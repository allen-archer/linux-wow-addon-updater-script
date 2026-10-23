#!/usr/bin/env bash
# Updates WoW addons listed by CurseForge Project ID in addon-list.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$DIR/config" ]]; then
    echo "Missing config file. Copy config.example to config and edit it." >&2
    exit 1
fi
source "$DIR/config"

API_KEY="$(tr -d '\n' < "$DIR/api-key")"
ADDONS_FILE="$DIR/addon-list"
STATE_FILE="$DIR/installed-versions.json"
RETAIL_TYPE_ID=517
API="https://api.curseforge.com/v1"

if [[ ! -d "$ADDONS_DIR" ]]; then
    echo "ADDONS_DIR does not exist: $ADDONS_DIR (check config)" >&2
    exit 1
fi

[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

# Auto-detect addons already installed (e.g. dropped in by hand) that aren't
# tracked yet, by reading the Project ID CurseForge stamps into their .toc.
declare -A known_ids
while IFS= read -r line; do
    line="${line%%#*}"
    id="$(echo "$line" | xargs)"
    [[ -n "$id" ]] && known_ids["$id"]=1
done < "$ADDONS_FILE"

shopt -s nullglob
declare -A seen_new_ids
for toc in "$ADDONS_DIR"/*/*.toc; do
    pid=$(grep -im1 "curse-project-id" "$toc" | grep -oE "[0-9]+" || true)
    [[ -z "$pid" ]] && continue
    [[ -n "${known_ids[$pid]:-}" || -n "${seen_new_ids[$pid]:-}" ]] && continue
    seen_new_ids["$pid"]=1
    new_name=$(curl -s -H "x-api-key: $API_KEY" "$API/mods/$pid" | jq -r '.data.name')
    echo "$pid # $new_name" >> "$ADDONS_FILE"
    echo "[$new_name] new addon detected in AddOns, added to addon-list (id $pid)"
done

while IFS= read -r line; do
    line="${line%%#*}"
    id="$(echo "$line" | xargs)"
    [[ -z "$id" ]] && continue

    mod_info=$(curl -s -H "x-api-key: $API_KEY" "$API/mods/$id")
    mod_name=$(echo "$mod_info" | jq -r '.data.name')
    mod_url=$(echo "$mod_info" | jq -r '.data.links.websiteUrl')
    file=$(curl -s -H "x-api-key: $API_KEY" \
        "$API/mods/$id/files?gameVersionTypeId=$RETAIL_TYPE_ID&pageSize=1&sortField=2&sortOrder=desc" \
        | jq '.data[0]')

    if [[ "$file" == "null" || -z "$file" ]]; then
        echo "[$mod_name] no retail file found, skipping"
        continue
    fi

    file_id=$(echo "$file" | jq -r '.id')
    known_id=$(jq -r --arg id "$id" '.[$id] // ""' "$STATE_FILE")

    if [[ "$file_id" == "$known_id" ]]; then
        echo "[$mod_name] up to date (file $file_id)"
        continue
    fi

    download_url=$(echo "$file" | jq -r '.downloadUrl')
    file_name=$(echo "$file" | jq -r '.fileName')

    if [[ "$download_url" == "null" || -z "$download_url" ]]; then
        if [[ "$file_id" != "$known_id" ]]; then
            echo "[$mod_name] update available: $file_name (download manually, author blocks API downloads) - $mod_url"
            jq --arg id "$id" --arg fid "$file_id" '.[$id] = $fid' "$STATE_FILE" > "$STATE_FILE.tmp"
            mv "$STATE_FILE.tmp" "$STATE_FILE"
        else
            echo "[$mod_name] up to date (file $file_id, manual download only)"
        fi
        continue
    fi

    echo "[$mod_name] downloading $file_name (file $file_id)"

    tmp_zip="$(mktemp --suffix=.zip)"
    curl -sf -L -o "$tmp_zip" "$download_url"
    unzip -oq "$tmp_zip" -d "$ADDONS_DIR"
    rm -f "$tmp_zip"

    jq --arg id "$id" --arg fid "$file_id" '.[$id] = $fid' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "[$mod_name] updated"
done < "$ADDONS_FILE"

# Drop a zip here for addons that can't be fetched via the API (e.g. distribution disabled).
shopt -s nullglob
for zip in "$DIR"/*.zip; do
    echo "[$(basename "$zip")] installing from local zip"
    unzip -oq "$zip" -d "$ADDONS_DIR"
    rm -f "$zip"
done
