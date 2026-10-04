#!/usr/bin/env bash
set -euo pipefail
operation="$2"
key=""
prefix=""
body=""
content_type=""
cache_control=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --content-type) content_type="$2"; shift 2 ;;
    --cache-control) cache_control="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$operation" in
  head-object)
    printf 'head-object %s\n' "$key" >> "$STUB_CALLS_FILE"
    if [[ -n "${STUB_FAIL_HEAD:-}" ]]; then
      printf 'An error occurred (403) when calling the HeadObject operation: Forbidden\n' >&2
      exit 254
    fi
    if [[ -f "$STUB_BUCKET_DIRECTORY/$key" ]]; then
      printf '{"ContentLength": 1}\n'
    else
      printf 'An error occurred (404) when calling the HeadObject operation: Not Found\n' >&2
      exit 254
    fi
    ;;
  list-objects-v2)
    printf 'list-objects-v2 %s\n' "$prefix" >> "$STUB_CALLS_FILE"
    if [[ -n "${STUB_FAIL_LIST:-}" ]]; then
      printf 'An error occurred (AccessDenied) when calling the ListObjectsV2 operation: Access Denied\n' >&2
      exit 254
    fi
    if [[ -d "$STUB_BUCKET_DIRECTORY/$prefix" ]]; then
      (cd "$STUB_BUCKET_DIRECTORY" && find "$prefix" -type f | sort | paste -sd $'\t' -)
    else
      printf 'None\n'
    fi
    ;;
  put-object)
    printf 'put-object %s content-type=%s cache-control=%s\n' "$key" "$content_type" "$cache_control" >> "$STUB_CALLS_FILE"
    if [[ "$key" == "${STUB_FAIL_PUT_KEY:-}" ]]; then
      printf 'An error occurred (InternalError) when calling the PutObject operation: We encountered an internal error.\n' >&2
      exit 255
    fi
    mkdir -p "$(dirname "$STUB_BUCKET_DIRECTORY/$key")" "$(dirname "$STUB_HEADERS_DIRECTORY/$key")"
    cp "$body" "$STUB_BUCKET_DIRECTORY/$key"
    printf 'content-type=%s\ncache-control=%s\n' "$content_type" "$cache_control" > "$STUB_HEADERS_DIRECTORY/$key"
    printf '{"ETag": "\\"d41d8cd98f00b204e9800998ecf8427e\\""}\n'
    ;;
  *)
    printf 'unexpected aws invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
