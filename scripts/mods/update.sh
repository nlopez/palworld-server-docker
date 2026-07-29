#!/bin/bash
# shellcheck source=scripts/helper_functions.sh
source "/home/steam/server/helper_functions.sh"

set -euo pipefail

DATA_DIR="${DATA_DIR:-/palworld}"
SERVER_PLATFORM="$(ServerPlatform)"
BIN_DIR="${DATA_DIR}/Pal/Binaries/Win64"
UE4SS_MODS_LAYOUT="${UE4SS_MODS_LAYOUT:-legacy}"
INSTALL_UE4SS_EXPERIMENTAL="${INSTALL_UE4SS_EXPERIMENTAL:-false}"
UE4SS_EXPERIMENTAL_URL="${UE4SS_EXPERIMENTAL_URL:-https://github.com/Okaetsu/RE-UE4SS/releases/download/experimental-palworld/UE4SS-Palworld.zip}"
UE4SS_CLEANUP_LEGACY="${UE4SS_CLEANUP_LEGACY:-true}"
MODS_BASE_DIR="${BIN_DIR}/Mods"
WORKSHOP_APP_ID="1623730"
STATE_FILE="${DATA_DIR}/.mod-support-state.json"
STEAMCMD_BIN="${STEAMCMD_BIN:-/home/steam/steamcmd/steamcmd.sh}"
STEAM_LOGIN_USER_FILE="${STEAM_LOGIN_USER_FILE:-/home/steam/Steam/.steam-login-user}"

if [ "${SERVER_PLATFORM}" != "windows" ]; then
    LogInfo "Mod support is enabled only for SERVER_PLATFORM=Windows."
    exit 0
fi

if [ "${UE4SS_MODS_LAYOUT}" = "ue4ss_dir" ]; then
    MODS_BASE_DIR="${BIN_DIR}/ue4ss/Mods"
elif [ "${UE4SS_MODS_LAYOUT}" != "legacy" ]; then
    LogWarn "Unknown UE4SS_MODS_LAYOUT=${UE4SS_MODS_LAYOUT}. Falling back to legacy layout."
    UE4SS_MODS_LAYOUT="legacy"
fi

trim() {
    local value="${1:-}"
    value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${value}"
}

debug_log() {
    if isTrue "${WORKSHOP_MODS_DEBUG:-false}"; then
        LogInfo "[mods-debug] $*"
    fi
}

previous_state='{}'
if [ -f "${STATE_FILE}" ]; then
    previous_state="$(jq -c . "${STATE_FILE}" 2>/dev/null || echo '{}')"
fi

ue4ss_source_is_available() {
    local source_dir="$1"

    [ -d "${source_dir}/ue4ss" ] || \
    [ -f "${source_dir}/dwmapi.dll" ] || \
    [ -f "${source_dir}/UE4SS.dll" ] || \
    [ -f "${source_dir}/UE4SS-settings.ini" ] || \
    [ -f "${source_dir}/MemberVariableLayout.ini" ] || \
    [ -f "${source_dir}/Vindsent.dll" ]
}

sync_ue4ss_experimental_source() {
    local zip_file="${DATA_DIR}/Mods/ue4ss-experimental.zip"
    local tmp_file="${zip_file}.tmp"
    local target_dir="${DATA_DIR}/Mods/NativeMods/ue4ss-experimental"
    local should_extract=false

    if ! isTrue "${INSTALL_UE4SS_EXPERIMENTAL}"; then
        if [ -d "${target_dir}" ]; then
            rm -rf "${target_dir}"
        fi
        return 0
    fi

    mkdir -p "${DATA_DIR}/Mods"
    mkdir -p "${DATA_DIR}/Mods/NativeMods"

    if [ -f "${zip_file}" ]; then
        if curl -sSfL -z "${zip_file}" -o "${tmp_file}" "${UE4SS_EXPERIMENTAL_URL}"; then
            if [ -s "${tmp_file}" ]; then
                mv -f "${tmp_file}" "${zip_file}"
                should_extract=true
                LogInfo "Downloaded newer UE4SS experimental package."
            else
                rm -f "${tmp_file}"
                if [ ! -d "${target_dir}" ]; then
                    should_extract=true
                fi
            fi
        else
            LogWarn "Failed to check UE4SS updates from ${UE4SS_EXPERIMENTAL_URL}. Using local cache if available."
            rm -f "${tmp_file}"
            if [ ! -f "${zip_file}" ]; then
                return 0
            fi
            if [ ! -d "${target_dir}" ]; then
                should_extract=true
            fi
        fi
    else
        if ! curl -sSfL -o "${zip_file}" "${UE4SS_EXPERIMENTAL_URL}"; then
            LogWarn "Failed to download UE4SS package from ${UE4SS_EXPERIMENTAL_URL}."
            return 0
        fi
        should_extract=true
    fi

    if [ "${should_extract}" != true ]; then
        return 0
    fi

    rm -rf "${target_dir}"
    mkdir -p "${target_dir}"

    if unzip -o "${zip_file}" -d "${target_dir}" >/dev/null; then
        debug_log "Extracted UE4SS package to ${target_dir}"
    else
        LogWarn "Failed to extract UE4SS package."
        rm -rf "${target_dir}"
    fi
}

