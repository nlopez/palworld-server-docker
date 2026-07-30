#!/bin/bash
# shellcheck source=scripts/helper_functions.sh
source "/home/steam/server/helper_functions.sh"

# shellcheck source=scripts/negative_delta_recovery.sh
source "/home/steam/server/negative_delta_recovery.sh"

if ! ValidateNegativeDeltaRecoverySetting; then
    LogError "PALWORLD_ALLOW_NEGATIVE_DELTA_TIME must be true or false."
    exit 1
fi

# Helper Functions for installation & updates
# shellcheck source=scripts/helper_install.sh
source "/home/steam/server/helper_install.sh"

dirExists "/palworld" || exit
isWritable "/palworld" || exit
isExecutable "/palworld" || exit

cd /palworld || exit

# Get the architecture using dpkg
architecture=$(dpkg --print-architecture)
platform=$(ServerPlatform)
settings_file=$(PalworldSettingsFilePath)
settings_dir=$(dirname "${settings_file}")

clean_platform() {
    LogInfo "Cleaning up other platform files"
    (
        cd /palworld;
        ls -1A | sed -e '/^Pal$/d' | tr '\n' ' ' | xargs rm -rf;
        cd Pal;
        ls -1A | sed -e '/^Saved$/d' | tr '\n' ' ' | xargs rm -rf;
    )
}

if [ "${platform}" = "windows" ] && ( [ -f /palworld/PalServer.sh ] || [ ! -f /palworld/PalServer.exe ] ); then
    clean_platform
elif [ "${platform}" = "linux" ] && ( [ -f /palworld/PalServer.exe ] || [ ! -f /palworld/PalServer.sh ] ); then
    clean_platform
fi


ensure_windows_runtime() {
    if [ "${architecture}" != "amd64" ]; then
        LogError "SERVER_PLATFORM=Windows is supported only on amd64 hosts. Current architecture: ${architecture}."
        exit 1
    fi

    export WINEPREFIX="${WINEPREFIX:-/palworld/.wine}"
    export WINEARCH="${WINEARCH:-win64}"
    export WINEDEBUG="${WINEDEBUG:--all}"
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=;dwmapi=n,b}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/home/steam/.xdg-runtime}"

    # Ensure XDG_RUNTIME_DIR exists with proper permissions
    if [ ! -d "${XDG_RUNTIME_DIR}" ]; then
        mkdir -p "${XDG_RUNTIME_DIR}"
        chmod 700 "${XDG_RUNTIME_DIR}"
    fi

    if ! command -v wine > /dev/null 2>&1; then
        LogError "wine binary is not installed in this image. Rebuild image with Wine dependencies."
        exit 1
    fi

    if [ ! -d "${WINEPREFIX}" ] || [ ! -f "${WINEPREFIX}/.wine-initialized" ]; then
        LogAction "Initializing Wine"
        mkdir -p "${WINEPREFIX}"
        WINEDLLOVERRIDES="${WINEDLLOVERRIDES}" wineboot --init || {
            LogError "Failed to initialize Wine prefix."
            exit 1
        }
        wineserver -w || true
        touch "${WINEPREFIX}/.wine-initialized"
    fi

    local marker_file="${WINEPREFIX}/.vcrun2022-installed"
    local winetricks_runner=()

    if [ ! -f "${marker_file}" ]; then
        if command -v winetricks > /dev/null 2>&1; then
            LogAction "Installing Visual C++ runtime via winetricks"

            if command -v xvfb-run > /dev/null 2>&1; then
                LogInfo "Using xvfb-run for headless winetricks execution"
                winetricks_runner=(xvfb-run -a --server-args="${WINETRICKS_XVFB_SERVER_ARGS:--screen 0 1024x768x24}")
            else
                winetricks_runner=()
            fi

            if "${winetricks_runner[@]}" winetricks -q vcrun2022; then
                touch "${marker_file}"
            else
                LogWarn "winetricks vcrun2022 installation failed. Continuing startup."
            fi
        else
            LogWarn "winetricks binary not found. Skipping setup."
        fi
    fi
}

if [ "${platform}" = "windows" ] && [ "${architecture}" = "arm64" ]; then
    LogError "SERVER_PLATFORM=Windows is not supported on arm64. Use SERVER_PLATFORM=Linux on arm64 hosts."
    exit 1
fi

IsInstalled
ServerInstalled=$?
if [ "$ServerInstalled" == 1 ]; then
    LogInfo "Server installation not detected."
    LogAction "Starting Installation"
    InstallServer
fi

# Always update on boot even if the server is installed, to prevent appmanifest issues
if [ "$ServerInstalled" == 0 ] && [ "${UPDATE_ON_BOOT,,}" == true ]; then
    rm -f /palworld/steamapps/appmanifest_2394010.acf
    InstallServer
fi

STARTCOMMAND=()
STARTCOMMAND_NOARGS=()

if [ "${platform}" = "windows" ]; then
    ensure_windows_runtime
    server_binary="$(PalworldServerBinaryPath)"

    if ! fileExists "${server_binary}"; then
        LogError "Server Not Installed Properly"
        exit 1
    fi

    STARTCOMMAND=("wine" "${server_binary}")

    STARTCOMMAND_NOARGS=("${STARTCOMMAND[@]}")
else
    STARTCOMMAND=("./PalServer.sh")
    STARTCOMMAND_NOARGS=("./PalServer.sh")
fi

#Validate Installation
if [ "${platform}" = "linux" ] && ! fileExists "${STARTCOMMAND[0]}"; then
    LogError "Server Not Installed Properly"
    exit 1
fi

# Check if the architecture is arm64
if [ "${platform}" = "linux" ] && [ "$architecture" == "arm64" ]; then
    # create an arm64 version of ./PalServer.sh

    cp ./PalServer.sh ./PalServer-arm64.sh

    sed -i "s|\(\"\$UE_PROJECT_ROOT\/Pal\/Binaries\/Linux\/PalServer-Linux-Shipping\" Pal \"\$@\"\)|LD_LIBRARY_PATH=/home/steam/steamcmd/linux64:\$LD_LIBRARY_PATH /usr/local/bin/box64 \1|" ./PalServer-arm64.sh
    chmod +x ./PalServer-arm64.sh
    STARTCOMMAND=("./PalServer-arm64.sh")
    STARTCOMMAND_NOARGS=("./PalServer-arm64.sh")
fi

if [ "${platform}" = "linux" ]; then
    isReadable "${STARTCOMMAND[0]}" || exit
    if ! isExecutable "${STARTCOMMAND[0]}"; then
        LogWarn "Attempt to make \"${STARTCOMMAND[0]}\" executable"
        chmod +x "${STARTCOMMAND[0]}" || exit
        isExecutable "${STARTCOMMAND[0]}" || exit
    fi
fi

# Prepare Arguments
if [ -n "${PORT}" ]; then
    STARTCOMMAND+=("-port=${PORT}")
fi

if [ -n "${QUERY_PORT}" ]; then
    STARTCOMMAND+=("-queryport=${QUERY_PORT}")
fi

if [ "${COMMUNITY,,}" = true ]; then
    STARTCOMMAND+=("-publiclobby")
fi

if [ "${ENABLE_PERF_THREADING_ARGS,,}" = true ]; then
    STARTCOMMAND+=("-useperfthreads" "-NoAsyncLoadingThread" "-UseMultithreadForDS")
fi

if [ "${PALWORLD_ALLOW_NEGATIVE_DELTA_TIME,,}" = true ]; then
    STARTCOMMAND+=("-ini:Engine:[ConsoleVariables]:Pal.AllowNegativeDeltaTime=1")
fi

if [ -n "${WORKER_THREADS_SERVER}" ]; then
    STARTCOMMAND+=("-NumberOfWorkerThreadsServer=${WORKER_THREADS_SERVER}")
fi

# Backward compatibility (deprecated)
if [ "${MULTITHREADING,,}" = true ]; then
    LogWarn "MULTITHREADING is deprecated. Use ENABLE_PERF_THREADING_ARGS and WORKER_THREADS_SERVER instead."
    if [ "${ENABLE_PERF_THREADING_ARGS,,}" != true ]; then
        STARTCOMMAND+=("-useperfthreads" "-NoAsyncLoadingThread" "-UseMultithreadForDS")
    fi

    if [ -z "${WORKER_THREADS_SERVER}" ]; then
        STARTCOMMAND+=("-NumberOfWorkerThreadsServer=$(nproc --all)")
    fi
fi

if [ "${ENABLE_GAMEDATA_API,,}" = true ]; then
    STARTCOMMAND+=("-enable-gamedata-api")
fi

if [ "${NOSTEAM,,}" = true ]; then
    STARTCOMMAND+=("-nosteam")
fi

LogAction "Checking for available container updates"
container_version_check

if [ "${DISABLE_GENERATE_SETTINGS,,}" = true ]; then
  LogAction "GENERATING CONFIG"
  LogWarn "Env vars will not be applied due to DISABLE_GENERATE_SETTINGS being set to TRUE!"
  mkdir -p "${settings_dir}" || exit

  # shellcheck disable=SC2143
  if [ ! "$(grep -s '[^[:space:]]' "${settings_file}")" ]; then
      LogAction "GENERATING CONFIG"
      # Server will generate all ini files after first run.
      timeout --preserve-status 15s "${STARTCOMMAND_NOARGS[@]}" 1> /dev/null

      # Wait for shutdown
      sleep 5
      cp /palworld/DefaultPalWorldSettings.ini "${settings_file}"
  fi
else
  LogAction "GENERATING CONFIG"
  LogInfo "Using Env vars to create PalWorldSettings.ini"
  /home/steam/server/compile-settings.sh || exit
fi

if [ "${DISABLE_GENERATE_ENGINE,,}" = false ]; then
    /home/steam/server/compile-engine.sh || exit
fi

if [ "${platform}" = "windows" ]; then
    LogAction "Syncing workshop mods"
    mods-update || exit
fi

LogAction "GENERATING CRONTAB"
truncate -s 0  "/home/steam/server/crontab"

if [ "${BACKUP_ENABLED,,}" = true ]; then
    LogInfo "BACKUP_ENABLED=${BACKUP_ENABLED,,}"
    LogInfo "Adding cronjob for auto backups"
    echo "$BACKUP_CRON_EXPRESSION bash /usr/local/bin/backup" >> "/home/steam/server/crontab"
    supercronic -quiet -test -no-reap "/home/steam/server/crontab" || exit
fi

if [ "${AUTO_UPDATE_ENABLED,,}" = true ] && [ "${UPDATE_ON_BOOT}" = true ]; then
    LogInfo "AUTO_UPDATE_ENABLED=${AUTO_UPDATE_ENABLED,,}"
    LogInfo "Adding cronjob for auto updating"
    echo "$AUTO_UPDATE_CRON_EXPRESSION bash /usr/local/bin/update" >> "/home/steam/server/crontab"
    supercronic -quiet -test -no-reap "/home/steam/server/crontab" || exit
fi

if [ "${AUTO_REBOOT_ENABLED,,}" = true ] && [ "${REST_API_ENABLED,,}" = true ]; then
    LogInfo "AUTO_REBOOT_ENABLED=${AUTO_REBOOT_ENABLED,,}"
    LogInfo "Adding cronjob for auto rebooting via REST API"
    echo "$AUTO_REBOOT_CRON_EXPRESSION bash /home/steam/server/auto_reboot.sh" >> "/home/steam/server/crontab"
    supercronic -quiet -test -no-reap "/home/steam/server/crontab" || exit
fi

if [ "${platform}" = "windows" ] && [ -n "${WORKSHOP_MOD_UPDATE_CRON:-}" ]; then
    LogInfo "WORKSHOP_MOD_UPDATE_CRON=${WORKSHOP_MOD_UPDATE_CRON}"
    LogInfo "Adding cronjob for workshop mod updates"
    echo "$WORKSHOP_MOD_UPDATE_CRON bash /home/steam/server/mods/update.sh" >> "/home/steam/server/crontab"
    supercronic -quiet -test -no-reap "/home/steam/server/crontab" || exit
fi

if [ -s "/home/steam/server/crontab" ]; then
    supercronic -passthrough-logs -no-reap "/home/steam/server/crontab" &
    LogInfo "Cronjobs started"
else
    LogInfo "No Cronjobs found"
fi

# Configure RCON settings.
# DEPRECATED: RCON will be removed in a future release.
cat >/home/steam/server/rcon.yaml  <<EOL
default:
  address: "127.0.0.1:${RCON_PORT}"
  password: "${ADMIN_PASSWORD}"
EOL

CHILD_PIDS=()
if PlayerLogging_isEnabled; then
    if [[ "$(id -u)" -eq 0 ]]; then
        su steam -c /home/steam/server/player_logging.sh &
    else
        /home/steam/server/player_logging.sh &
    fi
    CHILD_PIDS+=($!)
fi

LogAction "Starting Server"
DiscordMessage "Start" "${DISCORD_PRE_START_MESSAGE}" "success" "${DISCORD_PRE_START_MESSAGE_ENABLED}" "${DISCORD_PRE_START_MESSAGE_URL}"

echo "${STARTCOMMAND[*]}"
"${STARTCOMMAND[@]}"

LogAction "Ending Server"
if [ ${#CHILD_PIDS[@]} -ne 0 ]; then
    wait "${CHILD_PIDS[@]}"
fi

DiscordMessage "Stop" "${DISCORD_POST_SHUTDOWN_MESSAGE}" "failure" "${DISCORD_POST_SHUTDOWN_MESSAGE_ENABLED}" "${DISCORD_POST_SHUTDOWN_MESSAGE_URL}"
exit 0
