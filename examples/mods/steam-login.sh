#!/usr/bin/env bash
# Prepare a persistent Steam session (Steam Guard) without storing password in compose/.env.

set -euo pipefail

cd "$(dirname "$0")"

load_dotenv_value() {
  local key="$1"
  if [[ -f ".env" ]]; then
    sed -n "s/^${key}=//p" .env | tail -n1
  fi
}

STEAM_USERNAME="${STEAM_USERNAME:-$(load_dotenv_value STEAM_USERNAME)}"
STEAM_PASSWORD="${STEAM_PASSWORD:-$(load_dotenv_value STEAM_PASSWORD)}"
STEAM_SESSION_VOLUME="${STEAM_SESSION_VOLUME:-$(load_dotenv_value STEAM_SESSION_VOLUME)}"
STEAM_SESSION_VOLUME="${STEAM_SESSION_VOLUME:-${PWD}/Steam}"
STEAM_USERNAME_USER_FILE="${STEAM_USERNAME_USER_FILE:-.steam-login-user}"

if [[ -z "${STEAM_USERNAME:-}" || "${STEAM_USERNAME}" == "anonymous" ]]; then
  echo "ERROR: set STEAM_USERNAME to your Steam account name."
  echo "Example: STEAM_USERNAME=your_account ./steam-login.sh"
  exit 1
fi

if [[ "${1:-}" == "--reset" ]]; then
  echo "Wiping existing Steam session volume: ${STEAM_SESSION_VOLUME}"
  rm -rf "${STEAM_SESSION_VOLUME}"
fi

mkdir -p "${STEAM_SESSION_VOLUME}"

# Use explicit IMAGE env if provided, otherwise fallback to repository default.
IMAGE="${IMAGE:-thijsvanloef/palworld-server-docker:latest}"

echo "Using image: ${IMAGE}"
echo "Steam session volume: ${STEAM_SESSION_VOLUME}"
if [[ -n "${STEAM_PASSWORD:-}" ]]; then
  echo "Using non-interactive SteamCMD login for account: ${STEAM_USERNAME}"
else
  echo "Opening interactive SteamCMD login for account: ${STEAM_USERNAME}"
  echo "Approve Steam Guard on mobile app when prompted."
fi

docker run --rm -v "${STEAM_SESSION_VOLUME}:/home/steam/Steam" \
  --entrypoint chown "${IMAGE}" -R steam: /home/steam/Steam >/dev/null 2>&1 || true

if [[ -n "${STEAM_PASSWORD:-}" ]]; then
  docker run --rm -u steam \
    -v "${STEAM_SESSION_VOLUME}:/home/steam/Steam" \
    --entrypoint /home/steam/steamcmd/steamcmd.sh \
    "${IMAGE}" +login "${STEAM_USERNAME}" "${STEAM_PASSWORD}" +quit
else
  docker run --rm -it -u steam \
    -v "${STEAM_SESSION_VOLUME}:/home/steam/Steam" \
    --entrypoint /home/steam/steamcmd/steamcmd.sh \
    "${IMAGE}" +login "${STEAM_USERNAME}" +quit
fi

printf '%s\n' "${STEAM_USERNAME}" > "${STEAM_SESSION_VOLUME}/${STEAM_USERNAME_USER_FILE}"

echo
echo "Steam session is ready."
echo "Saved login user file: ${STEAM_SESSION_VOLUME}/${STEAM_USERNAME_USER_FILE}"
echo "Start server with the same Steam volume mounted to /home/steam/Steam."