cleanup_previous_ue4ss_artifacts() {
    local state_json="$1"
    local tracked_path

    while IFS= read -r tracked_path; do
        [ -z "${tracked_path}" ] && continue
        rm -rf "${BIN_DIR}/${tracked_path}"
    done < <(printf '%s' "${state_json}" | jq -r '.ue4ss.files[]? // empty' 2>/dev/null)

    if isTrue "${UE4SS_CLEANUP_LEGACY}"; then
        rm -f "${BIN_DIR}/dwmapi.dll" "${BIN_DIR}/UE4SS.dll" "${BIN_DIR}/UE4SS-settings.ini" "${BIN_DIR}/MemberVariableLayout.ini" "${BIN_DIR}/Vindsent.dll"
    fi
}

add_deployed_ue4ss_file() {
    local path="$1"
    local current

    for current in "${DEPLOYED_UE4SS_FILES[@]}"; do
        if [ "${current}" = "${path}" ]; then
            return 0
        fi
    done

    DEPLOYED_UE4SS_FILES+=("${path}")
}

deploy_ue4ss_artifacts() {
    local source_dir="$1"

    if ! ue4ss_source_is_available "${source_dir}"; then
        return 0
    fi

    mkdir -p "${BIN_DIR}"

    if [ -d "${source_dir}/ue4ss" ]; then
        rm -rf "${BIN_DIR}/ue4ss"
        cp -a "${source_dir}/ue4ss" "${BIN_DIR}/"
        add_deployed_ue4ss_file "ue4ss"
    fi

    if [ -f "${source_dir}/dwmapi.dll" ]; then
        cp -f "${source_dir}/dwmapi.dll" "${BIN_DIR}/dwmapi.dll"
        add_deployed_ue4ss_file "dwmapi.dll"
    elif [ -f "${source_dir}/UE4SS.dll" ]; then
        cp -f "${source_dir}/UE4SS.dll" "${BIN_DIR}/UE4SS.dll"
        cp -f "${source_dir}/UE4SS.dll" "${BIN_DIR}/dwmapi.dll"
        add_deployed_ue4ss_file "UE4SS.dll"
        add_deployed_ue4ss_file "dwmapi.dll"
    fi

    for extra_file in "UE4SS-settings.ini" "MemberVariableLayout.ini" "Vindsent.dll"; do
        if [ -f "${source_dir}/${extra_file}" ]; then
            cp -f "${source_dir}/${extra_file}" "${BIN_DIR}/${extra_file}"
            add_deployed_ue4ss_file "${extra_file}"
        fi
    done

    if [ -d "${source_dir}/Mods" ]; then
        mkdir -p "${MODS_BASE_DIR}"
        cp -a "${source_dir}/Mods/." "${MODS_BASE_DIR}/"
        add_deployed_ue4ss_file "$(realpath --relative-to="${BIN_DIR}" "${MODS_BASE_DIR}")"
    fi
}

read_workshop_ids() {
    local ids=()
    local raw_id
    local line

    if [ -n "${WORKSHOP_MOD_IDS:-}" ]; then
        IFS=',' read -r -a raw_ids <<< "${WORKSHOP_MOD_IDS}"
        for raw_id in "${raw_ids[@]}"; do
            raw_id="$(trim "${raw_id}")"
            if [ -n "${raw_id}" ]; then
                ids+=("${raw_id}")
            fi
        done
    fi

    if [ -f "${DATA_DIR}/workshop-mods.txt" ]; then
        while IFS= read -r line || [ -n "${line:-}" ]; do
            line="${line%%#*}"
            line="$(trim "${line}")"
            if [ -n "${line}" ]; then
                ids+=("${line}")
            fi
        done < "${DATA_DIR}/workshop-mods.txt"
    fi

    printf '%s\n' "${ids[@]}" | awk 'NF && !seen[$0]++'
}

