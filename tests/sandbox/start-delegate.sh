#!/usr/bin/env bash
# ============================================================
# Sandbox harness: `start` must hand the work to systemd.
#
# Run it:
#   bash tests/sandbox/start-delegate.sh
#   ./tests/sandbox/start-delegate.sh          (it is chmod +x)
#
# Why: `sudo vpn-proxy start` used to run `nohup ss-redir … &` from the
# user's own terminal. That child inherits the terminal's SESSION cgroup,
# so closing the terminal makes logind reap the whole session — the proxy
# dies, silently, and `systemctl status vpn-proxy` shows nothing. The fix
# is delegation: when a loaded unit points at this script, `start` must
# call `systemctl start` and do no work of its own.
#
# What could silently regress, and is asserted here:
#   * delegation that recurses forever (ExecStart -> systemctl -> ExecStart)
#   * a non-root `start` that leaves an orphan listener behind
#   * a silent fallback to an unsupervised start when systemctl fails
#   * a direct-path start whose pidfile holds the short-lived setsid parent
#   * `start full` losing its mode across the delegation round trip
#   * `stop` leaving the unit active so the watchdog resurrects the proxy
#   * a redundant `start` killing the healthy supervised ss-redir, which a
#     `systemctl start` on an ACTIVE oneshot unit cannot replace (see [2b])
#   * a malformed/empty request file aborting the in-unit start or stranding
#     /run/vpn-proxy/start-request (see [10b], [10c])
#
# Everything is faked on PATH and lives in mktemp dirs; nothing on the
# host is touched and no credential is ever printed. `pgrep`/`pkill` are
# deliberately NOT faked: resolving the real listener PID is the point.
# ============================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/../.." && pwd)"
PROXY_SH="${REPO_DIR}/proxy.sh"

if [[ ! -f "$PROXY_SH" ]]; then
    echo "[!!] proxy.sh not found at ${PROXY_SH}" >&2
    exit 2
fi
if [[ ! -f "${REPO_DIR}/config.sh" ]]; then
    echo "[!!] ${REPO_DIR}/config.sh is missing." >&2
    echo "    cp config.sh.example config.sh" >&2
    exit 2
fi

PASS=0
FAIL=0
SANDBOX_DIR=""

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        bad "$label (expected to find: ${needle})"
        printf '       --- actual output ---\n%s\n       ----------------------\n' "$haystack"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        bad "$label (must NOT contain: ${needle})"
        printf '       --- actual output ---\n%s\n       ----------------------\n' "$haystack"
    fi
}

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label (expected '${want}', got '${got}')"
    fi
}

assert_file_absent() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        bad "$label (unexpectedly exists: ${path})"
    else
        ok "$label"
    fi
}

assert_file_present() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        ok "$label"
    else
        bad "$label (missing: ${path})"
    fi
}

