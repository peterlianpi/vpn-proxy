#!/bin/bash
# ============================================================
# Set a new Outline / Shadowsocks access key
# Usage: ./set-key.sh "ss://..."
# Decodes an access key, updates config.sh (both dev + system),
# resolves the proxy IP, and restarts the proxy.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECODER="$SCRIPT_DIR/decode-key.sh"
DEV_CONFIG="$SCRIPT_DIR/config.sh"
SYS_CONFIG="/opt/vpn-proxy/config.sh"

# Source log helpers if available
if [[ -f "$SCRIPT_DIR/lib/log.sh" ]]; then
    source "$SCRIPT_DIR/lib/log.sh"
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 \"ss://...\""
    echo ""
    echo "Example:"
    echo "  $0 \"ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwYXNzd29yZA@example.com:25266#My%20Server\""
    exit 1
fi

key="$1"

# Decode
if [[ ! -f "$DECODER" ]]; then
    echo "[ERROR] decode-key.sh not found at $DECODER"
    exit 1
fi

raw="${key#ss://}"
name=""
if [[ "$raw" == *#* ]]; then
    name="${raw#*#}"
    name=$(printf '%b' "${name//%/\\x}" 2>/dev/null || echo "$name")
    raw="${raw%%#*}"
fi

if [[ "$raw" != *@* ]]; then
    echo "[ERROR] Invalid key format — missing @"
    exit 1
fi

userinfo="${raw%%@*}"
hostport="${raw#*@}"
host="${hostport%:*}"
port="${hostport##*:}"

# Strip query params from port (e.g. 47266?security=none)
port="${port%%\?*}"

# Decode base64 userinfo -> method:password
len=${#userinfo}
pad=$(( (4 - len % 4) % 4 ))
printf -v padded "%s%${pad}s" "$userinfo" ""
padded="${padded// /=}"
decoded=$(echo "$padded" | base64 -d 2>/dev/null || echo "$padded" | openssl base64 -d 2>/dev/null)
method="${decoded%%:*}"
password="${decoded#*:}"

# Validate password isn't empty
if [[ -z "$password" || "$password" == "$decoded" ]]; then
    echo "[ERROR] Failed to decode password from userinfo"
    exit 1
fi

echo "=== New Access Key ==="
echo "  Label    : $name"
echo "  Server   : $host"
echo "  Port     : $port"
echo "  Method   : $method"
echo "  Password : $password"
echo ""

# Resolve proxy IP
proxy_ip=$(dig +short "$host" | head -1 2>/dev/null || true)
if [[ -z "$proxy_ip" ]]; then
    proxy_ip=$(getent hosts "$host" | awk '{print $1}' | head -1 2>/dev/null || true)
fi
if [[ -z "$proxy_ip" ]]; then
    echo "[WARN] Could not resolve $host — using current PROXY_IP"
    proxy_ip=""
fi

# Update config files
update_config() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then
        echo "[WARN] $cfg not found — skipping"
        return
    fi

    sed -i "s/^SS_SERVER=.*/SS_SERVER=\"$host\"/" "$cfg"
    sed -i "s/^SS_PORT=.*/SS_PORT=$port/" "$cfg"
    sed -i "s/^SS_PASSWORD=.*/SS_PASSWORD=\"$password\"/" "$cfg"
    sed -i "s/^SS_METHOD=.*/SS_METHOD=\"$method\"/" "$cfg"
    if [[ -n "$proxy_ip" ]]; then
        sed -i "s/^PROXY_IP=.*/PROXY_IP=\"$proxy_ip\"/" "$cfg"
    fi

    echo "[OK] Updated $cfg"
}

update_config "$DEV_CONFIG"

if [[ -f "$SYS_CONFIG" ]]; then
    update_config "$SYS_CONFIG"
fi

# Restart via systemd
echo "[..] Restarting vpn-proxy service..."
if systemctl is-active --quiet vpn-proxy 2>/dev/null; then
    sudo systemctl restart vpn-proxy
else
    sudo systemctl start vpn-proxy
fi

echo "[OK] vpn-proxy restarted — check: vpn-proxy status"
echo ""
echo "  Server   : $host:$port"
echo "  Method   : $method"
echo "  Name     : $name"