find_workshop_source_dir() {
    local mod_id="$1"
    local candidate

    for candidate in \
        "/home/steam/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${mod_id}" \
        "/home/steam/.steam/steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${mod_id}" \
        "/home/steam/.local/share/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${mod_id}"; do
        if [ -d "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    return 1
}

collect_package_name() {
    local source_dir="$1"
    local fallback_name="$2"
    local info_json="${source_dir}/Info.json"
    local package_name=""

    if [ -f "${info_json}" ]; then
        package_name="$(jq -r '.PackageName // empty' "${info_json}" 2>/dev/null || true)"
    fi

    if [ -n "${package_name}" ] && [ "${package_name}" != "null" ]; then
        printf '%s' "${package_name}"
    else
        printf '%s' "${fallback_name}"
    fi
}

copy_mod_files() {
    local source_dir="$1"
    local target_dir="$2"

    rm -rf "${target_dir}"
    mkdir -p "${target_dir}"
    cp -a "${source_dir}/." "${target_dir}/"
}

deploy_logic_paks() {
    local source_dir="$1"
    local target_dir="${DATA_DIR}/Pal/Content/Paks/LogicMods"
    local pak

    mkdir -p "${target_dir}"
    while IFS= read -r -d '' pak; do
        cp -f "${pak}" "${target_dir}/"
    done < <(find "${source_dir}" -type f -name '*.pak' -print0)
}

ensure_palmodsettings_ini() {
    local ini_file="${MODS_BASE_DIR}/PalModSettings.ini"
    local tmp_file
    tmp_file="$(mktemp)"

    mkdir -p "${MODS_BASE_DIR}"

    if [ -f "${ini_file}" ]; then
        local in_active_list=false
        while IFS= read -r line || [ -n "${line:-}" ]; do
            if [ "${line}" = "[ActiveModList]" ]; then
                in_active_list=true
                continue
            fi

            if [[ "${line}" =~ ^\[.*\]$ ]] && [ "${in_active_list}" = true ]; then
                in_active_list=false
            fi

            if [ "${in_active_list}" = true ]; then
                continue
            fi

            if [[ "${line}" =~ ^bGlobalEnableMod= ]]; then
                echo "bGlobalEnableMod=true" >> "${tmp_file}"
            else
                echo "${line}" >> "${tmp_file}"
            fi
        done < "${ini_file}"
    fi

    if [ ! -s "${tmp_file}" ]; then
        cat > "${tmp_file}" <<'EOF'
[Settings]
bGlobalEnableMod=true
EOF
    elif ! grep -q '^bGlobalEnableMod=true$' "${tmp_file}" 2>/dev/null; then
        if grep -q '^bGlobalEnableMod=' "${tmp_file}" 2>/dev/null; then
            sed -i 's/^bGlobalEnableMod=.*/bGlobalEnableMod=true/' "${tmp_file}"
        elif grep -q '^\[Settings\]$' "${tmp_file}" 2>/dev/null; then
            sed -i '/^\[Settings\]$/a bGlobalEnableMod=true' "${tmp_file}"
        else
            {
                echo '[Settings]'
                echo 'bGlobalEnableMod=true'
                echo
                cat "${tmp_file}"
            } > "${tmp_file}.new"
            mv "${tmp_file}.new" "${tmp_file}"
        fi
    fi

    {
        echo
        echo '[ActiveModList]'
        for package_name in "${ACTIVE_PACKAGES[@]}"; do
            echo "${package_name}=true"
        done
    } >> "${tmp_file}"

    mv "${tmp_file}" "${ini_file}"
    chmod 644 "${ini_file}"
}

build_state_json() {
    local workshop_json='{}'
    local native_json='{}'
    local ue4ss_files_json='[]'
    local mod_id source_dir version mod_name native_version tracked_file

    for mod_id in "${WORKSHOP_IDS[@]}"; do
        source_dir="$(find_workshop_source_dir "${mod_id}" || true)"
        if [ -n "${source_dir}" ] && [ -f "${source_dir}/Info.json" ]; then
            version="$(jq -r '.Version // "unknown"' "${source_dir}/Info.json" 2>/dev/null || echo unknown)"
        else
            version="missing"
        fi
        workshop_json="$(jq -cn --argjson base "${workshop_json}" --arg key "${mod_id}" --arg value "${version}" '$base + {($key): $value}')"
    done

    for mod_name in "${NATIVE_MOD_NAMES[@]}"; do
        source_dir="${DATA_DIR}/Mods/NativeMods/${mod_name}"
        native_version="$(find "${source_dir}" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -n 1)"
        if [ -z "${native_version}" ]; then
            native_version="missing"
        fi
        native_json="$(jq -cn --argjson base "${native_json}" --arg key "${mod_name}" --arg value "${native_version}" '$base + {($key): $value}')"
    done

    for tracked_file in "${DEPLOYED_UE4SS_FILES[@]}"; do
        ue4ss_files_json="$(jq -cn --argjson base "${ue4ss_files_json}" --arg value "${tracked_file}" '$base + [$value]')"
    done

    jq -cn \
        --argjson workshop "${workshop_json}" \
        --argjson native "${native_json}" \
        --argjson ue4ss_files "${ue4ss_files_json}" \
        --arg ue4ss_layout "${UE4SS_MODS_LAYOUT}" \
        '{workshop: $workshop, native: $native, ue4ss: {layout: $ue4ss_layout, files: $ue4ss_files}}'
}

download_workshop_mods() {
    local ids=("$@")
    local steamcmd_args=("+login")
    local login_user=""
    local login_source="anonymous"

    if [ -n "${STEAM_USERNAME:-}" ] && [ "${STEAM_USERNAME}" != "anonymous" ]; then
        login_user="$(trim "${STEAM_USERNAME}")"
        login_source="STEAM_USERNAME"
    elif [ -s "${STEAM_LOGIN_USER_FILE}" ]; then
        login_user="$(trim "$(head -n1 "${STEAM_LOGIN_USER_FILE}")")"
        login_source="${STEAM_LOGIN_USER_FILE}"
    fi

    if [ -n "${login_user}" ]; then
        steamcmd_args+=("${login_user}")
    else
        steamcmd_args+=("anonymous")
    fi

    local mod_id
    for mod_id in "${ids[@]}"; do
        steamcmd_args+=("+workshop_download_item" "${WORKSHOP_APP_ID}" "${mod_id}")
    done
    steamcmd_args+=("+quit")

    if [ "${#ids[@]}" -eq 0 ]; then
        return 0
    fi

    LogInfo "Downloading ${#ids[@]} Steam Workshop mod(s)..."
    debug_log "${STEAMCMD_BIN} +login ${login_source} +workshop_download_item ... +quit"
    if ! "${STEAMCMD_BIN}" "${steamcmd_args[@]}"; then
        LogWarn "SteamCMD reported an error while downloading workshop mods. Continuing with any files that were downloaded."
    fi
}

mapfile -t WORKSHOP_IDS < <(read_workshop_ids || true)
download_workshop_mods "${WORKSHOP_IDS[@]}"
sync_ue4ss_experimental_source

mkdir -p "${MODS_BASE_DIR}"
mkdir -p "${DATA_DIR}/Mods/NativeMods"

ACTIVE_PACKAGES=()
NATIVE_MOD_NAMES=()
DEPLOYED_UE4SS_FILES=()

cleanup_previous_ue4ss_artifacts "${previous_state}"

for mod_id in "${WORKSHOP_IDS[@]}"; do
    source_dir="$(find_workshop_source_dir "${mod_id}" || true)"
    if [ -z "${source_dir}" ]; then
        LogWarn "Workshop mod ${mod_id} was not found after download."
        continue
    fi

    dest_dir="${MODS_BASE_DIR}/Workshop/${mod_id}"
    copy_mod_files "${source_dir}" "${dest_dir}"
    deploy_logic_paks "${source_dir}"
    deploy_ue4ss_artifacts "${source_dir}"
    ACTIVE_PACKAGES+=("$(collect_package_name "${source_dir}" "${mod_id}")")
    debug_log "Deployed workshop mod ${mod_id} to ${dest_dir}"
done

while IFS= read -r -d '' mod_path; do
    mod_name="$(basename "${mod_path}")"
    dest_dir="${MODS_BASE_DIR}/${mod_name}"

    copy_mod_files "${mod_path}" "${dest_dir}"
    deploy_logic_paks "${mod_path}"
    deploy_ue4ss_artifacts "${mod_path}"
    ACTIVE_PACKAGES+=("$(collect_package_name "${mod_path}" "${mod_name}")")
    NATIVE_MOD_NAMES+=("${mod_name}")
    debug_log "Deployed native mod ${mod_name} to ${dest_dir}"
done < <(find "${DATA_DIR}/Mods/NativeMods" -mindepth 1 -maxdepth 1 -type d -print0)

ensure_palmodsettings_ini

current_state="$(build_state_json)"

printf '%s\n' "${current_state}" | jq '.' > "${STATE_FILE}"
chmod 644 "${STATE_FILE}"

debug_log "previous state: ${previous_state}"
debug_log "current state: ${current_state}"

if [ "${current_state}" = "${previous_state}" ]; then
    LogInfo "No mod changes detected."
    exit 0
fi

LogAction "Mod changes detected"

server_running=false
if pgrep -f "$(PalworldServerProcessMatch)" >/dev/null 2>&1; then
    server_running=true
fi

if [ "${server_running}" != true ]; then
    LogInfo "Server is not running yet, so no restart is required."
    exit 0
fi

if ! isTrue "${REST_API_ENABLED:-false}"; then
    LogWarn "Mod changes were detected, but REST_API_ENABLED is false. Please restart the server manually."
    exit 0
fi

if [ "$(get_player_count)" -gt 0 ]; then
    REST_API announce '{"message":"Palworld server will restart in 60 seconds for mod updates."}' >/dev/null 2>&1 || true
    sleep 60
fi

shutdown_server >/dev/null 2>&1 || LogWarn "Failed to request a graceful shutdown after mod updates."

exit 0
