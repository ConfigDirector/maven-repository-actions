#!/usr/bin/env bash

set -euo pipefail

TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIRECTORY/../scripts/maven-repository.sh"
WORK_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

PASSED=0
FAILED=0
OUTPUT_FILE="$WORK_DIRECTORY/output"
STUB_DIRECTORY="$WORK_DIRECTORY/stub"
export STUB_CALLS_FILE="$WORK_DIRECTORY/calls"
export STUB_BUCKET_DIRECTORY="$WORK_DIRECTORY/bucket"
export STUB_HEADERS_DIRECTORY="$WORK_DIRECTORY/headers"
STAGING_DIRECTORY="$WORK_DIRECTORY/staging"
BUCKET="maven-test"
ENDPOINT="https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"

mkdir -p "$STUB_DIRECTORY"
cp "$TEST_DIRECTORY/aws-stub.sh" "$STUB_DIRECTORY/aws"
chmod +x "$STUB_DIRECTORY/aws"
export PATH="$STUB_DIRECTORY:$PATH"

reset_fixtures() {
  rm -rf "$STUB_BUCKET_DIRECTORY" "$STUB_HEADERS_DIRECTORY" "$STAGING_DIRECTORY"
  mkdir -p "$STUB_BUCKET_DIRECTORY" "$STUB_HEADERS_DIRECTORY" "$STAGING_DIRECTORY"
  : > "$STUB_CALLS_FILE"
  unset STUB_FAIL_PUT_KEY STUB_FAIL_HEAD STUB_FAIL_LIST
  export AWS_ACCESS_KEY_ID="test-access-key-id"
  export AWS_SECRET_ACCESS_KEY="test-secret-access-key"
}

stage_version() {
  local artifact="$1" version="$2" directory="$STAGING_DIRECTORY/com/configdirector/$1/$2" file
  mkdir -p "$directory"
  for file in "$artifact-$version.pom" "$artifact-$version.jar" "$artifact-$version-sources.jar" \
      "$artifact-$version-javadoc.jar" "$artifact-$version.module"; do
    printf 'staged %s\n' "$file" > "$directory/$file"
    printf 'signature of %s\n' "$file" > "$directory/$file.asc"
    printf 'md5 of %s' "$file" > "$directory/$file.md5"
    printf 'sha1 of %s' "$file" > "$directory/$file.sha1"
    printf 'sha256 of %s' "$file" > "$directory/$file.sha256"
    printf 'sha512 of %s' "$file" > "$directory/$file.sha512"
  done
  printf '<metadata><versioning><versions><version>%s</version></versions></versioning></metadata>\n' "$version" \
    > "$STAGING_DIRECTORY/com/configdirector/$artifact/maven-metadata.xml"
  printf 'gradle md5' > "$STAGING_DIRECTORY/com/configdirector/$artifact/maven-metadata.xml.md5"
}

bucket_has_released_version() {
  local artifact="$1" version="$2" directory="$STUB_BUCKET_DIRECTORY/com/configdirector/$1/$2"
  mkdir -p "$directory"
  printf 'released\n' > "$directory/$artifact-$version.jar"
  printf 'released\n' > "$directory/$artifact-$version.pom"
}

bucket_has_half_uploaded_version() {
  local artifact="$1" version="$2" directory="$STUB_BUCKET_DIRECTORY/com/configdirector/$1/$2"
  mkdir -p "$directory"
  printf 'half\n' > "$directory/$artifact-$version.jar"
}

run_script() {
  local status=0
  "$SCRIPT" "$@" > "$OUTPUT_FILE" 2>&1 || status=$?
  printf '%s' "$status"
}

calls() {
  grep "^$1" "$STUB_CALLS_FILE" || true
}

call_line_number() {
  grep -n -F "$1" "$STUB_CALLS_FILE" | head -1 | cut -d: -f1
}

fail() {
  echo "FAILED: $1: $2"
  echo "  output:"
  sed 's/^/    /' "$OUTPUT_FILE"
  echo "  aws calls:"
  sed 's/^/    /' "$STUB_CALLS_FILE"
  FAILED=$((FAILED + 1))
}

pass() {
  echo "ok: $1"
  PASSED=$((PASSED + 1))
}

assert_status() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$name" "expected exit status $expected, got $actual"
    return 1
  fi
}

assert_equal() {
  local name="$1" description="$2" expected="$3" actual="$4"
  if [[ "$actual" != "$expected" ]]; then
    fail "$name" "$description: expected '$expected', got '$actual'"
    return 1
  fi
}

