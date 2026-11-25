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
case "${FLAVOR:-retail}" in
    retail)  GAME_VERSION_TYPE_ID=517 ;;
    forever) GAME_VERSION_TYPE_ID=88568 ;;
    classic) GAME_VERSION_TYPE_ID=67408 ;;
    tbc)     GAME_VERSION_TYPE_ID=73246 ;;
    wrath)   GAME_VERSION_TYPE_ID=73713 ;;
    wrath-titan) GAME_VERSION_TYPE_ID=81212 ;;
    cata)    GAME_VERSION_TYPE_ID=77522 ;;
    mop)     GAME_VERSION_TYPE_ID=79434 ;;
    *) echo "Unknown FLAVOR '$FLAVOR' in config (use retail, forever, classic, tbc, wrath, wrath-titan, cata or mop)" >&2; exit 1 ;;
esac
API="https://api.curseforge.com/v1"

if [[ ! -d "$ADDONS_DIR" ]]; then
    echo "ADDONS_DIR does not exist: $ADDONS_DIR (check config)" >&2
    exit 1
fi

[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

# Auto-detect addons already installed (e.g. dropped in by hand) that aren't
# tracked yet, by reading the Project ID CurseForge stamps into their .toc.
# Zips dropped next to the script are scanned too, so they get tracked.
declare -A known_ids
while IFS= read -r line; do
    line="${line%%#*}"
    id="$(echo "$line" | xargs)"
    [[ -n "$id" ]] && known_ids["$id"]=1
done < "$ADDONS_FILE"

shopt -s nullglob
declare -A seen_new_ids
for pid in $( {
    grep -ihm1 "curse-project-id" "$ADDONS_DIR"/*/*.toc /dev/null || true
    for zip in "$DIR"/*.zip; do
        unzip -p "$zip" '*.toc' 2>/dev/null | grep -im1 "curse-project-id" || true
    done
} | grep -oE "[0-9]+" ); do
    [[ -n "${known_ids[$pid]:-}" || -n "${seen_new_ids[$pid]:-}" ]] && continue
    seen_new_ids["$pid"]=1
    new_name=$(curl -s -H "x-api-key: $API_KEY" "$API/mods/$pid" | jq -r '.data.name')
    echo "$pid # $new_name" >> "$ADDONS_FILE"
    echo "[$new_name] new addon detected, added to addon-list (id $pid)"
done

while IFS= read -r line; do
    line="${line%%#*}"
    id="$(echo "$line" | xargs)"
    [[ -z "$id" ]] && continue

    mod_info=$(curl -s -H "x-api-key: $API_KEY" "$API/mods/$id")
    mod_name=$(echo "$mod_info" | jq -r '.data.name')
    mod_url=$(echo "$mod_info" | jq -r '.data.links.websiteUrl')
    file=$(curl -s -H "x-api-key: $API_KEY" \
        "$API/mods/$id/files?gameVersionTypeId=$GAME_VERSION_TYPE_ID&pageSize=1&sortField=2&sortOrder=desc" \
        | jq '.data[0]')

    if [[ "$file" == "null" || -z "$file" ]]; then
        echo "[$mod_name] no ${FLAVOR:-retail} file found, skipping"
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
        # ponytail: matches the exact CurseForge fileName; renamed downloads (e.g. "foo (1).zip") are missed
        local_zip="$DIR/$file_name"
        [[ ! -f "$local_zip" && -n "${DOWNLOADS_DIR:-}" ]] && local_zip="$DOWNLOADS_DIR/$file_name"
        if [[ -f "$local_zip" ]]; then
            echo "[$mod_name] installing $local_zip (file $file_id)"
            unzip -oq "$local_zip" -d "$ADDONS_DIR"
            rm -f "$local_zip"
            jq --arg id "$id" --arg fid "$file_id" '.[$id] = $fid' "$STATE_FILE" > "$STATE_FILE.tmp"
            mv "$STATE_FILE.tmp" "$STATE_FILE"
            echo "[$mod_name] updated"
        else
            echo "[$mod_name] update available: $file_name (download manually, author blocks API downloads) - $mod_url"
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
