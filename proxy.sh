#!/bin/bash
# ============================================================
# Outline VPN Proxy — Main Control Script
# Usage: ./proxy.sh {start|stop|restart|status} [full|local] [--exclude CIDR ...]
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# NOTE: iptables changes require root (sudo). ss-redir can run as your user.
# Usage: sudo ./proxy.sh start
#        ./proxy.sh start local          # only this machine's TCP (OUTPUT)
#        ./proxy.sh start --exclude 1.2.3.4/32

if [[ $EUID -eq 0 ]]; then
    PID_DIR="/run/vpn-proxy"
else
    PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/vpn-proxy"
fi
PIDFILE_SS_REDIR="$PID_DIR/ss-redir.pid"
PIDFILE_SS_LOCAL="$PID_DIR/ss-local.pid"

PROXY_MODE="${PROXY_MODE:-full}"
RUNTIME_EXCLUDES=()
CMD=""

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status} [options]

Commands:
  start     Start ss-redir and apply iptables rules
  stop      Remove iptables rules and stop ss-redir
  restart   stop then start
  status    Show process, routing mode, and public IP

Routing modes (config: PROXY_MODE, override on CLI):
  full      Proxy all TCP — forwarded + local traffic (default)
  local     Proxy only locally-generated TCP (OUTPUT chain)

Options:
  --mode MODE       Routing mode: full | local
  --exclude CIDR    Extra destination to bypass (repeatable)
  full|local        Shorthand for --mode

Examples:
  sudo $0 start
  sudo $0 start local
  sudo $0 start --exclude 203.0.113.0/24
  $0 status
EOF
}

parse_args() {
    if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    CMD="${1:-status}"
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            full|local)
                PROXY_MODE="$1"
                shift
                ;;
            --mode)
                PROXY_MODE="${2:?--mode requires full or local}"
                shift 2
                ;;
            --exclude)
                RUNTIME_EXCLUDES+=("${2:?--exclude requires a CIDR or IP}")
                shift 2
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                echo "[ERROR] Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$PROXY_MODE" in
        full|local) ;;
        *)
            echo "[ERROR] Invalid mode '$PROXY_MODE' (use full or local)"
            exit 1
            ;;
    esac
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] '$1' needs root for iptables. Run: sudo $0 $*"
        exit 1
    fi
}

have_root() {
    [[ $EUID -eq 0 ]]
}

iptables_active() {
    if have_root; then
        iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q TPROXY \
            || iptables -t nat -L SS_REDIR -n 2>/dev/null | grep -q REDIRECT
        return
    fi

    # Non-root: iptables -L often fails; check jump rules via sudo -n if allowed
    if sudo -n iptables -t mangle -C PREROUTING -p tcp -j SS_TPROXY 2>/dev/null; then
        return 0
    fi
    if sudo -n iptables -t nat -C OUTPUT -p tcp -j SS_REDIR 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_proxy_mode() {
    if ! have_root; then
        if sudo -n iptables -t mangle -C PREROUTING -p tcp -j SS_TPROXY 2>/dev/null; then
            echo "full"
            return
        fi
        if sudo -n iptables -t nat -C OUTPUT -p tcp -j SS_REDIR 2>/dev/null; then
            echo "local"
            return
        fi
        echo "none"
        return
    fi

    if iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q TPROXY; then
        echo "full"
    elif iptables -t nat -L SS_REDIR -n 2>/dev/null | grep -q REDIRECT; then
        echo "local"
    else
        echo "none"
    fi
}

# --- Resolve proxy IP dynamically ---
resolve_proxy_ip() {
    if [[ -n "${PROXY_IP:-}" ]]; then
        echo "$PROXY_IP"
        return
    fi

    local ip
    ip=$(dig +short "$SS_SERVER" | head -1 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(getent hosts "$SS_SERVER" | awk '{print $1}' | head -1)
    fi
    if [[ -z "$ip" ]]; then
        echo "[WARN] Could not resolve $SS_SERVER — using fallback" >&2
        ip="13.115.84.100"
    fi
    echo "$ip"
}

all_excluded_ips() {
    local items=()
    local ip

    if [[ -n "${EXTRA_EXCLUDED_IPS:-}" ]]; then
        read -r -a items <<< "$EXTRA_EXCLUDED_IPS"
    fi
    if ((${#RUNTIME_EXCLUDES[@]} > 0)); then
        items+=("${RUNTIME_EXCLUDES[@]}")
    fi

    for ip in "${items[@]}"; do
        [[ -n "$ip" ]] && printf '%s\n' "$ip"
    done
}

# --- Apply iptables transparent proxy rules ---
apply_tproxy() {
    local proxy_ip="$1"
    local ss_redir_port="$2"
    local mode="$3"

    iptables -t mangle -N DIVERT 2>/dev/null || true
    iptables -t mangle -N SS_TPROXY 2>/dev/null || true
    iptables -t nat -N SS_REDIR 2>/dev/null || true

    iptables -t mangle -F DIVERT 2>/dev/null || true
    iptables -t mangle -F SS_TPROXY 2>/dev/null || true
    iptables -t nat -F SS_REDIR 2>/dev/null || true

    iptables -t mangle -A DIVERT -j MARK --set-mark 1
    iptables -t mangle -A DIVERT -j ACCEPT

    local net
    for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
               172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t mangle -A SS_TPROXY -d "$net" -j RETURN
        iptables -t nat -A SS_REDIR -d "$net" -j RETURN
    done

    if [[ -n "$proxy_ip" ]]; then
        iptables -t mangle -A SS_TPROXY -d "$proxy_ip" -j RETURN
        iptables -t nat -A SS_REDIR -d "$proxy_ip" -j RETURN
    fi
    iptables -t mangle -A SS_TPROXY -d "$SS_SERVER" -j RETURN
    iptables -t nat -A SS_REDIR -d "$SS_SERVER" -j RETURN

    for net in 162.159.198.0/24 162.159.193.0/24; do
        iptables -t mangle -A SS_TPROXY -d "$net" -j RETURN
        iptables -t nat -A SS_REDIR -d "$net" -j RETURN
    done

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        iptables -t mangle -A SS_TPROXY -d "$ip" -j RETURN
        iptables -t nat -A SS_REDIR -d "$ip" -j RETURN
    done < <(all_excluded_ips)

    if [[ "$mode" == "full" ]]; then
        iptables -t mangle -A SS_TPROXY -p tcp -j TPROXY --on-port "$ss_redir_port" --tproxy-mark 1
        iptables -t mangle -C PREROUTING -p tcp -j SS_TPROXY 2>/dev/null \
            || iptables -t mangle -A PREROUTING -p tcp -j SS_TPROXY
        ip rule add fwmark 1 lookup 100 priority 100 2>/dev/null || true
        ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    fi

    iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports "$ss_redir_port"
    iptables -t nat -C OUTPUT -p tcp -j SS_REDIR 2>/dev/null \
        || iptables -t nat -A OUTPUT -p tcp -j SS_REDIR
}

# --- Remove only our iptables rules (do not flush entire chains) ---
clean_tproxy() {
    iptables -t mangle -D PREROUTING -p tcp -j SS_TPROXY 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp -j SS_REDIR 2>/dev/null || true

    iptables -t mangle -F DIVERT 2>/dev/null || true
    iptables -t mangle -X DIVERT 2>/dev/null || true
    iptables -t mangle -F SS_TPROXY 2>/dev/null || true
    iptables -t mangle -X SS_TPROXY 2>/dev/null || true
    iptables -t nat -F SS_REDIR 2>/dev/null || true
    iptables -t nat -X SS_REDIR 2>/dev/null || true

    ip rule del fwmark 1 lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
}

ensure_pid_dir() {
    mkdir -p "$PID_DIR"
}

ss_redir_running() {
    pgrep -f "ss-redir.*$SS_REDIR_PORT" >/dev/null
}

stop_ss_redir() {
    if [[ -f "$PIDFILE_SS_REDIR" ]]; then
        local pid
        pid=$(cat "$PIDFILE_SS_REDIR" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE_SS_REDIR"
    fi

    if ss_redir_running; then
        if have_root; then
            pkill -f "ss-redir.*$SS_REDIR_PORT" 2>/dev/null || true
        else
            pkill -u "$(id -u)" -f "ss-redir.*$SS_REDIR_PORT" 2>/dev/null || true
        fi
    fi
}

start_ss_redir() {
    ensure_pid_dir
    if ss_redir_running; then
        echo "[OK] ss-redir already running"
        return 0
    fi

    echo "[..] Starting ss-redir (transparent proxy) on :$SS_REDIR_PORT ..."
    nohup ss-redir -s "$SS_SERVER" -p "$SS_PORT" \
                   -l "$SS_REDIR_PORT" \
                   -k "$SS_PASSWORD" \
                   -m "$SS_METHOD" \
                   --no-delay >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDFILE_SS_REDIR"
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "[OK] ss-redir started (pid=$pid)"
    else
        echo "[ERROR] ss-redir failed to start"
        rm -f "$PIDFILE_SS_REDIR"
        return 1
    fi
}

describe_mode() {
    case "$PROXY_MODE" in
        full)  echo "all TCP (forwarded + local)" ;;
        local) echo "local TCP only (OUTPUT)" ;;
    esac
}

# --- Start ---
cmd_start() {
    start_ss_redir

    require_root "start"

    local proxy_ip
    proxy_ip=$(resolve_proxy_ip)
    echo "[..] Applying transparent proxy rules (mode=$(describe_mode), exclude: $proxy_ip) ..."
    apply_tproxy "$proxy_ip" "$SS_REDIR_PORT" "$PROXY_MODE"
    echo "[OK] Transparent proxy active — $(describe_mode) via $SS_SERVER:$SS_PORT"
    echo ""
    echo "    SSH/RDP/LAN and excluded destinations are NOT proxied"
    echo "    To stop: sudo $0 stop"
}

# --- Stop ---
cmd_stop() {
    local rules_removed=false

    if have_root; then
        echo "[..] Removing transparent proxy rules..."
        clean_tproxy
        rules_removed=true
        echo "[OK] TPROXY rules removed"
    elif iptables_active; then
        echo "[WARN] iptables rules still active — run: sudo $0 stop"
    fi

    stop_ss_redir
    echo "[OK] ss-redir stopped"

    if ! $rules_removed && iptables_active; then
        echo ""
        echo "    [WARN] Traffic may still be redirected to :$SS_REDIR_PORT (no listener)"
        echo "    Fix: sudo $0 stop"
    else
        echo ""
        echo "    Internet is now DIRECT (no proxy)"
    fi
}

# --- Status ---
cmd_status() {
    echo "=== Outline VPN Proxy Status ==="
    echo ""

    if ss_redir_running; then
        echo "  ss-redir  : RUNNING  (:$SS_REDIR_PORT -> $SS_SERVER:$SS_PORT)"
    else
        echo "  ss-redir  : STOPPED"
    fi

    local tproxy_active=false
    local mode_label
    local active_mode
    active_mode=$(detect_proxy_mode)
    case "$active_mode" in
        full)
            tproxy_active=true
            mode_label="ACTIVE   (mode=full — all TCP via proxy)"
            ;;
        local)
            tproxy_active=true
            mode_label="ACTIVE   (mode=local — OUTPUT TCP via proxy)"
            ;;
        *)
            mode_label="INACTIVE (direct connection)"
            ;;
    esac
    if [[ "$active_mode" == "none" ]] && ss_redir_running; then
        mode_label="UNKNOWN  (ss-redir running — sudo $0 status for rule details)"
        tproxy_active=true
    fi
    echo "  TPROXY    : $mode_label"

    if $tproxy_active && ! ss_redir_running && [[ "$active_mode" != "none" ]]; then
        echo ""
        echo "  [WARN] iptables redirect active but ss-redir is down — run: sudo $0 stop"
    fi

    echo ""
    echo "--- IP Check ---"
    if ss_redir_running || $tproxy_active; then
        curl -s --connect-timeout 10 https://ipinfo.io/json 2>/dev/null || echo "(timeout)"
    else
        curl -s --connect-timeout 5 https://ipinfo.io/json 2>/dev/null || echo "(timeout)"
    fi
    echo ""
}

# --- Reload (restart) ---
cmd_reload() {
    cmd_stop
    echo ""
    if have_root; then
        cmd_start
        return
    fi

    start_ss_redir
    if iptables_active; then
        echo "[OK] ss-redir restarted (iptables rules unchanged)"
        echo ""
        echo "    To change routing mode or refresh rules: sudo $0 start [$PROXY_MODE]"
    else
        echo "[ERROR] iptables not active. Apply rules with: sudo $0 start [$PROXY_MODE]"
        exit 1
    fi
}

# --- Main ---
parse_args "$@"

case "$CMD" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart|reload) cmd_reload ;;
    status)  cmd_status ;;
    *)
        usage
        exit 1
        ;;
esac