assert_output_contains() {
  local name="$1" expected="$2"
  if ! grep -q -F -- "$expected" "$OUTPUT_FILE"; then
    fail "$name" "expected the output to mention '$expected'"
    return 1
  fi
}

assert_before() {
  local name="$1" earlier="$2" later="$3" earlier_line later_line
  earlier_line=$(call_line_number "$earlier")
  later_line=$(call_line_number "$later")
  if [[ -z "$earlier_line" || -z "$later_line" || "$earlier_line" -ge "$later_line" ]]; then
    fail "$name" "expected '$earlier' (line ${earlier_line:-none}) before '$later' (line ${later_line:-none})"
    return 1
  fi
}

uploaded_header() {
  grep "^$2=" "$STUB_HEADERS_DIRECTORY/$1" | cut -d= -f2-
}

test_version_files_go_up_before_the_pom_and_metadata_last() {
  local name="version files go up before the POM, and metadata last" status prefix file
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  prefix="com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0"
  for file in ".jar" ".jar.asc" ".jar.md5" ".jar.sha1" ".jar.sha256" ".jar.sha512" "-sources.jar" \
      "-sources.jar.asc" "-javadoc.jar" "-javadoc.jar.sha512" ".module" ".module.asc" ".pom.asc" \
      ".pom.md5" ".pom.sha1" ".pom.sha256" ".pom.sha512"; do
    assert_before "$name" "put-object $prefix$file " "put-object $prefix.pom " || return 0
  done
  for file in "" ".md5" ".sha1" ".sha256" ".sha512"; do
    assert_before "$name" "put-object $prefix.pom " "put-object com/configdirector/server-sdk/maven-metadata.xml$file " || return 0
  done
  assert_equal "$name" "number of files uploaded" 35 "$(calls put-object | wc -l | tr -d ' ')" || return 0
  assert_equal "$name" "uploaded jar bytes" "staged server-sdk-1.8.0.jar" "$(cat "$STUB_BUCKET_DIRECTORY/$prefix.jar")" || return 0
  pass "$name"
}

test_a_version_whose_pom_is_in_the_bucket_is_refused() {
  local name="a version whose POM is in the bucket is refused before any upload" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  bucket_has_released_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_output_contains "$name" "com.configdirector:server-sdk:1.8.0" || return 0
  assert_output_contains "$name" "com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0.pom" || return 0
  pass "$name"
}

test_one_released_target_blocks_the_whole_run() {
  local name="one released target among several blocks the whole run" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  stage_version server-sdk-testing 1.8.0
  bucket_has_released_version server-sdk-testing 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" \
    com.configdirector:server-sdk:1.8.0 com.configdirector:server-sdk-testing:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_output_contains "$name" "com.configdirector:server-sdk-testing:1.8.0" || return 0
  pass "$name"
}

test_a_half_uploaded_version_is_completed() {
  local name="a version left without a POM by an earlier run is uploaded again" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  bucket_has_half_uploaded_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  assert_equal "$name" "uploaded jar bytes" "staged server-sdk-1.8.0.jar" \
    "$(cat "$STUB_BUCKET_DIRECTORY/com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0.jar")" || return 0
  pass "$name"
}

test_metadata_lists_the_bucket_versions_and_the_new_one() {
  local name="metadata lists the versions in the bucket plus the new one" status metadata
  reset_fixtures
  stage_version server-sdk 1.10.0
  bucket_has_released_version server-sdk 1.9.0
  bucket_has_released_version server-sdk 1.7.0
  bucket_has_half_uploaded_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.10.0)
  assert_status "$name" 0 "$status" || return 0
  metadata=$(tr -d ' \n' < "$STUB_BUCKET_DIRECTORY/com/configdirector/server-sdk/maven-metadata.xml")
  assert_equal "$name" "versions" "<versions><version>1.7.0</version><version>1.9.0</version><version>1.10.0</version></versions>" \
    "$(grep -o '<versions>.*</versions>' <<<"$metadata")" || return 0
  assert_equal "$name" "latest" "<latest>1.10.0</latest>" "$(grep -o '<latest>[^<]*</latest>' <<<"$metadata")" || return 0
  assert_equal "$name" "release" "<release>1.10.0</release>" "$(grep -o '<release>[^<]*</release>' <<<"$metadata")" || return 0
  assert_equal "$name" "groupId" "<groupId>com.configdirector</groupId>" "$(grep -o '<groupId>[^<]*</groupId>' <<<"$metadata")" || return 0
  assert_equal "$name" "artifactId" "<artifactId>server-sdk</artifactId>" "$(grep -o '<artifactId>[^<]*</artifactId>' <<<"$metadata")" || return 0
  if ! grep -q '<lastUpdated>[0-9]\{14\}</lastUpdated>' <<<"$metadata"; then
    fail "$name" "expected a 14 digit lastUpdated, got: $metadata"
    return 0
  fi
  pass "$name"
}

