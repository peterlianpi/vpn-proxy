#!/usr/bin/env bash
# Wait for DNS (and optional TCP) before starting ss-redir at boot.
set -euo pipefail

_script_path="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _script_path="$(readlink -f "$_script_path" 2>/dev/null || echo "$_script_path")"
fi
SCRIPT_DIR="$(cd "$(dirname "$_script_path")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

MAX_TRIES="${VPN_PROXY_BOOT_WAIT_TRIES:-30}"
SLEEP_SEC="${VPN_PROXY_BOOT_WAIT_SLEEP:-2}"

server_ready() {
    getent hosts "$SS_SERVER" >/dev/null 2>&1 && return 0
    dig +short A "$SS_SERVER" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

for ((i = 1; i <= MAX_TRIES; i++)); do
    if server_ready; then
        if command -v nc >/dev/null 2>&1; then
            nc -z -w 3 "$SS_SERVER" "$SS_PORT" >/dev/null 2>&1 && exit 0
        else
            exit 0
        fi
    fi
    sleep "$SLEEP_SEC"
done

echo "[ERROR] Network not ready for ${SS_SERVER}:${SS_PORT} after $((MAX_TRIES * SLEEP_SEC))s" >&2
exit 1
