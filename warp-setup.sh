#!/bin/bash
# ============================================================
# WARP through Outline Proxy Setup
# Registers and connects WARP via Japan proxy
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== WARP + Outline Setup ==="
echo ""

# 1. Ensure proxy is running
echo "[1/4] Starting Outline proxy..."
"$SCRIPT_DIR/proxy.sh" start
echo ""

# 2. Register WARP (API call goes through Japan proxy)
echo "[2/4] Registering WARP..."
warp-cli --accept-tos registration delete 2>/dev/null || true
warp-cli --accept-tos registration new
echo ""

# 3. Connect WARP
echo "[3/4] Connecting WARP..."
warp-cli connect
sleep 3
echo ""

# 4. Verify
echo "[4/4] Verifying..."
warp-cli status
echo ""

echo "=== Done ==="
echo "WARP tunnel is active through Outline/Japan"
echo ""
echo "Traffic flow:"
echo "  App -> WARP tunnel -> Outline proxy (Japan) -> Internet"
echo ""
echo "To disable:  warp-cli disconnect"
echo "To stop VPN: $SCRIPT_DIR/proxy.sh stop"
