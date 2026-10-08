#!/bin/bash
# ============================================================
# Outline VPN Proxy — Main Control Script
# Usage: ./proxy.sh {start|stop|restart|status|refresh} [full|local|selective] [--exclude CIDR ...]
# ============================================================
set -euo pipefail

_script_path="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _script_path="$(readlink -f "$_script_path" 2>/dev/null || echo "$_script_path")"
fi
SCRIPT_DIR="$(cd "$(dirname "$_script_path")" && pwd)"

if [[ -f "$SCRIPT_DIR/lib/log.sh" ]]; then
    # shellcheck source=lib/log.sh
    source "$SCRIPT_DIR/lib/log.sh"
    vp_log_init
fi

source "$SCRIPT_DIR/config.sh"

if [[ "${DOMAINS_FILE:-domains.txt}" != /* ]]; then
    DOMAINS_FILE="$SCRIPT_DIR/${DOMAINS_FILE:-domains.txt}"
else
    DOMAINS_FILE="${DOMAINS_FILE:-$SCRIPT_DIR/domains.txt}"
fi

# NOTE: iptables changes require root (sudo). ss-redir can run as your user.
# Usage: sudo ./proxy.sh start selective   # DEFAULT — only domains in domains.txt
#        sudo ./proxy.sh start full         # all TCP (forwarded + local)
#        ./proxy.sh start local            # only this machine's TCP (OUTPUT)
#        sudo ./proxy.sh start --exclude 1.2.3.4/32

IPSET_NAME="${IPSET_NAME:-vpn_proxy_domains}"
IPSET_TIMEOUT="${IPSET_TIMEOUT:-3600}"
DOMAIN_REFRESH_INTERVAL="${DOMAIN_REFRESH_INTERVAL:-300}"
SELECTIVE_SCOPE="${SELECTIVE_SCOPE:-local}"

if [[ $EUID -eq 0 ]]; then
    PID_DIR="/run/vpn-proxy"
else
    PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/vpn-proxy"
fi
PIDFILE_SS_REDIR="$PID_DIR/ss-redir.pid"
PIDFILE_SS_LOCAL="$PID_DIR/ss-local.pid"
PIDFILE_DOMAIN_REFRESH="$PID_DIR/domain-refresh.pid"
PIDFILE_ACTIVE_MODE="$PID_DIR/active-mode"

# Where a root-run instance (the systemd unit) records its mode.
# RuntimeDirectory=vpn-proxy creates /run/vpn-proxy as 0755, so this file
# is world-readable and a non-root `status` can read it with no sudo at all.
# The override exists so the sandbox tests can point it somewhere hermetic.
ROOT_ACTIVE_MODE_FILE="${VPN_PROXY_ACTIVE_MODE_FILE:-/run/vpn-proxy/active-mode}"

# Shipped default is 'selective' (only domains.txt is proxied).
# A CLI mode (proxy.sh start full|local|selective, or --mode) is parsed
# later in parse_args() and always wins over this value, which in turn
# wins over the PROXY_MODE set in config.sh.
PROXY_MODE="${PROXY_MODE:-selective}"
# Set the moment a mode arrives on the command line. `start full` must keep
# beating everything else — including a start-request file left by an earlier
# delegation — so the request is only honoured when no CLI mode was given.
PROXY_MODE_FROM_CLI=0
RUNTIME_EXCLUDES=()
CMD=""

usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|refresh|set-key} [options]

Commands:
  start     Start ss-redir and apply iptables rules
  stop      Remove iptables rules and stop ss-redir
  restart   stop then start
  status    Show process, routing mode, and public IP
  refresh   Re-resolve domains.txt into ipset (selective mode)
  set-key   Decode and apply a new ss:// access key (config + restart)
  logs      Show log file (e.g. logs -f, logs -n 200)

Routing modes (default: config PROXY_MODE, then selective; CLI wins):
  selective   Proxy only domains listed in domains.txt (ipset) — default
  full        Proxy all TCP — forwarded + local traffic
  local       Proxy only locally-generated TCP (OUTPUT chain)

  Switch on demand:  $0 start full | $0 start local | $0 start selective
  Persist in config.sh: PROXY_MODE="full"

Options:
  --mode MODE         Routing mode: full | local | selective
  --exclude CIDR      Extra destination to bypass (repeatable)
  --domains-file PATH Domain list file (default: domains.txt)
  full|local|selective  Shorthand for --mode

Examples:
  sudo $0 start
  sudo $0 start local
  sudo $0 start selective
  sudo $0 refresh
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
            full|local|selective)
                PROXY_MODE="$1"
                PROXY_MODE_FROM_CLI=1
                shift
                ;;
            --mode)
                PROXY_MODE="${2:?--mode requires full, local, or selective}"
                PROXY_MODE_FROM_CLI=1
                shift 2
                ;;
            --domains-file)
                DOMAINS_FILE="${2:?--domains-file requires a path}"
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
        full|local|selective) ;;
        *)
            echo "[ERROR] Invalid mode '$PROXY_MODE' (use full, local, or selective)"
            exit 1
            ;;
    esac
}

require_root() {
    if ! have_root; then
        echo "[ERROR] '$1' needs root for iptables. Run: sudo $0 $*"
        exit 1
    fi
}

have_root() {
    # VP_ASSUME_ROOT is a documented TEST SEAM only: the sandbox harnesses
    # fake privilege instead of using it. Production never sets it.
    [[ $EUID -eq 0 || "${VP_ASSUME_ROOT:-0}" == "1" ]]
}

# Can this invocation actually READ the iptables rules? Only root or a
# working `sudo -n` can. Without one of those, every rule query returns
# "not found", which would be reported as a confident "no rules" — a lie.
can_verify_rules() {
    if have_root; then
        return 0
    fi
    sudo -n true >/dev/null 2>&1
}

# --- systemd delegation -------------------------------------------------
# `sudo vpn-proxy start` used to run `nohup ss-redir … &` from the user's
# terminal. That child inherits the terminal's *session* cgroup, so when the
# terminal closes logind reaps the whole session — and the proxy dies with no
# error anywhere. The fix is not "nohup harder", it is to put ss-redir inside
# /system.slice/vpn-proxy.service, where systemd (and the watchdog timer)
# own it. To do that, `start` must stop doing the work itself when a loaded
# unit points at THIS script, and hand the job to systemd instead.
VP_UNIT="${VP_UNIT:-vpn-proxy.service}"
# /run/systemd/system is the canonical place systemd keeps its own live
# unit tree. A host that has no systemd (container, WSL) has no such dir,
# which is a cheap and reliable "there is no PID 1 supervisor" probe.
VP_SYSTEMD_DIR="${VP_SYSTEMD_DIR:-/run/systemd/system}"
# The unit's ExecStart path, used to prove the unit would run THIS file and
# not some other checkout of it.
VP_UNIT_EXEC="${VP_UNIT_EXEC:-/usr/local/bin/vpn-proxy}"
# How long a written start-request stays valid. `systemctl start` cannot pass
# argv, so the requested mode and excludes travel in a file; the TTL makes a
# request that was never consumed (crash, failed start) expire instead of
# silently re-applying an old mode on a later boot.
VP_REQUEST_TTL="${VP_REQUEST_TTL:-300}"
REQUEST_FILE="${VP_REQUEST_FILE:-$PID_DIR/start-request}"

# Am I already running INSIDE the systemd unit? Two independent guards,
# because either alone can be wrong:
#   VP_SYSTEMD=1  — set by Environment= in the unit file. Survives a systemd
#                   version that forgets to export INVOCATION_ID.
#   INVOCATION_ID — set by systemd for every unit process. Survives a unit
#                   file that predates Environment= (i.e. an old install on
#                   disk that was never re-copied).
# Without BOTH guards the two paths can recurse forever: proxy.sh calls
# systemctl, whose ExecStart calls proxy.sh, which calls systemctl…
in_systemd_unit() {
    [[ "${VP_SYSTEMD:-0}" == "1" || -n "${INVOCATION_ID:-}" ]]
}

unit_load_state() {
    systemctl show -p LoadState --value "$VP_UNIT" 2>/dev/null || true
}

# 'loaded' is the only state that means systemd can actually start it.
# 'masked' / 'not-found' / '' all mean: take the direct path.
# The unit tree check is the belt to that braces: a host with no systemd at
# all (container, WSL) has no /run/systemd/system, and asking `systemctl`
# there is at best noise.
unit_available() {
    [[ -d "$VP_SYSTEMD_DIR" ]] || return 1
    [[ "$(unit_load_state)" == "loaded" ]]
}

unit_is_active() {
    [[ "$(systemctl is-active "$VP_UNIT" 2>/dev/null || true)" == "active" ]]
}

# Only delegate to a unit that would run THIS script. If the installed unit
# points at a different checkout, delegating would start that other copy.
unit_runs_this_script() {
    local unit_script
    unit_script="$(readlink -f "$VP_UNIT_EXEC" 2>/dev/null || true)"
    [[ -n "$unit_script" && "$unit_script" == "$_script_path" ]]
}

# Record what the caller asked for, because `systemctl start` cannot forward
# argv. One KEY=VALUE per line, mode + the possibly-empty exclude list.
write_start_request() {
    mkdir -p "$PID_DIR"
    (
        umask 077
        {
            printf 'ts=%s\n' "$(date +%s)"
            printf 'mode=%s\n' "$PROXY_MODE"
            printf 'script=%s\n' "$_script_path"
            printf 'excludes=%s\n' "${RUNTIME_EXCLUDES[*]-}"
        } > "$REQUEST_FILE"
    )
}

# Read the request back on the in-unit side of the delegation round trip.
# Consumes the file (single-use). Never trips `set -e` on a short or empty
# file — a truncated request must degrade to "no request", not abort start.
read_start_request() {
    [[ -s "$REQUEST_FILE" ]] || return 1

    local ts mode excludes line key value
    ts="" mode="" excludes=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            ts)       ts="$value" ;;
            mode)     mode="$value" ;;
            excludes) excludes="$value" ;;
        esac
    done < "$REQUEST_FILE"

    if [[ -z "$ts" || -z "$mode" ]]; then
        rm -f "$REQUEST_FILE"
        return 1
    fi
    if (( $(date +%s) - ts > VP_REQUEST_TTL )); then
        rm -f "$REQUEST_FILE"
        return 1
    fi

    # The delegation round trip is `systemctl start` -> ExecStart with NO argv,
    # so PROXY_MODE_FROM_CLI is 0 here and the request supplies the mode.
    # A mode given on THIS command line always wins, even over a request.
    if [[ "$PROXY_MODE_FROM_CLI" -eq 0 ]]; then
        case "$mode" in
            full|local|selective) PROXY_MODE="$mode" ;;
            *) rm -f "$REQUEST_FILE"; return 1 ;;
        esac
    fi
    if [[ -n "$excludes" ]]; then
        read -r -a RUNTIME_EXCLUDES <<< "$excludes"
    fi
    rm -f "$REQUEST_FILE"
    return 0
}

# All live ss-redir PIDs for our port, one per line. Every decision about
# "is the proxy running" and "who is supervising it" goes through this.
ss_redir_pids() {
    pgrep -f "ss-redir.*$SS_REDIR_PORT" 2>/dev/null || true
}

# Which cgroup owns the listener: vpn-proxy / manual / none.
# /proc/<pid>/cgroup is world-readable, so this needs no sudo and a plain
# `vpn-proxy status` can tell supervised from unsupervised for itself.
ss_redir_supervision() {
    local pid found=""
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        found="$found $pid"
        if [[ -r "/proc/$pid/cgroup" ]] \
           && grep -q "$VP_UNIT" "/proc/$pid/cgroup" 2>/dev/null; then
            echo "vpn-proxy"
            return 0
        fi
    done <<< "$(ss_redir_pids)"
    [[ -n "$found" ]] && echo "manual" || echo "none"
}

iptables_active() {
    if have_root; then
        iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q TPROXY \
            || iptables -t nat -L SS_REDIR -n 2>/dev/null | grep -q REDIRECT
        return
    fi

    # Non-root: iptables -L needs root, so only probe when sudo really works.
    if ! can_verify_rules; then
        return 1
    fi

    if sudo -n iptables -t mangle -C PREROUTING -p tcp -j SS_TPROXY 2>/dev/null; then
        return 0
    fi
    if sudo -n iptables -t nat -C OUTPUT -p tcp -j SS_REDIR 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_proxy_mode() {
    if [[ -f "$PIDFILE_ACTIVE_MODE" ]]; then
        cat "$PIDFILE_ACTIVE_MODE"
        return
    fi

    if ! have_root; then
        # Read the root-run state file directly — it is world-readable, so
        # this needs no sudo. The old `sudo -n test/cat/iptables` probes could
        # never succeed here and only turned "cannot check" into a confident
        # "none", which is what made a live proxy look INACTIVE.
        if [[ -r "$ROOT_ACTIVE_MODE_FILE" ]]; then
            cat "$ROOT_ACTIVE_MODE_FILE"
            return
        fi
        echo "unknown"
        return
    fi

    if iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q TPROXY; then
        if iptables -t mangle -L SS_TPROXY -n 2>/dev/null | grep -q "match-set $IPSET_NAME"; then
            echo "selective"
        else
            echo "full"
        fi
    elif iptables -t nat -L SS_REDIR -n 2>/dev/null | grep -q "match-set $IPSET_NAME"; then
        echo "selective"
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

require_ipset() {
    if ! command -v ipset >/dev/null 2>&1; then
        echo "[ERROR] ipset not found. Install: sudo apt install ipset"
        exit 1
    fi
}

read_domains() {
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        echo "[ERROR] Domain list not found: $DOMAINS_FILE"
        echo "        Copy: cp domains.txt.example domains.txt"
        exit 1
    fi
    grep -vE '^\s*($|#)' "$DOMAINS_FILE" | sed 's/#.*//' | awk 'NF {print $1}'
}

ensure_ipset() {
    require_ipset
    if ! ipset list "$IPSET_NAME" &>/dev/null; then
        ipset create "$IPSET_NAME" hash:ip family inet hashsize 4096 maxelem 65536 timeout "$IPSET_TIMEOUT"
    fi
}

resolve_domains_to_ipset() {
    local quiet="${1:-}"
    local flush="${2:-}"

    require_ipset
    ensure_ipset
    if [[ "$flush" == "flush" ]]; then
        ipset flush "$IPSET_NAME"
    fi

    local domain ip
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            ipset add "$IPSET_NAME" "$ip" -exist timeout "$IPSET_TIMEOUT"
        done < <(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    done < <(read_domains)

    if [[ "$quiet" != "quiet" ]]; then
        local set_size
        set_size=$(ipset list "$IPSET_NAME" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        echo "[OK] ipset $IPSET_NAME: $set_size entries (from $DOMAINS_FILE)"
    fi
}

destroy_ipset() {
    ipset destroy "$IPSET_NAME" 2>/dev/null || true
}

start_domain_refresh() {
    [[ "$PROXY_MODE" != "selective" ]] && return 0

    stop_domain_refresh
    (
        while true; do
            sleep "$DOMAIN_REFRESH_INTERVAL"
            resolve_domains_to_ipset quiet || true
        done
    ) &
    echo "$!" > "$PIDFILE_DOMAIN_REFRESH"
}

stop_domain_refresh() {
    if [[ -f "$PIDFILE_DOMAIN_REFRESH" ]]; then
        local pid
        pid=$(cat "$PIDFILE_DOMAIN_REFRESH" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE_DOMAIN_REFRESH"
    fi
}

write_active_mode() {
    ensure_pid_dir
    echo "$PROXY_MODE" > "$PIDFILE_ACTIVE_MODE"
}

clear_active_mode() {
    rm -f "$PIDFILE_ACTIVE_MODE"
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

    local use_tproxy=false
    if [[ "$mode" == "full" ]]; then
        use_tproxy=true
    elif [[ "$mode" == "selective" && "$SELECTIVE_SCOPE" == "full" ]]; then
        use_tproxy=true
    fi

    if $use_tproxy; then
        if [[ "$mode" == "selective" ]]; then
            iptables -t mangle -A SS_TPROXY -m set --match-set "$IPSET_NAME" dst -p tcp \
                -j TPROXY --on-port "$ss_redir_port" --tproxy-mark 1
        else
            iptables -t mangle -A SS_TPROXY -p tcp -j TPROXY --on-port "$ss_redir_port" --tproxy-mark 1
        fi
        iptables -t mangle -C PREROUTING -p tcp -j SS_TPROXY 2>/dev/null \
            || iptables -t mangle -A PREROUTING -p tcp -j SS_TPROXY
        ip rule add fwmark 1 lookup 100 priority 100 2>/dev/null || true
        ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    fi

    if [[ "$mode" == "selective" ]]; then
        iptables -t nat -A SS_REDIR -m set --match-set "$IPSET_NAME" dst -p tcp \
            -j REDIRECT --to-ports "$ss_redir_port"
    else
        iptables -t nat -A SS_REDIR -p tcp -j REDIRECT --to-ports "$ss_redir_port"
    fi
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

    stop_domain_refresh
    destroy_ipset
    clear_active_mode
}

ensure_pid_dir() {
    mkdir -p "$PID_DIR"
}

ss_redir_running() {
    [[ -n "$(ss_redir_pids)" ]]
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

ss_redir_log_file() {
    if [[ -n "${VP_LOG_DIR:-}" ]]; then
        echo "${VP_LOG_DIR}/ss-redir.log"
    elif [[ $EUID -eq 0 ]]; then
        echo "/var/log/vpn-proxy/ss-redir.log"
    else
        echo "${XDG_RUNTIME_DIR:-/tmp}/vpn-proxy/ss-redir.log"
    fi
}

wait_for_server() {
    local tries="${SS_START_DNS_TRIES:-30}"
    local delay="${SS_START_DNS_DELAY:-2}"

    while (( tries-- > 0 )); do
        if getent hosts "$SS_SERVER" >/dev/null 2>&1; then
            return 0
        fi
        if dig +short A "$SS_SERVER" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            return 0
        fi
        sleep "$delay"
    done

    echo "[ERROR] DNS not ready for $SS_SERVER (waited $((SS_START_DNS_TRIES * SS_START_DNS_DELAY))s)" >&2
    return 1
}

start_ss_redir() {
    ensure_pid_dir
    if ss_redir_running; then
        echo "[OK] ss-redir already running"
        return 0
    fi

    wait_for_server || return 1

    local log_file attempts pid
    log_file="$(ss_redir_log_file)"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    attempts="${SS_START_ATTEMPTS:-5}"

    # setsid puts the child in a brand-new session with NO controlling
    # terminal, so closing this terminal no longer gets it reaped. It is a
    # fallback, not a guarantee: logind only reaps the *session* cgroup of
    # the caller, so this keeps the process alive — but nothing restarts it
    # and `systemctl status vpn-proxy` still cannot see it. Only delegation
    # to the unit gives that, which is why cmd_start tries it first.
    local setsid_bin=""
    if [[ "${VP_NO_SETSID:-0}" != "1" ]]; then
        setsid_bin="$(command -v setsid || true)"
    fi

    echo "[..] Starting ss-redir (transparent proxy) on :$SS_REDIR_PORT ..."
    while (( attempts-- > 0 )); do
        nohup ${setsid_bin:+"$setsid_bin"} ss-redir -s "$SS_SERVER" -p "$SS_PORT" \
                       -l "$SS_REDIR_PORT" \
                       -k "$SS_PASSWORD" \
                       -m "$SS_METHOD" \
                       --no-delay >>"$log_file" 2>&1 &
        # setsid FORKS when it has a controlling terminal (an interactive
        # shell), so $! is the short-lived setsid parent, NOT ss-redir.
        # The pidfile must therefore never record $!: it is resolved from
        # the real, surviving listener after it is confirmed alive.
        sleep 3
        pid=""
        local candidate
        while read -r candidate; do
            [[ -n "$candidate" ]] || continue
            pid="$candidate"
            break
        done <<< "$(ss_redir_pids)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid" > "$PIDFILE_SS_REDIR"
            echo "[OK] ss-redir started (pid=$pid)"
            return 0
        fi
        rm -f "$PIDFILE_SS_REDIR"
        pkill -f "ss-redir.*$SS_REDIR_PORT" 2>/dev/null || true
        sleep 2
    done

    echo "[ERROR] ss-redir failed to start — see $log_file"
    [[ -f "$log_file" ]] && tail -5 "$log_file" >&2 || true
    return 1
}

describe_mode() {
    case "$PROXY_MODE" in
        full)      echo "all TCP (forwarded + local)" ;;
        local)     echo "local TCP only (OUTPUT)" ;;
        selective) echo "domains in $(basename "$DOMAINS_FILE") ($SELECTIVE_SCOPE scope)" ;;
    esac
}

# --- Start ---
cmd_start() {
    # (1) Non-root refuses BEFORE anything is created. This check used to
    # live after start_ss_redir, so a plain `vpn-proxy start` really did
    # fork an ss-redir, write a pidfile into $XDG_RUNTIME_DIR, and only
    # then exit 1 on the root check — an orphan listener with no rules,
    # unsupervised and invisible to `systemctl status`.
    if ! have_root; then
        echo "[ERROR] 'start' needs root: it writes iptables rules and owns /run/vpn-proxy."
        if unit_available; then
            echo "        Fix: sudo systemctl start $VP_UNIT"
        else
            echo "        Fix: sudo $0 start ${PROXY_MODE}"
        fi
        echo "        A plain start here would leave an unsupervised ss-redir behind,"
        echo "        which dies silently when this session closes. Nothing was created."
        exit 1
    fi

    # (2) Delegate to systemd when a loaded unit runs THIS script. This is
    # the path that makes `sudo vpn-proxy start` durable: the unit's
    # ExecStart re-enters this same script, now inside the unit's cgroup.
    # Placed before every spawn/write so this run creates nothing itself.
    if ! in_systemd_unit && unit_available && unit_runs_this_script; then
        write_start_request
        # Drop any leftover ss-redir from an earlier unsupervised direct
        # start: it would keep :$SS_REDIR_PORT bound and make the unit's own
        # ss-redir fail to bind.
        stop_ss_redir
        if systemctl start "$VP_UNIT"; then
            echo "[OK] $VP_UNIT started, supervised, watchdog armed"
            rm -f "$REQUEST_FILE"
            return 0
        fi
        # Never fall back silently: a silently-unsupervised proxy is the
        # exact failure this whole path exists to remove.
        rm -f "$REQUEST_FILE"
        echo "[ERROR] systemctl start $VP_UNIT failed — NOT falling back to an unsupervised start."
        echo "        Inspect: journalctl -u $VP_UNIT -n 30"
        return 1
    fi

    # (3) In-unit invocation (or a host with no unit to delegate to): pick
    # the requested mode back up from the delegation request file, so
    # `sudo vpn-proxy start full` still takes effect across the round trip.
    read_start_request || true

    # Check the toolchain BEFORE anything starts: a missing ipset in
    # selective mode must not leave an orphan ss-redir listening with no
    # rules behind it.
    if [[ "$PROXY_MODE" == "selective" ]]; then
        require_ipset
    fi

    start_ss_redir

    # Supervise the truth: a listener started from a terminal is not owned by
    # anything, so say so out loud on every direct (non-unit) start.
    if ! in_systemd_unit; then
        echo "[WARN] Not supervised by systemd — this ss-redir dies when this session closes."
        echo "       Fix: sudo systemctl start $VP_UNIT"
    fi

    if [[ "$PROXY_MODE" == "selective" ]]; then
        echo "[..] Resolving domains from $DOMAINS_FILE ..."
        resolve_domains_to_ipset "" flush
    fi

    local proxy_ip
    proxy_ip=$(resolve_proxy_ip)
    echo "[..] Applying transparent proxy rules (mode=$(describe_mode), exclude: $proxy_ip) ..."
    apply_tproxy "$proxy_ip" "$SS_REDIR_PORT" "$PROXY_MODE"
    write_active_mode
    start_domain_refresh
    echo "[OK] Transparent proxy active — $(describe_mode) via $SS_SERVER:$SS_PORT"
    echo ""
    if [[ "$PROXY_MODE" == "selective" ]]; then
        echo "    Only listed domains are proxied; refresh IPs: sudo $0 refresh"
    else
        echo "    SSH/RDP/LAN and excluded destinations are NOT proxied"
    fi
    echo "    To stop: sudo $0 stop"
}

# --- Stop ---
cmd_stop() {
    # Delegate to the unit when one owns this script and is ACTIVE.
    # Stopping ss-redir from here instead would leave the unit
    # `active (exited)`, and vpn-proxy-watchdog.timer would faithfully
    # restart the proxy the user just asked to stop.
    if have_root && ! in_systemd_unit && unit_available \
       && unit_runs_this_script && unit_is_active; then
        if systemctl stop "$VP_UNIT"; then
            echo "[OK] $VP_UNIT stopped — watchdog will not restart it"
            echo ""
            echo "    Internet is now DIRECT (no proxy)"
            return 0
        fi
        echo "[ERROR] systemctl stop $VP_UNIT failed — inspect: journalctl -u $VP_UNIT -n 30"
        return 1
    fi

    local rules_removed=false

    if have_root; then
        echo "[..] Removing transparent proxy rules..."
        clean_tproxy
        rules_removed=true
        echo "[OK] TPROXY rules removed"
    elif can_verify_rules && iptables_active; then
        echo "[WARN] iptables rules still active — run: sudo $0 stop"
    fi

    stop_ss_redir
    echo "[OK] ss-redir stopped"

    if $rules_removed; then
        echo ""
        echo "    Internet is now DIRECT (no proxy)"
    elif iptables_active; then
        echo ""
        echo "    [WARN] Traffic may still be redirected to :$SS_REDIR_PORT (no listener)"
        echo "    Fix: sudo $0 stop"
    else
        echo ""
        echo "    WARN Could not verify iptables without root — traffic may STILL be redirected. Run: sudo $0 stop"
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

    # Supervision truth, readable without root: /proc/<pid>/cgroup is 0444.
    local supervision unit_state
    supervision="$(ss_redir_supervision)"
    case "$supervision" in
        vpn-proxy)
            echo "  supervision: $VP_UNIT (systemd, watchdog-protected)"
            ;;
        *)
            echo "  supervision: NONE — unsupervised; dies when its session closes."
            echo "                Fix: sudo systemctl start $VP_UNIT"
            ;;
    esac
    if unit_state="$(systemctl is-active "$VP_UNIT" 2>/dev/null)" && [[ -n "$unit_state" ]]; then
        echo "  unit      : ${unit_state}"
    else
        echo "  unit      : UNKNOWN (not readable without privileges)"
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
        selective)
            tproxy_active=true
            mode_label="ACTIVE   (mode=selective — listed domains via proxy)"
            ;;
        unknown)
            mode_label="UNKNOWN  (cannot verify without root — re-run: sudo $0 status)"
            ;;
        *)
            mode_label="INACTIVE (direct connection)"
            ;;
    esac
    if [[ "$active_mode" == "none" || "$active_mode" == "unknown" ]] && ss_redir_running; then
        mode_label="UNKNOWN  (ss-redir running — sudo $0 status for rule details)"
        tproxy_active=true
    fi
    echo "  TPROXY    : $mode_label"

    if [[ "$active_mode" == "unknown" ]]; then
        echo ""
        echo "  [!] iptables rules cannot be read without root, so routing is UNKNOWN."
        echo "      UNKNOWN is NOT 'direct' — traffic may still be redirected."
        echo "      Verify with: sudo $0 status"
    fi

    if [[ "$active_mode" == "selective" ]] && have_root && ipset list "$IPSET_NAME" &>/dev/null; then
        local set_size
        set_size=$(ipset list "$IPSET_NAME" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        echo "  ipset     : $IPSET_NAME ($set_size entries)"
    fi

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

# --- Refresh domain ipset ---
cmd_refresh() {
    require_root "refresh"
    if ! ipset list "$IPSET_NAME" &>/dev/null; then
        echo "[ERROR] ipset $IPSET_NAME not active. Start selective mode first."
        exit 1
    fi
    echo "[..] Refreshing domain IPs from $DOMAINS_FILE ..."
    resolve_domains_to_ipset
}

# --- Reload (restart) ---
cmd_reload() {
    # Same delegation contract as cmd_stop: a reload must go through the
    # unit, otherwise the stop half would leave an active-but-dead unit for
    # the watchdog to "fix" on the next tick.
    if have_root && ! in_systemd_unit && unit_available \
       && unit_runs_this_script && unit_is_active; then
        write_start_request
        if systemctl restart "$VP_UNIT"; then
            echo "[OK] $VP_UNIT restarted, supervised, watchdog armed"
            rm -f "$REQUEST_FILE"
            return 0
        fi
        rm -f "$REQUEST_FILE"
        echo "[ERROR] systemctl restart $VP_UNIT failed — inspect: journalctl -u $VP_UNIT -n 30"
        return 1
    fi

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
    elif ! can_verify_rules; then
        echo "[ERROR] Could not verify iptables without root — state is UNKNOWN, not 'inactive'."
        echo "        Re-run with root to reload the routing rules: sudo $0 start [$PROXY_MODE]"
        exit 1
    else
        echo "[ERROR] iptables not active. Apply rules with: sudo $0 start [$PROXY_MODE]"
        exit 1
    fi
}

# --- Main ---
if [[ "${1:-}" == "logs" ]]; then
    shift
    if declare -F vp_logs >/dev/null 2>&1; then
        vp_logs "$@"
    else
        echo "[ERROR] Logging not installed. Run: sudo ./install.sh"
        exit 1
    fi
    exit 0
fi

parse_args "$@"

case "$CMD" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart|reload) cmd_reload ;;
    refresh) cmd_refresh ;;
    set-key)
        shift || true
        exec "$SCRIPT_DIR/set-key.sh" "$@"
        ;;
    status)  cmd_status ;;
    *)
        usage
        exit 1
        ;;
esac
