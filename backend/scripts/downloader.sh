#!/usr/bin/env bash
set -u

url="${1:-}"
dest_path="${2:-}"
extract_dir="${3:-}"
state_file="${4:-}"
operation_id="${5:-}"
mode="${6:-extract}"
connect_timeout="${7:-15}"
max_time="${8:-900}"
retries="${9:-2}"
user_agent="${10:-discord(dot)gg/luatools}"

write_state() {
    local status="$1"
    local error="${2:-}"
    if [ -n "$operation_id" ]; then
        if [ -n "$error" ]; then
            printf '{"operationId":"%s","status":"%s","error":"%s"}\n' "$operation_id" "$status" "$error" > "$state_file"
        else
            printf '{"operationId":"%s","status":"%s"}\n' "$operation_id" "$status" > "$state_file"
        fi
    else
        if [ -n "$error" ]; then
            printf '{"status":"%s","error":"%s"}\n' "$status" "$error" > "$state_file"
        else
            printf '{"status":"%s"}\n' "$status" > "$state_file"
        fi
    fi
}

fail() {
    write_state "failed" "$1"
    exit 1
}

[ -n "$url" ] || fail "Missing URL"
[ -n "$dest_path" ] || fail "Missing destination path"
[ -n "$state_file" ] || fail "Missing state file"

mkdir -p "$(dirname "$dest_path")" || fail "Failed to create download directory"
rm -f "$dest_path"

write_state "downloading"
curl --fail --location \
    --connect-timeout "$connect_timeout" \
    --max-time "$max_time" \
    --retry "$retries" \
    --retry-delay 2 \
    --retry-all-errors \
    -A "$user_agent" \
    "$url" \
    -o "$dest_path" || fail "Download failed"

if [ "$mode" = "download-only" ]; then
    write_state "downloaded"
    exit 0
fi

[ -n "$extract_dir" ] || fail "Missing extraction directory"
rm -rf "$extract_dir"
mkdir -p "$extract_dir" || fail "Failed to create extraction directory"

write_state "extracting"
unzip -tq "$dest_path" >/dev/null || fail "Archive validation failed"
unzip -o -q "$dest_path" -d "$extract_dir" || fail "Extraction failed"
write_state "extracted"
