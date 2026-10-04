#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  maven-repository.sh check <bucket> <endpoint> <group:artifactId:version>...
  maven-repository.sh upload <staging-directory> <bucket> <endpoint> <group:artifactId:version>...

Coordinates may also arrive as one argument separated by spaces or newlines.

check refuses, with exit status 1, any version whose POM is already in the S3 bucket at <endpoint>.

upload runs the same check, then uploads each version from the Maven repository laid out under
<staging-directory>: every file of the version except its POM, then the POM, then the artifact's
maven-metadata.xml listing every version in the bucket. Nothing is uploaded if any check fails.

Credentials are read from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
EOF
  exit 1
}

TARGET_COORDINATES=()
TARGET_GROUPS=()
TARGET_ARTIFACT_IDS=()
TARGET_VERSIONS=()
TARGET_ARTIFACT_PREFIXES=()
TARGET_VERSION_PREFIXES=()
TARGET_POM_FILE_NAMES=()
TARGET_RELEASED_VERSIONS=()
METADATA_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$METADATA_DIRECTORY"' EXIT

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

configure_aws_cli_for_r2() {
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
  export AWS_PAGER=""
  export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
  export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
}

require_credentials() {
  local name
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [[ -n "${!name:-}" ]] || fail "$name is not set"
  done
}

is_coordinate_part() {
  case "$1" in
    "" | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

parse_targets() {
  local target group artifact_id version artifact_prefix
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    IFS=: read -r group artifact_id version <<<"$target"
    is_coordinate_part "$group" && is_coordinate_part "$artifact_id" && is_coordinate_part "$version" \
      || fail "'$target' is not a group:artifactId:version"
    artifact_prefix="${group//.//}/$artifact_id"
    TARGET_COORDINATES+=("$target")
    TARGET_GROUPS+=("$group")
    TARGET_ARTIFACT_IDS+=("$artifact_id")
    TARGET_VERSIONS+=("$version")
    TARGET_ARTIFACT_PREFIXES+=("$artifact_prefix")
    TARGET_VERSION_PREFIXES+=("$artifact_prefix/$version")
    TARGET_POM_FILE_NAMES+=("$artifact_id-$version.pom")
  done < <(printf '%s\n' "$@" | tr ' \t' '\n\n')
  [[ ${#TARGET_COORDINATES[@]} -ge 1 ]] || usage
}

require_staged_poms() {
  local index pom
  for index in "${!TARGET_COORDINATES[@]}"; do
    pom="$STAGING_DIRECTORY/${TARGET_VERSION_PREFIXES[$index]}/${TARGET_POM_FILE_NAMES[$index]}"
    [[ -f "$pom" ]] || fail "$pom is not in the staging directory"
  done
}

object_exists() {
  local key="$1" output
  if output=$(aws s3api head-object --bucket "$BUCKET" --key "$key" --endpoint-url "$ENDPOINT" 2>&1); then
    return 0
  fi
  case "$output" in
    *"(404)"*) return 1 ;;
    *) fail "could not check whether $key exists: $output" ;;
  esac
}

refuse_released_targets() {
  local index key
  for index in "${!TARGET_COORDINATES[@]}"; do
    key="${TARGET_VERSION_PREFIXES[$index]}/${TARGET_POM_FILE_NAMES[$index]}"
    if object_exists "$key"; then
      fail "${TARGET_COORDINATES[$index]} is already in the bucket: $key exists. A released version is never replaced, so bump the version instead. Nothing was uploaded."
    fi
    printf '%s is not in the bucket yet\n' "${TARGET_COORDINATES[$index]}"
  done
}

versions_with_a_pom_under() {
  local prefix="$1" artifact_id="$2" key remainder version
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix/" --query 'Contents[].Key' --output text --endpoint-url "$ENDPOINT" \
    | tr '\t' '\n' \
    | while IFS= read -r key; do
        [[ -z "$key" || "$key" == "None" ]] && continue
        remainder="${key#"$prefix"/}"
        version="${remainder%%/*}"
        if [[ "$remainder" == "$version/$artifact_id-$version.pom" ]]; then
          printf '%s\n' "$version"
        fi
      done
}

collect_released_versions() {
  local index released
  for index in "${!TARGET_COORDINATES[@]}"; do
    released=$(versions_with_a_pom_under "${TARGET_ARTIFACT_PREFIXES[$index]}" "${TARGET_ARTIFACT_IDS[$index]}") \
      || fail "could not list the versions of ${TARGET_GROUPS[$index]}:${TARGET_ARTIFACT_IDS[$index]} in the bucket. Nothing was uploaded."
    TARGET_RELEASED_VERSIONS+=("$released")
  done
}

content_type_for() {
  case "$1" in
    *.asc | *.md5 | *.sha1 | *.sha256 | *.sha512) printf 'text/plain' ;;
    *.pom | *.xml) printf 'application/xml' ;;
    *.jar) printf 'application/java-archive' ;;
    *.module) printf 'application/json' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

