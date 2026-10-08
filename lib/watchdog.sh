#!/usr/bin/env bash
# ============================================================
# vpn-proxy watchdog — self-heal check for the vpn-proxy unit
#
# Driven by vpn-proxy-watchdog.timer (oneshot, ~every 60s).
#
# Contract:
#   * The unit is active  -> check ss-redir, iptables and (in selective
#     mode) the ipset. If any of them is dead, restart the unit.
#   * The unit is NOT active -> exit 0 immediately. An intentional
#     `systemctl stop vpn-proxy` is NEVER undone by the watchdog.
#
# Why this exists: vpn-proxy.service is Type=oneshot + RemainAfterExit,
# so once `start` returned 0 systemd reports `active (exited)` forever.
# Restart=on-failure can never fire after a success, so a later ss-redir
# death (or a reboot that lost the ipset) left a "green" unit with no
# proxy running. This script is the self-heal for that gap.
#
# Run manually:  sudo /opt/vpn-proxy/lib/watchdog.sh
# ============================================================
set -uo pipefail

UNIT="${VPN_PROXY_UNIT:-vpn-proxy}"
PID_DIR="/run/${UNIT}"
PIDFILE_ACTIVE_MODE="$PID_DIR/active-mode"

# Grace period between the liveness check and the restart, so a restart
# that is already in flight is not fought with.
SETTLE_SECONDS="${VPN_PROXY_WATCHDOG_SETTLE:-2}"

_script_path="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _script_path="$(readlink -f "$_script_path" 2>/dev/null || echo "$_script_path")"
fi
SCRIPT_DIR="$(cd "$(dirname "$_script_path")" && pwd)"

if [[ -f "$SCRIPT_DIR/log.sh" ]]; then
    # shellcheck source=log.sh
    source "$SCRIPT_DIR/log.sh"
    vp_log_init
else
    vp_warn() { echo "[!!] $*" >&2; }
    vp_ok()   { echo "[OK] $*"; }
fi

CONFIG_FILE="${VPN_PROXY_CONFIG:-$SCRIPT_DIR/../config.sh}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=../config.sh
    source "$CONFIG_FILE"
fi

SS_REDIR_PORT="${SS_REDIR_PORT:-10800}"
IPSET_NAME="${IPSET_NAME:-vpn_proxy_domains}"

log_warn() { vp_warn "$*"; logger -t vpn-proxy-watchdog "$*" 2>/dev/null || true; }

unit_active() {
    systemctl is-active --quiet "$UNIT"
}

ss_redir_running() {
    pgrep -f "ss-redir.*$SS_REDIR_PORT" >/dev/null 2>&1
}

# The nat OUTPUT jump is installed by every mode (full/local/selective).
# If iptables is not installed we cannot verify, so we do not call it
# unhealthy — better a missed restart than a permanent restart loop.
nat_rules_ok() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    iptables -t nat -C OUTPUT -p tcp -j SS_REDIR >/dev/null 2>&1
}

active_mode() {
    if [[ -r "$PIDFILE_ACTIVE_MODE" ]]; then
        cat "$PIDFILE_ACTIVE_MODE" 2>/dev/null && return
    fi
    # No sudo fallback: the watchdog runs as root under
    # vpn-proxy-watchdog.service, so an unreadable file means it is gone.
    echo "${PROXY_MODE:-unknown}"
}

# --- Guard 1: intentional stop ------------------------------------------
if ! unit_active; then
    echo "[..] $UNIT is not active — intentional stop, nothing to heal."
    exit 0
fi

# --- Guard 2: re-check after a short settle ----------------------------
# If the unit is being restarted/stopped right now, leave it alone.
sleep "$SETTLE_SECONDS"
if ! unit_active; then
    echo "[..] $UNIT stopped during the check — leaving it alone."
    exit 0
fi

# --- Guard 3: re-check immediately before acting ------------------------
health=()
ss_redir_running || health+=("ss-redir not running on :$SS_REDIR_PORT")
nat_rules_ok   || health+=("nat OUTPUT -> SS_REDIR rule missing")
if [[ "$(active_mode)" == "selective" ]]; then
    # `command -v ipset` guards the check: on a host without ipset a missing
    # set is not evidence of a degraded proxy, and treating it as one would
    # restart the unit every 60s forever — a loop no restart can satisfy.
    if ! ipset list "$IPSET_NAME" &>/dev/null && command -v ipset >/dev/null 2>&1; then
        health+=("ipset $IPSET_NAME missing (selective mode)")
    fi
fi

if ((${#health[@]} == 0)); then
    echo "[OK] $UNIT healthy (mode=$(active_mode))"
    exit 0
fi

log_warn "$UNIT is active but degraded: ${health[*]} — restarting"

# --- Guard 4: last chance, right before the restart --------------------
if ! unit_active; then
    echo "[..] $UNIT became inactive before the restart — honouring the stop."
    exit 0
fi

if systemctl restart "$UNIT"; then
    vp_ok "$UNIT restarted by watchdog (${health[*]})"
else
    log_warn "watchdog could not restart $UNIT (see: journalctl -u $UNIT)"
fi
exit 0