#!/usr/bin/env bash
# vpn-proxy logging helpers (sourced by proxy.sh)

VP_LOG_DIR="${VP_LOG_DIR:-/var/log/vpn-proxy}"
VP_LOG_FILE="${VP_LOG_FILE:-${VP_LOG_DIR}/vpn-proxy.log}"

vp_log_init() {
    mkdir -p "$VP_LOG_DIR" 2>/dev/null || true
    touch "$VP_LOG_FILE" 2>/dev/null || true
}

_vp_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_vp_write_log() {
    local level="$1"
    shift
    vp_log_init
    if [[ -w "$VP_LOG_FILE" ]] 2>/dev/null; then
        printf '%s [%s] %s\n' "$(_vp_ts)" "$level" "$*" >>"$VP_LOG_FILE"
    fi
    logger -t vpn-proxy "$*" 2>/dev/null || true
}

vp_step() { echo "[..] $*"; _vp_write_log "STEP" "$*"; }
vp_ok()   { echo "[OK] $*"; _vp_write_log "OK" "$*"; }
vp_warn() { echo "[!!] $*" >&2; _vp_write_log "WARN" "$*"; }
vp_err()  { echo "[!!] $*" >&2; _vp_write_log "ERR" "$*"; }

vp_logs() {
    vp_log_init
    case "${1:-}" in
        -f|--follow)
            [[ -f "$VP_LOG_FILE" ]] || { vp_warn "No log at $VP_LOG_FILE"; return 1; }
            tail -f "$VP_LOG_FILE"
            ;;
        -n)
            [[ -f "$VP_LOG_FILE" ]] || { vp_warn "No log at $VP_LOG_FILE"; return 1; }
            tail -n "${2:-50}" "$VP_LOG_FILE"
            ;;
        *)
            [[ -f "$VP_LOG_FILE" ]] || { vp_warn "No log at $VP_LOG_FILE"; return 1; }
            tail -n "${1:-50}" "$VP_LOG_FILE"
            ;;
    esac
}