upload_file() {
  local file="$1" key="$2" cache_control="${3:-}"
  local arguments=(--bucket "$BUCKET" --key "$key" --body "$file" --content-type "$(content_type_for "$file")" --endpoint-url "$ENDPOINT")
  if [[ -n "$cache_control" ]]; then
    arguments+=(--cache-control "$cache_control")
  fi
  aws s3api put-object "${arguments[@]}" > /dev/null || fail "could not upload $key"
  printf 'uploaded %s\n' "$key"
}

upload_version_files() {
  local index prefix file
  for index in "${!TARGET_COORDINATES[@]}"; do
    prefix="${TARGET_VERSION_PREFIXES[$index]}"
    while IFS= read -r file; do
      [[ "$(basename "$file")" == "${TARGET_POM_FILE_NAMES[$index]}" ]] && continue
      upload_file "$file" "$prefix/$(basename "$file")"
    done < <(find "$STAGING_DIRECTORY/$prefix" -maxdepth 1 -type f | sort)
  done
}

upload_poms() {
  local index key
  for index in "${!TARGET_COORDINATES[@]}"; do
    key="${TARGET_VERSION_PREFIXES[$index]}/${TARGET_POM_FILE_NAMES[$index]}"
    upload_file "$STAGING_DIRECTORY/$key" "$key"
  done
}

write_metadata() {
  local index="$1" file="$2" version
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<metadata>\n'
    printf '  <groupId>%s</groupId>\n' "${TARGET_GROUPS[$index]}"
    printf '  <artifactId>%s</artifactId>\n' "${TARGET_ARTIFACT_IDS[$index]}"
    printf '  <versioning>\n'
    printf '    <latest>%s</latest>\n' "${TARGET_VERSIONS[$index]}"
    printf '    <release>%s</release>\n' "${TARGET_VERSIONS[$index]}"
    printf '    <versions>\n'
    while IFS= read -r version; do
      [[ -n "$version" ]] || continue
      printf '      <version>%s</version>\n' "$version"
    done < <(printf '%s\n%s\n' "${TARGET_RELEASED_VERSIONS[$index]}" "${TARGET_VERSIONS[$index]}" | sort -V | uniq)
    printf '    </versions>\n'
    printf '    <lastUpdated>%s</lastUpdated>\n' "$(date -u +%Y%m%d%H%M%S)"
    printf '  </versioning>\n'
    printf '</metadata>\n'
  } > "$file"
}

write_checksums() {
  local file="$1"
  printf '%s' "$(md5sum "$file" | cut -d' ' -f1)" > "$file.md5"
  printf '%s' "$(sha1sum "$file" | cut -d' ' -f1)" > "$file.sha1"
  printf '%s' "$(sha256sum "$file" | cut -d' ' -f1)" > "$file.sha256"
  printf '%s' "$(sha512sum "$file" | cut -d' ' -f1)" > "$file.sha512"
}

upload_metadata() {
  local index prefix directory extension
  for index in "${!TARGET_COORDINATES[@]}"; do
    prefix="${TARGET_ARTIFACT_PREFIXES[$index]}"
    directory="$METADATA_DIRECTORY/$prefix"
    mkdir -p "$directory"
    write_metadata "$index" "$directory/maven-metadata.xml"
    write_checksums "$directory/maven-metadata.xml"
    for extension in "" .md5 .sha1 .sha256 .sha512; do
      upload_file "$directory/maven-metadata.xml$extension" "$prefix/maven-metadata.xml$extension" no-cache
    done
  done
}

check() {
  [[ $# -ge 3 ]] || usage
  BUCKET="$1"
  ENDPOINT="$2"
  shift 2
  require_credentials
  parse_targets "$@"
  configure_aws_cli_for_r2
  refuse_released_targets
}

upload() {
  [[ $# -ge 4 ]] || usage
  STAGING_DIRECTORY="$1"
  BUCKET="$2"
  ENDPOINT="$3"
  shift 3
  require_credentials
  parse_targets "$@"
  require_staged_poms
  configure_aws_cli_for_r2
  refuse_released_targets
  collect_released_versions
  upload_version_files
  upload_poms
  upload_metadata
  printf 'released %s\n' "${TARGET_COORDINATES[@]}"
}

case "${1:-}" in
  check) shift; check "$@" ;;
  upload) shift; upload "$@" ;;
  *) usage ;;
esac
