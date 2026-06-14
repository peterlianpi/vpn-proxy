#!/bin/bash
# ============================================================
# Decode an Outline / Shadowsocks access key
# Usage: ./decode-key.sh "ss://..."
# ============================================================
set -euo pipefail

decode_base64() {
    local input="$1"
    # Add padding if needed
    local len=${#input}
    local pad=$(( (4 - len % 4) % 4 ))
    printf -v padded "%s%${pad}s" "$input" ""
    padded="${padded// /=}"
    echo "$padded" | base64 -d 2>/dev/null || echo "$padded" | openssl base64 -d 2>/dev/null
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 \"ss://...\""
    echo ""
    echo "Example:"
    echo "  $0 \"ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwYXNzd29yZA@example.com:25266#My%20Server\""
    exit 1
fi

key="$1"

# Strip ss:// prefix
raw="${key#ss://}"

# Extract name (after #)
name=""
if [[ "$raw" == *#* ]]; then
    name="${raw#*#}"
    name=$(printf '%b' "${name//%/\\x}" 2>/dev/null || echo "$name")
    raw="${raw%%#*}"
fi

# Split userinfo@host:port
if [[ "$raw" == *@* ]]; then
    userinfo="${raw%%@*}"
    hostport="${raw#*@}"
    host="${hostport%:*}"
    port="${hostport##*:}"
else
    echo "[ERROR] Invalid key format — missing @"
    exit 1
fi

# Decode base64 userinfo -> method:password
decoded=$(decode_base64 "$userinfo")
method="${decoded%%:*}"
password="${decoded#*:}"

echo "=== Decoded Access Key ==="
echo ""
echo "Server  : $host"
echo "Port    : $port"
echo "Method  : $method"
echo "Password: $password"
echo "Name    : $name"
echo ""
echo "--- Config snippet ---"
echo "SS_SERVER=\"$host\""
echo "SS_PORT=$port"
echo "SS_PASSWORD=\"$password\""
echo "SS_METHOD=\"$method\""