test_metadata_checksums_match_the_uploaded_metadata() {
  local name="metadata checksums match the uploaded metadata" status directory
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  directory="$STUB_BUCKET_DIRECTORY/com/configdirector/server-sdk"
  assert_equal "$name" "md5" "$(md5sum "$directory/maven-metadata.xml" | cut -d' ' -f1)" "$(cat "$directory/maven-metadata.xml.md5")" || return 0
  assert_equal "$name" "sha1" "$(sha1sum "$directory/maven-metadata.xml" | cut -d' ' -f1)" "$(cat "$directory/maven-metadata.xml.sha1")" || return 0
  assert_equal "$name" "sha256" "$(sha256sum "$directory/maven-metadata.xml" | cut -d' ' -f1)" "$(cat "$directory/maven-metadata.xml.sha256")" || return 0
  assert_equal "$name" "sha512" "$(sha512sum "$directory/maven-metadata.xml" | cut -d' ' -f1)" "$(cat "$directory/maven-metadata.xml.sha512")" || return 0
  pass "$name"
}

test_metadata_is_uploaded_with_no_cache_and_version_files_without() {
  local name="metadata and its checksums carry no-cache, version files carry nothing" status file
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  for file in "" ".md5" ".sha1" ".sha256" ".sha512"; do
    assert_equal "$name" "cache-control of maven-metadata.xml$file" "no-cache" \
      "$(uploaded_header "com/configdirector/server-sdk/maven-metadata.xml$file" cache-control)" || return 0
  done
  for file in ".pom" ".jar" ".jar.asc" ".pom.sha1"; do
    assert_equal "$name" "cache-control of server-sdk-1.8.0$file" "" \
      "$(uploaded_header "com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0$file" cache-control)" || return 0
  done
  pass "$name"
}

test_content_types_follow_the_file_extension() {
  local name="content types follow the file extension" status prefix
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  prefix="com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0"
  assert_equal "$name" "pom" "application/xml" "$(uploaded_header "$prefix.pom" content-type)" || return 0
  assert_equal "$name" "jar" "application/java-archive" "$(uploaded_header "$prefix.jar" content-type)" || return 0
  assert_equal "$name" "sources jar" "application/java-archive" "$(uploaded_header "$prefix-sources.jar" content-type)" || return 0
  assert_equal "$name" "module" "application/json" "$(uploaded_header "$prefix.module" content-type)" || return 0
  assert_equal "$name" "asc" "text/plain" "$(uploaded_header "$prefix.jar.asc" content-type)" || return 0
  assert_equal "$name" "sha256" "text/plain" "$(uploaded_header "$prefix.jar.sha256" content-type)" || return 0
  assert_equal "$name" "metadata" "application/xml" "$(uploaded_header "com/configdirector/server-sdk/maven-metadata.xml" content-type)" || return 0
  assert_equal "$name" "metadata md5" "text/plain" "$(uploaded_header "com/configdirector/server-sdk/maven-metadata.xml.md5" content-type)" || return 0
  pass "$name"
}

test_two_targets_share_the_run() {
  local name="two targets upload all their files before either POM" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  stage_version server-sdk-testing 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" \
    com.configdirector:server-sdk:1.8.0 com.configdirector:server-sdk-testing:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  assert_before "$name" "put-object com/configdirector/server-sdk-testing/1.8.0/server-sdk-testing-1.8.0.jar " \
    "put-object com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0.pom " || return 0
  assert_before "$name" "put-object com/configdirector/server-sdk-testing/1.8.0/server-sdk-testing-1.8.0.pom " \
    "put-object com/configdirector/server-sdk/maven-metadata.xml " || return 0
  assert_equal "$name" "number of files uploaded" 70 "$(calls put-object | wc -l | tr -d ' ')" || return 0
  pass "$name"
}

test_a_failed_upload_stops_before_the_pom() {
  local name="a failed upload stops the run before the POM" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  export STUB_FAIL_PUT_KEY="com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0-sources.jar"
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "POM upload" "" "$(calls "put-object com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0.pom ")" || return 0
  assert_equal "$name" "metadata upload" "" "$(calls "put-object com/configdirector/server-sdk/maven-metadata.xml")" || return 0
  pass "$name"
}

test_a_failed_bucket_listing_stops_the_run_before_any_upload() {
  local name="a failed bucket listing stops the run before any upload" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  export STUB_FAIL_LIST=1
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_output_contains "$name" "Access Denied" || return 0
  pass "$name"
}