# --- sandbox construction -------------------------------------------------
# prepare <unit_flavour> <setsid_mode>   — runs in the PARENT so the fakes
# and their paths survive into the assertions below.
#   loaded     LoadState=loaded, inactive, ExecStart -> this proxy.sh
#   active     LoadState=loaded, IS active
#   masked     LoadState=masked (systemd refuses to start it)
#   foreign    LoadState=loaded but ExecStart points at another file
#   no-systemd LoadState=loaded but /run/systemd/system does not exist
prepare() {
    local flavour="$1" setsid_mode="$2"
    teardown_sandbox

    SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vp-delegate.XXXXXX")"
    mkdir -p "${SANDBOX_DIR}/bin" "${SANDBOX_DIR}/run/vpn-proxy" \
             "${SANDBOX_DIR}/xdg/vpn-proxy" "${SANDBOX_DIR}/log" \
             "${SANDBOX_DIR}/repo/lib"

    CALL_LOG="${SANDBOX_DIR}/calls.log"
    SS_PID_FILE="${SANDBOX_DIR}/ss-redir.pid"
    STATE_FILE="${SANDBOX_DIR}/unit.state"
    REQUEST="${SANDBOX_DIR}/run/vpn-proxy/start-request"
    OUT_FILE="${SANDBOX_DIR}/proxy.out"
    : > "$CALL_LOG"

    # The fake systemctl's notion of unit state. Seeded from the flavour so
    # every existing scenario starts from the state it used to fake from
    # the flavour string alone.
    case "$flavour" in
        active) echo active > "$STATE_FILE" ;;
        *)      echo inactive > "$STATE_FILE" ;;
    esac

    # A private COPY of the script, with its own config.sh. Two reasons,
    # both about not lying to the operator:
    #  * proxy.sh sources config.sh from its own directory, and that file
    #    holds the REAL ss:// password — a sandbox that sourced it could
    #    print it. Here the password is a placeholder that matches nothing.
    #  * SS_REDIR_PORT is given a port unique to this run. proxy.sh finds
    #    the listener with `pgrep -f "ss-redir.*:$SS_REDIR_PORT"`, so on a
    #    host with the REAL proxy running the sandbox would otherwise see
    #    the live ss-redir as its own, and every "is it running?" assertion
    #    would be answering about the production process.
    cp "${PROXY_SH}" "${SANDBOX_DIR}/repo/proxy.sh"
    cp "${REPO_DIR}"/lib/*.sh "${SANDBOX_DIR}/repo/lib/" 2>/dev/null || true
    cp "${REPO_DIR}/set-key.sh" "${SANDBOX_DIR}/repo/" 2>/dev/null || true
    SB_PROXY="${SANDBOX_DIR}/repo/proxy.sh"
    SB_PORT="$(( 20000 + (RANDOM % 20000) ))"   # unique per run: never collides with a real listener
    cat > "${SANDBOX_DIR}/repo/config.sh" <<EOS
#!/bin/bash
# Sandbox config — placeholder credentials, no real key, private port.
SS_SERVER="sandbox.invalid"
SS_PORT=9999
SS_PASSWORD="sandbox-placeholder-not-a-real-key"
SS_METHOD="chacha20-ietf-poly1305"
SS_REDIR_PORT=${SB_PORT}
SS_SOCKS_PORT=1081
PROXY_IP="203.0.113.9"
EXTRA_EXCLUDED_IPS=""
PROXY_MODE="selective"
EOS

    # Exported for the fakes, which read them at RUN time (their heredocs
    # are quoted, so nothing is baked in at creation time).
    export CALL_LOG SS_PID_FILE
    export FAKE_STATE_FILE="$STATE_FILE"
    export FAKE_UNIT_FLAVOUR="$flavour"
    case "$flavour" in
        masked) export FAKE_LOAD_STATE="masked" ;;
        *)      export FAKE_LOAD_STATE="loaded" ;;
    esac
    case "$flavour" in
        no-systemd) export FAKE_SYSTEMD_DIR="${SANDBOX_DIR}/no-systemd-here" ;;
        *)          export FAKE_SYSTEMD_DIR="${SANDBOX_DIR}/run" ;;
    esac
    if [[ "$flavour" == "foreign" ]]; then
        export FAKE_UNIT_EXEC="${SANDBOX_DIR}/some-other-copy.sh"
    else
        export FAKE_UNIT_EXEC="$SB_PROXY"
    fi

    # fake systemctl -------------------------------------------------------
    # LoadState is what unit_available() reads; every call is logged.
    # With VP_SYSTEMCTL_EXEC=1 it also RUNS the unit's ExecStart the way
    # systemd would (VP_SYSTEMD=1 + INVOCATION_ID), so the delegation round
    # trip is exercised for real instead of mocked.
    #
    # It models a Type=oneshot + RemainAfterExit=yes unit with a state
    # FILE, because that is the whole point: on real systemd `start` on an
    # already-ACTIVE oneshot unit is a NO-OP — ExecStart is NOT re-run.
    # An earlier version of this fake always ran ExecStart, so it could not
    # model the bug this harness now guards (see [2b]).
    cat > "${SANDBOX_DIR}/bin/systemctl" <<'EOS'
#!/bin/sh
echo "systemctl $*" >> "$CALL_LOG"

STATE_FILE="$FAKE_STATE_FILE"
[ -f "$STATE_FILE" ] || echo inactive > "$STATE_FILE"
unit_state() { cat "$STATE_FILE" 2>/dev/null || echo inactive; }

case "$1" in
    show)
        echo "$FAKE_LOAD_STATE"
        exit 0
        ;;
    is-active)
        s="$(unit_state)"
        [ "$s" = "active" ] && { echo active; exit 0; }
        echo "$s"
        exit 3
        ;;
    start|stop|restart)
        [ "${VP_SYSTEMCTL_EXIT:-0}" != "0" ] && exit "$VP_SYSTEMCTL_EXIT"
        if [ "$1" = "start" ] && [ "$(unit_state)" = "active" ]; then
            # REAL systemd: starting an ALREADY-ACTIVE oneshot unit is a
            # no-op. ExecStart is NOT re-run, so an ss-redir the CLI killed
            # a moment earlier stays dead.
            exit 0
        fi
        job=start
        [ "$1" = "stop" ] && job=stop
        if [ "${VP_SYSTEMCTL_EXEC:-0}" = "1" ]; then
            VP_SYSTEMD=1 INVOCATION_ID=fake-invocation \
                "$FAKE_UNIT_EXEC" "$job" >> "$CALL_LOG" 2>&1
            rc=$?
            [ "$rc" -ne 0 ] && exit "$rc"
        fi
        # RemainAfterExit=yes: the unit reads active after a successful
        # ExecStart, and inactive after a clean ExecStop.
        if [ "$job" = "stop" ]; then echo inactive > "$STATE_FILE"
        else echo active > "$STATE_FILE"; fi
        exit 0
        ;;
esac
exit 0
EOS

    # fake setsid ----------------------------------------------------------
    # Real setsid FORKS when it has a controlling terminal. The fake does
    # the same and exits at once: $! after `setsid …` is this short-lived
    # parent, NOT ss-redir. Catching that is the point of this harness.
    if [[ "$setsid_mode" == "setsid" ]]; then
        cat > "${SANDBOX_DIR}/bin/setsid" <<'EOS'
#!/bin/sh
echo "setsid: new session leader $$" >&2
"$@" &
exit 0
EOS
    fi

    # fake ss-redir --------------------------------------------------------
    # A real, long-lived process (so pgrep/kill -0 act on it). It records
    # its own PID so teardown can kill exactly it.
    cat > "${SANDBOX_DIR}/bin/ss-redir" <<'EOS'
#!/bin/sh
echo "ss-redir $*" >> "$CALL_LOG"
echo $$ > "$SS_PID_FILE"
# Stay as THIS process: proxy.sh finds the listener with
# `pgrep -f "ss-redir.*:$SS_REDIR_PORT"`, so exec'ing another binary
# would rename it and the lookup would fail.
while :; do sleep 1; done
EOS

    # fake sudo ------------------------------------------------------------
    cat > "${SANDBOX_DIR}/bin/sudo" <<'EOS'
#!/bin/sh
echo "sudo $*" >> "$CALL_LOG"
[ "$1" = "-n" ] && shift
exec "$@"
EOS

    # fake ipset / iptables / dig / curl / logger --------------------------
    cat > "${SANDBOX_DIR}/bin/ipset" <<'EOS'
#!/bin/sh
echo "ipset $*" >> "$CALL_LOG"
case "$1" in
    list) echo "Number of entries: 2"; echo "1.2.3.4"; echo "5.6.7.8"; exit 0 ;;
    *) exit 0 ;;
esac
EOS
    cat > "${SANDBOX_DIR}/bin/iptables" <<'EOS'
#!/bin/sh
echo "iptables $*" >> "$CALL_LOG"
exit 0
EOS
    cat > "${SANDBOX_DIR}/bin/dig" <<'EOS'
#!/bin/sh
echo "1.2.3.4"
exit 0
EOS
    cat > "${SANDBOX_DIR}/bin/curl" <<'EOS'
#!/bin/sh
echo '{"ip":"203.0.113.9"}'
exit 0
EOS
    cat > "${SANDBOX_DIR}/bin/logger" <<'EOS'
#!/bin/sh
exit 0
EOS

    chmod +x "${SANDBOX_DIR}/bin/"*
}

teardown_sandbox() {
    local p
    # Kill the background domain-refresh loop proxy.sh leaves behind, then
    # the fake ss-redir, by the PIDs the sandbox itself recorded.
    p="$(cat "${SANDBOX_DIR:-/nonexistent}/xdg/vpn-proxy/domain-refresh.pid" 2>/dev/null || true)"
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
    if [[ -n "${SS_PID_FILE:-}" && -f "$SS_PID_FILE" ]]; then
        p="$(cat "$SS_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$p" ]]; then kill "$p" 2>/dev/null || true; fi
    fi
    if [[ -n "${SANDBOX_DIR:-}" && -d "$SANDBOX_DIR" ]]; then
        # Scoped to this sandbox's own binary path, so a REAL ss-redir on
        # the host is never touched.
        pkill -f "${SANDBOX_DIR}/bin/ss-redir" 2>/dev/null || true
        rm -rf "$SANDBOX_DIR"
    fi
    SANDBOX_DIR=""
}

# Count call-log lines matching a grep BRE.
count_calls() {
    grep -c -- "$1" "$CALL_LOG" 2>/dev/null || true
}

# Paths a refused `start` must never create.
assert_nothing_created() {
    local label="$1"
    assert_file_absent "${SANDBOX_DIR}/xdg/vpn-proxy/ss-redir.pid" "$label: no ss-redir pidfile"
    assert_file_absent "${SANDBOX_DIR}/xdg/vpn-proxy/domain-refresh.pid" "$label: no domain-refresh pidfile"
    assert_file_absent "${SANDBOX_DIR}/xdg/vpn-proxy/active-mode" "$label: no active-mode file"
    assert_file_absent "$REQUEST" "$label: no start-request file"
    assert_eq "$(count_calls '^ss-redir ')" "0" "$label: no ss-redir process spawned"
    assert_eq "$(count_calls '^ipset ')" "0" "$label: no ipset touched"
}

# run_proxy <root:yes|no> [VAR=val ...] -- <args...>
# The sandbox must already exist (prepare runs in the parent).
run_proxy() {
    local root="$1"; shift
    local -a envs=(
        "PATH=${SANDBOX_DIR}/bin:${PATH}"
        "XDG_RUNTIME_DIR=${SANDBOX_DIR}/xdg"
        "VPN_PROXY_ACTIVE_MODE_FILE=${SANDBOX_DIR}/run/vpn-proxy/active-mode"
        "VP_LOG_DIR=${SANDBOX_DIR}/log"
        "VP_LOG_FILE=${SANDBOX_DIR}/log/vpn-proxy.log"
        "VP_SYSTEMD_DIR=${FAKE_SYSTEMD_DIR}"
        "VP_REQUEST_FILE=${REQUEST}"
        "VP_UNIT_EXEC=${FAKE_UNIT_EXEC}"
        "SS_START_ATTEMPTS=1"
        "SS_START_DNS_TRIES=1"
        "SS_START_DNS_DELAY=0"
    )
    [[ "$root" == "yes" ]] && envs+=("VP_ASSUME_ROOT=1") || envs+=("VP_ASSUME_ROOT=0")

    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift

    # Output goes to a FILE, never through $( ): start_domain_refresh leaves a
    # background subshell alive, and a command substitution waits for every
    # writer on its pipe to close — which would hang the harness, not the proxy.
    env "${envs[@]}" bash "$SB_PROXY" "$@" > "$OUT_FILE" 2>&1
    RUN_RC=$?
    cat "$OUT_FILE"
    return "$RUN_RC"
}

# run_in_unit <args...> — simulate the ExecStart side of the delegation.
run_in_unit() {
    run_proxy yes VP_SYSTEMD=1 -- "$@"
}

echo "=== start-delegate sandbox (systemd delegation, setsid fallback) ==="
echo "repo: ${REPO_DIR}"
echo "user: $(id -un) (uid=$(id -u))"
echo

# --------------------------------------------------------------------------
echo "[1] non-root 'start' refuses BEFORE creating anything"
prepare loaded setsid
out="$(run_proxy no -- start)"
assert_contains "$out" "[ERROR] 'start' needs root" "start refuses without root"
assert_contains "$out" "sudo systemctl start vpn-proxy.service" "start suggests the systemd fix"
assert_contains "$out" "Nothing was created" "start says it created nothing"
assert_not_contains "$out" "ss-redir started" "no ss-redir was started"
assert_nothing_created "non-root start"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[2] root + loaded unit -> exactly one 'systemctl start', zero direct spawn"
prepare loaded setsid
out="$(run_proxy yes -- start)"
assert_contains "$out" "supervised, watchdog armed" "start reports supervision"
assert_eq "$(count_calls '^systemctl start vpn-proxy\.service$')" "1" "exactly one systemctl start"
assert_eq "$(count_calls '^ss-redir ')" "0" "no direct ss-redir spawn"
assert_eq "$(count_calls '^ipset ')" "0" "no direct ipset work"
assert_eq "$(count_calls '^iptables ')" "0" "no direct iptables work"
assert_not_contains "$out" "Not supervised by systemd" "no unsupervised warning on the delegated path"
assert_file_absent "${SANDBOX_DIR}/xdg/vpn-proxy/ss-redir.pid" "the CLI itself writes no pidfile; the unit's run does"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[2b] a SECOND start on an already-active unit kills nothing (idempotent)"
# Regression, and the reason this harness fake exists. Real systemd: `start`
# on an ACTIVE Type=oneshot + RemainAfterExit=yes unit is a NO-OP — ExecStart
# is NOT re-run. cmd_start used to call stop_ss_redir BEFORE `systemctl start`
# on every run, so a redundant `sudo vpn-proxy start` killed the healthy
# supervised ss-redir, nothing replaced it, and the command still printed
# "[OK] … started" and exited 0. Reproduced twice against real systemd.
prepare loaded setsid
out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- start)"
first_pid="$(cat "$SS_PID_FILE" 2>/dev/null || true)"
calls="$(cat "$CALL_LOG")"
assert_contains "$calls" "[OK] Transparent proxy active" "the first start really ran the unit"
assert_eq "$(count_calls '^ss-redir ')" "1" "the first start spawned exactly one ss-redir"
if [[ -n "$first_pid" ]] && kill -0 "$first_pid" 2>/dev/null; then
    ok "the first ss-redir is live, so there IS something to lose"
else
    bad "no live ss-redir after the first start — this test proves nothing"
fi

out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- start)"
second_pid="$(cat "$SS_PID_FILE" 2>/dev/null || true)"
assert_contains "$out" "already active — nothing to do" "the redundant start says it did nothing"
assert_not_contains "$out" "started, supervised" "it does not claim to have started anything"
assert_not_contains "$out" "supervised, watchdog armed" "and does not print the old success line"
if [[ -n "$first_pid" ]] && kill -0 "$first_pid" 2>/dev/null; then
    ok "the healthy ss-redir is STILL ALIVE after the redundant start"
else
    bad "the redundant start KILLED the healthy ss-redir (pid ${first_pid})"
fi
assert_eq "$second_pid" "$first_pid" "no replacement process: the same pid is still serving"
assert_eq "$(cat "${SANDBOX_DIR}/xdg/vpn-proxy/ss-redir.pid" 2>/dev/null || true)" \
    "$first_pid" "the supervised pidfile still names the original process"
assert_eq "$(count_calls '^ss-redir ')" "1" "still exactly one ss-redir spawn in total"
assert_file_absent "$REQUEST" "the redundant start writes no start-request"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[3] a delegated start really runs the unit, and the unit does not recurse"
prepare loaded setsid
out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- start)"
calls="$(cat "$CALL_LOG")"
assert_contains "$calls" "[OK] Transparent proxy active" "the ExecStart line actually ran and applied the rules"
assert_eq "$(count_calls '^systemctl start vpn-proxy\.service$')" "1" "systemctl was called exactly once"
assert_eq "$(count_calls '^ss-redir ')" "1" "ss-redir spawned exactly once, inside the unit"
assert_not_contains "$calls" "Failed to start vpn-proxy" "the in-unit run did not start the unit again"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[4] in-unit run (VP_SYSTEMD=1) makes ZERO systemctl calls (recursion guard)"
prepare loaded setsid
out="$(run_in_unit start)"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "no systemctl action at all inside the unit"
assert_eq "$(count_calls '^ss-redir ')" "1" "the in-unit run spawns ss-redir itself"
assert_not_contains "$out" "Not supervised by systemd" "no unsupervised warning inside the unit"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[5] INVOCATION_ID alone also counts as in-unit (second, independent guard)"
prepare loaded setsid
out="$(run_proxy yes INVOCATION_ID=fake-invocation -- start)"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "INVOCATION_ID alone prevents recursion"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[6] masked unit -> direct path (setsid), pidfile holds the REAL ss-redir pid"
prepare masked setsid
out="$(run_proxy yes -- start)"
pidfile="$(cat "${SANDBOX_DIR}/xdg/vpn-proxy/ss-redir.pid" 2>/dev/null || true)"
real_pid="$(cat "$SS_PID_FILE" 2>/dev/null || true)"
assert_contains "$out" "Not supervised by systemd" "direct start warns it is unsupervised"
assert_contains "$out" "sudo systemctl start vpn-proxy.service" "direct start names the fix"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "no systemctl action with a masked unit"
assert_file_present "${SANDBOX_DIR}/xdg/vpn-proxy/ss-redir.pid" "the direct path wrote a pidfile"
if [[ -n "$real_pid" ]]; then
    ok "the fake ss-redir really is running (pid resolved)"
else
    bad "no live ss-redir to compare the pidfile against"
fi
assert_eq "$pidfile" "$real_pid" "pidfile PID == the real ss-redir, not setsid's parent"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[7] no /run/systemd/system -> same direct path"
prepare no-systemd setsid
out="$(run_proxy yes -- start)"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "no systemctl action without a systemd unit tree"
assert_contains "$out" "Not supervised by systemd" "still warns about the missing supervision"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[8] a loaded unit running a DIFFERENT script is not delegated to"
prepare foreign setsid
out="$(run_proxy yes -- start)"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "a foreign unit is left alone"
assert_contains "$out" "Not supervised by systemd" "the direct path is taken instead"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[9] 'start full' survives the delegation round trip via the request file"
prepare loaded setsid
out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- start full)"
calls="$(cat "$CALL_LOG")"
assert_contains "$calls" "mode=all TCP (forwarded + local)" "the in-unit run applied mode=full"
assert_eq "$(count_calls '^ss-redir ')" "1" "still exactly one ss-redir"
assert_file_absent "$REQUEST" "the request file is consumed, not left behind"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[9b] 'start selective --exclude' round trip carries the excludes too"
prepare loaded setsid
out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- start selective --exclude 203.0.113.0/24)"
calls="$(cat "$CALL_LOG")"
assert_contains "$calls" "203.0.113.0/24" "the excluded CIDR reached the applied rules"
assert_file_absent "$REQUEST" "the request file is consumed"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[9c] mode precedence on the in-unit side: CLI beats the request file"
# config.sh ships PROXY_MODE="selective"; a fresh CLI value must win.
prepare loaded setsid
printf 'ts=%s\nmode=local\nexcludes=\n' "$(date +%s)" > "$REQUEST"
out="$(run_in_unit start full)"
assert_contains "$out" "mode=all TCP (forwarded + local)" "CLI mode=full wins over the request"
assert_not_contains "$out" "mode=local TCP only" "the request's mode=local did not override it"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[10] a stale request (older than the TTL) is discarded, not applied"
prepare loaded setsid
printf 'ts=%s\nmode=full\nexcludes=\n' "$(( $(date +%s) - 400 ))" > "$REQUEST"
out="$(run_in_unit start)"
assert_not_contains "$out" "mode=all TCP" "a 400s-old request does not override the default"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[10b] a non-numeric ts degrades to the config mode, it does not abort start"
# `ts` is read from a FILE. With `ts=abc`, `$(( now - ts ))` raised an
# unbound-variable error under `set -u`, which killed the whole in-unit
# ExecStart instead of degrading to "no request, use config.sh's mode".
prepare loaded setsid
printf 'ts=abc\nmode=full\nexcludes=\n' > "$REQUEST"
out="$(run_in_unit start)"
assert_not_contains "$out" "unbound variable" "a non-numeric ts raises no bash arithmetic error"
assert_contains "$out" "[OK] Transparent proxy active" "the in-unit start still completes"
assert_not_contains "$out" "mode=all TCP" "the malformed request does not apply mode=full"
assert_file_absent "$REQUEST" "the malformed request is consumed, not left in /run"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[10c] a zero-byte request file is consumed, not left in /run"
prepare loaded setsid
: > "$REQUEST"
out="$(run_in_unit start)"
assert_file_absent "$REQUEST" "the empty request file is removed, not stranded"
assert_contains "$out" "[OK] Transparent proxy active" "and the in-unit start still completes"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[11] stop with an ACTIVE unit -> only 'systemctl stop', no direct iptables"
prepare active setsid
out="$(VP_SYSTEMCTL_EXEC=1 run_proxy yes -- stop)"
calls="$(cat "$CALL_LOG")"
assert_contains "$out" "watchdog will not restart it" "stop confirms the watchdog will not resurrect"
assert_eq "$(count_calls '^systemctl stop vpn-proxy\.service$')" "1" "exactly one systemctl stop"
assert_eq "$(count_calls '^ss-redir ')" "0" "no direct ss-redir spawn from the CLI"
assert_contains "$calls" "iptables" "the unit's own ExecStop removed the rules"
assert_eq "$(count_calls '^systemctl stop vpn-proxy\.service$')" "1" "and it did not stop twice"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[12] a failing systemctl start reports loudly and does NOT fall back"
prepare loaded setsid
out="$(VP_SYSTEMCTL_EXIT=1 run_proxy yes -- start)"
rc=$?
assert_contains "$out" "NOT falling back to an unsupervised start" "the failure is loud, not silent"
assert_contains "$out" "journalctl -u vpn-proxy.service -n 30" "the failure points at the journal"
assert_eq "$(count_calls '^ss-redir ')" "0" "no unsupervised ss-redir spawned as a 'fix'"
assert_eq "$(count_calls '^ipset ')" "0" "no ipset work as a 'fix'"
assert_file_absent "$REQUEST" "the request file is cleaned up on failure"
if [[ "$rc" -ne 0 ]]; then
    ok "start exits non-zero when systemctl fails"
else
    bad "start should exit non-zero when systemctl fails (got ${rc})"
fi
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[13] 'stop' with an INACTIVE unit still cleans up directly"
prepare loaded setsid
out="$(run_proxy yes -- stop)"
assert_eq "$(count_calls '^systemctl \(start\|stop\|restart\) ')" "0" "no systemctl action for an inactive unit"
assert_contains "$out" "TPROXY rules removed" "the direct stop path still removes the rules"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[14] status tells the truth about supervision without root"
prepare loaded setsid
out="$(run_proxy no -- status)"
assert_contains "$out" "supervision:" "status reports supervision"
assert_contains "$out" "supervision: NONE" "no unit in /proc/*/cgroup means NONE"
assert_contains "$out" "sudo systemctl start vpn-proxy.service" "status names the fix"
assert_contains "$out" "unit      :" "status reports the unit state"
assert_not_contains "$out" "INACTIVE (direct connection)" "status still never claims a direct connection"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "[15] other commands are untouched by the delegation work"
prepare loaded setsid
out="$(run_proxy yes -- --help)"
assert_contains "$out" "Usage:" "help still prints usage"
assert_contains "$out" "set-key" "help still lists set-key"
teardown_sandbox
prepare loaded setsid
out="$(run_proxy yes -- refresh)"
assert_contains "$out" "[OK] ipset" "refresh still re-resolves domains.txt"
teardown_sandbox
echo

# --------------------------------------------------------------------------
echo "=== ${PASS} passed, ${FAIL} failed ==="
teardown_sandbox
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0