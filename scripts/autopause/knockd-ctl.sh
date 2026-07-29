#!/bin/bash
# shellcheck source=scripts/helper_functions.sh
source "/home/steam/server/helper_functions.sh"

basedir="/home/steam/server/autopause"
config="${basedir}/knockd.cfg"

resolveInterfaces() {
    local interfaces="${AUTO_PAUSE_KNOCK_INTERFACES:-auto}"
    resolvedInterfaces=()

    if [ "${interfaces}" = "auto" ]; then
        # Try to detect available interfaces
        for iface in eth0 lo; do
            if ip link show "${iface}" > /dev/null 2>&1; then
                resolvedInterfaces+=("${iface}")
            fi
        done
    else
        # User-specified interfaces
        IFS=',' read -ra requested <<< "${interfaces}"
        for iface in "${requested[@]}"; do
            iface="$(echo "${iface}" | tr -d ' ')"
            if ip link show "${iface}" > /dev/null 2>&1; then
                resolvedInterfaces+=("${iface}")
            else
                LogWarn "Interface ${iface} not found, skipping."
            fi
        done
    fi
}

case "${1}" in
"start")
    if [ ! -f "${config}" ]; then
        cat - << EOF > "${config}"
[options]
 logfile = /dev/null
[resume-by-player]
 sequence = ${PORT:-8211}:udp
 seq_cooldown = 5
 command = autopause resume "LOGIN from %IP%"
[resume-by-rcon]
 sequence = ${RCON_PORT:-25575}
 seq_timeout = 1
 command = autopause resume "RCON from %IP%"
 tcpflags = syn
[resume-by-rest]
 sequence = ${REST_API_PORT:-8212}
 seq_timeout = 1
 command = autopause resume "REST_API from %IP%"
 tcpflags = syn
EOF
    fi
    resolveInterfaces
    if [ "${#resolvedInterfaces[@]}" -eq 0 ]; then
        LogWarn "AUTO_PAUSE_KNOCK_INTERFACES=${interfaces} did not resolve any usable interfaces."
        exit 1
    fi
    knockdArgs=(-d -c "${config}")
    if isTrue "${AUTO_PAUSE_DEBUG:-false}"; then
        LogInfo "AUTO_PAUSE_KNOCK_INTERFACES=\"${interfaces}\" resolved to: \"${resolvedInterfaces[*]}\""
        knockdArgs+=(-D)
    fi
    # Detects knocks coming from interfaces.
    for iface in "${resolvedInterfaces[@]}"; do
        knockd "${knockdArgs[@]}" -i "${iface}" -p "${basedir}/.knockd-${iface}.pid"
    done
    ;;
"stop")
    for pidFile in "${basedir}"/.knockd-*.pid; do
        if [ -f "${pidFile}" ]; then
            kill -KILL "$(cat "${pidFile}")"
            rm -f "${pidFile}"
        fi
    done
    ;;
*)
    echo "Usage: $(basename "${0}") <command>"
    echo "command:"
    echo "    start ... launch knockd"
    echo "    stop  ... kill knockd"
esac