test_a_failed_existence_check_stops_the_run_before_any_upload() {
  local name="a failed existence check stops the run before any upload" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  export STUB_FAIL_HEAD=1
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_output_contains "$name" "Forbidden" || return 0
  pass "$name"
}

test_check_refuses_a_version_whose_pom_is_in_the_bucket() {
  local name="check refuses a version whose POM is in the bucket" status
  reset_fixtures
  bucket_has_released_version server-sdk 1.8.0
  status=$(run_script check "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0 com.configdirector:server-sdk-testing:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_output_contains "$name" "com.configdirector:server-sdk:1.8.0" || return 0
  pass "$name"
}

test_check_passes_a_version_that_is_not_in_the_bucket() {
  local name="check passes a version that is not in the bucket without a staging directory" status
  reset_fixtures
  bucket_has_half_uploaded_version server-sdk 1.8.0
  status=$(run_script check "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0 com.configdirector:server-sdk-testing:1.8.0)
  assert_status "$name" 0 "$status" || return 0
  assert_equal "$name" "uploads" "" "$(calls put-object)" || return 0
  assert_equal "$name" "existence checks" "head-object com/configdirector/server-sdk/1.8.0/server-sdk-1.8.0.pom
head-object com/configdirector/server-sdk-testing/1.8.0/server-sdk-testing-1.8.0.pom" "$(calls head-object)" || return 0
  pass "$name"
}

test_an_unknown_mode_fails_before_any_request() {
  local name="an unknown mode fails before any request" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script publish "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "aws calls" "" "$(cat "$STUB_CALLS_FILE")" || return 0
  pass "$name"
}

test_artifacts_given_as_one_whitespace_separated_argument_are_all_handled() {
  local name="artifacts given as one newline separated argument are all handled" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  stage_version server-sdk-testing 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" $'  com.configdirector:server-sdk:1.8.0\n\n  com.configdirector:server-sdk-testing:1.8.0  \n')
  assert_status "$name" 0 "$status" || return 0
  assert_equal "$name" "number of files uploaded" 70 "$(calls put-object | wc -l | tr -d ' ')" || return 0
  pass "$name"
}

test_a_target_missing_from_the_staging_directory_fails_before_any_request() {
  local name="a target missing from the staging directory fails before any request" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" \
    com.configdirector:server-sdk:1.8.0 com.configdirector:server-sdk-testing:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "aws calls" "" "$(cat "$STUB_CALLS_FILE")" || return 0
  assert_output_contains "$name" "server-sdk-testing-1.8.0.pom" || return 0
  pass "$name"
}

test_a_malformed_target_fails_before_any_request() {
  local name="a malformed target fails before any request" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" "com.configdirector:server-sdk")
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "aws calls" "" "$(cat "$STUB_CALLS_FILE")" || return 0
  pass "$name"
}

test_missing_credentials_fail_before_any_request() {
  local name="missing credentials fail before any request" status
  reset_fixtures
  stage_version server-sdk 1.8.0
  unset AWS_SECRET_ACCESS_KEY
  status=$(run_script upload "$STAGING_DIRECTORY" "$BUCKET" "$ENDPOINT" com.configdirector:server-sdk:1.8.0)
  assert_status "$name" 1 "$status" || return 0
  assert_equal "$name" "aws calls" "" "$(cat "$STUB_CALLS_FILE")" || return 0
  assert_output_contains "$name" "AWS_SECRET_ACCESS_KEY" || return 0
  pass "$name"
}

test_version_files_go_up_before_the_pom_and_metadata_last
test_a_version_whose_pom_is_in_the_bucket_is_refused
test_one_released_target_blocks_the_whole_run
test_a_half_uploaded_version_is_completed
test_metadata_lists_the_bucket_versions_and_the_new_one
test_metadata_checksums_match_the_uploaded_metadata
test_metadata_is_uploaded_with_no_cache_and_version_files_without
test_content_types_follow_the_file_extension
test_two_targets_share_the_run
test_a_failed_upload_stops_before_the_pom
test_a_failed_bucket_listing_stops_the_run_before_any_upload
test_a_failed_existence_check_stops_the_run_before_any_upload
test_check_refuses_a_version_whose_pom_is_in_the_bucket
test_check_passes_a_version_that_is_not_in_the_bucket
test_an_unknown_mode_fails_before_any_request
test_artifacts_given_as_one_whitespace_separated_argument_are_all_handled
test_a_target_missing_from_the_staging_directory_fails_before_any_request
test_a_malformed_target_fails_before_any_request
test_missing_credentials_fail_before_any_request

echo
echo "$PASSED passed, $FAILED failed"
if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi
