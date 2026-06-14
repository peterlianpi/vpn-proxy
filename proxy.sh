#!/bin/bash
# ============================================================
# Outline VPN Proxy — Main Control Script
# Usage: ./proxy.sh {start|stop|restart|status|reload}
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# NOTE: This script must be run as root (sudo) for iptables
# Usage: sudo ./proxy.sh start

PIDFILE_SS_REDIR="/tmp/ss-redir.pid"
PIDFILE_SS_LOCAL="/tmp/ss-local.pid"

# --- Resolve proxy IP dynamically ---
resolve_proxy_ip() {
    local ip
    ip=$(dig +short "$SS_SERVER" | head -1 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(getent hosts "$SS_SERVER" | awk '{print $1}' | head -1)
    fi
    if [[ -z "$ip" ]]; then
        echo "[WARN] Could not resolve $SS_SERVER — using fallback"
        ip="13.115.84.100"
    fi
    echo "$ip"
}

# --- Apply iptables transparent proxy rules ---
apply_tproxy() {
    local proxy_ip="$1"
    local ss_redir_port="$2"

    # Create chains
    iptables -t mangle -N DIVERT 2>/dev/null || true
    iptables -t mangle -N SS_TPROXY 2>/dev/null || true
    iptables -t nat -N SS_REDIR 2>/dev/null || true

    # Flush
    iptables -t mangle -F DIVERT 2>/dev/null || true
    iptables -t mangle -F SS_TPROXY 2>/dev/null || true
    iptables -t nat -F SS_REDIR 2>/dev/null || true

    # --- DIVERT chain ---
    iptables -t mangle -A DIVERT -j MARK --set-mark 1
    iptables -t mangle -A DIVERT -j ACCEPT

    # --- SS_TPROXY (PREROUTING — for non-local traffic) ---
    # Skip local / private ranges
    for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
               172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t mangle -A SS_TPROXY -d "$net" -j RETURN
    done

    # Skip the proxy server itself (anti-loop)
    if [[ -n "$proxy_ip" ]]; then
        iptables -t mangle -A SS_TPROXY -d "$proxy_ip" -j RETURN
    fi
    iptables -t mangle -A SS_TPROXY -d "$SS_SERVER" -j RETURN

    # Skip WARP infrastructure (if WARP is used alongside)
    iptables -t mangle -A SS_TPROXY -d 162.159.198.0/24 -j RETURN
    iptables -t mangle -A SS_TPROXY -d 162.159.193.0/24 -j RETURN

    # Skip extra excluded IPs
    for ip in $EXTRA_EXCLUDED_IPS; do
        iptables -t mangle -A SS_TPROXY -d "$ip" -j RETURN
    done

    # TPROXY remaining TCP traffic
    iptables -t mangle -A SS_TPROXY -p tcp -j TPROXY --on-port "$ss_redir_port" --tproxy-mark 1
    iptables -t mangle -A PREROUTING -p tcp -j SS_TPROXY

    # --- SS_REDIR (OUTPUT — for locally-generated traffic) ---
    for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
               172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A SS_REDIR -d "$net" -j RETURN
    done

    if [[ -n "$proxy_ip" ]]; then
        iptables -t nat -A SS_REDIR -d "$proxy_ip" -j RETURN
    fi
    iptables -t nat -A SS_REDIR -d "$SS_SERVER" -j RETURN

    for net in 162.159.198.0/24 162.159.193.0/24; do
        iptables -t nat -A SS_REDIR -d "$net" -j RETURN
    done

    for ip in $EXTRA_EXCLUDED_IPS; do
        iptables -t nat -A SS_REDIR -d "$ip" -j RETURN
    done

    iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports "$ss_redir_port"
    iptables -t nat -A OUTPUT -p tcp -j SS_REDIR

    # Routing: fwmark 1 -> table 100
    ip rule add fwmark 1 lookup 100 priority 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
}

# --- Remove iptables transparent proxy rules ---
clean_tproxy() {
    iptables -t mangle -F PREROUTING 2>/dev/null || true
    iptables -t mangle -F DIVERT 2>/dev/null || true
    iptables -t mangle -X DIVERT 2>/dev/null || true
    iptables -t mangle -F SS_TPROXY 2>/dev/null || true
    iptables -t mangle -X SS_TPROXY 2>/dev/null || true
    iptables -t nat -F OUTPUT 2>/dev/null || true
    iptables -t nat -F SS_REDIR 2>/dev/null || true
    iptables -t nat -X SS_REDIR 2>/dev/null || true
    ip rule del fwmark 1 lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
}

# --- Start ---
cmd_start() {
    if pgrep -f "ss-redir.*$SS_REDIR_PORT" >/dev/null; then
        echo "[OK] ss-redir already running"
    else
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
            return 1
        fi
    fi

    # Resolve proxy IP and apply iptables
    local proxy_ip
    proxy_ip=$(resolve_proxy_ip)
    echo "[..] Applying transparent proxy rules (exclude: $proxy_ip) ..."
    apply_tproxy "$proxy_ip" "$SS_REDIR_PORT"
    echo "[OK] Transparent proxy active — all TCP traffic routed through $SS_SERVER:$SS_PORT"
    echo ""
    echo "    SSH/RDP/local traffic is NOT proxied"
    echo "    To stop: ./proxy.sh stop"
}

# --- Stop ---
cmd_stop() {
    echo "[..] Removing transparent proxy rules..."
    clean_tproxy
    echo "[OK] TPROXY rules removed"

    if [[ -f "$PIDFILE_SS_REDIR" ]]; then
        kill "$(cat "$PIDFILE_SS_REDIR")" 2>/dev/null || true
        rm -f "$PIDFILE_SS_REDIR"
    fi
    pkill -f "ss-redir.*$SS_REDIR_PORT" 2>/dev/null || true
    echo "[OK] ss-redir stopped"
    echo ""
    echo "    Internet is now DIRECT (no proxy)"
}

# --- Status ---
cmd_status() {
    echo "=== Outline VPN Proxy Status ==="
    echo ""

    if pgrep -f "ss-redir.*$SS_REDIR_PORT" >/dev/null; then
        echo "  ss-redir  : RUNNING  (:$SS_REDIR_PORT -> $SS_SERVER:$SS_PORT)"
    else
        echo "  ss-redir  : STOPPED"
    fi

    local tproxy_active=false
    if iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q TPROXY; then
        echo "  TPROXY    : ACTIVE   (all TCP via proxy)"
        tproxy_active=true
    else
        echo "  TPROXY    : INACTIVE (direct connection)"
    fi

    echo ""
    echo "--- IP Check ---"
    if $tproxy_active; then
        curl -s --connect-timeout 8 https://ipinfo.io/json 2>/dev/null || echo "(timeout)"
    else
        curl -s --connect-timeout 5 https://ipinfo.io/json 2>/dev/null || echo "(timeout)"
    fi
    echo ""
}

# --- Reload (restart) ---
cmd_reload() {
    cmd_stop
    echo ""
    cmd_start
}

# --- Main ---
case "${1:-status}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart|reload) cmd_reload ;;
    status)  cmd_status ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
