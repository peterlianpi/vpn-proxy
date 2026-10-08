#!/usr/bin/env bash
# ============================================================
# Sandbox harness: status/stop honesty when run WITHOUT root.
#
# Run it:
#   bash tests/sandbox/status-degrade.sh
#   ./tests/sandbox/status-degrade.sh          (it is chmod +x)
#
# Why: before the fix, a non-root `proxy.sh status` could not read the
# iptables rules, yet the dead `sudo -n iptables` probes reported "none".
# Status then printed "INACTIVE (direct connection)" and `stop` printed
# "Internet is now DIRECT (no proxy)" while traffic was still being
# redirected into a dead ss-redir. That is the worst possible failure mode
# for a proxy: confident, and wrong.
#
# This harness puts fake `sudo`, `iptables`, `ipset`, `pgrep`, `curl`,
# `pkill` and `logger` on PATH and runs the REAL proxy.sh as the current
# (non-root) user. It touches nothing on the host: every path it uses is a
# mktemp dir, and VPN_PROXY_ACTIVE_MODE_FILE repoints the one absolute path
# proxy.sh reads (/run/vpn-proxy/active-mode) at a temp file so the test
# passes whether or not the live deployment is running.
#
# It also never prints the ss:// key: status/stop echo no credentials.
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
if [[ "$(id -u)" -eq 0 ]]; then
    echo "[!!] This harness must run as a NON-root user (it fakes privilege)." >&2
    exit 2
fi

PASS=0
FAIL=0

# The name the fake iptables advertises in its match-set rule.
IPSET_NAME="${IPSET_NAME:-vpn_proxy_domains}"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

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

# --- sandbox construction -------------------------------------------------
# $1 = "sudo-fail" | "sudo-exec"
make_sandbox() {
    local flavour="$1"
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/vp-sandbox.XXXXXX")"
    mkdir -p "${dir}/bin" "${dir}/run/vpn-proxy" "${dir}/xdg/vpn-proxy" "${dir}/log"

    # fake sudo ---------------------------------------------------------
    if [[ "$flavour" == "sudo-fail" ]]; then
        cat >"${dir}/bin/sudo" <<'EOS'
#!/bin/sh
# Always fails: stands in for "no sudo, or sudo needs a password".
echo "sudo: a password is required" >&2
exit 1
EOS
    else
        cat >"${dir}/bin/sudo" <<'EOS'
#!/bin/sh
# Works passwordlessly and just runs the command, so the fake iptables on
# PATH is what actually answers.
[ "$1" = "-n" ] && shift
exec "$@"
EOS
    fi

    # fake iptables ------------------------------------------------------
    # Reports a live SS_REDIR chain whose selective rule matches the ipset.
    cat >"${dir}/bin/iptables" <<EOS
#!/bin/sh
# Fake iptables. SS_REDIR carries the selective match-set rule.
case "\$*" in
    *"-C"*)
        # jump rules exist
        echo "FakeRule"
        exit 0
        ;;
    *SS_TPROXY*)
        echo "Chain SS_TPROXY (1 references)"
        exit 0
        ;;
esac
case "\$*" in
    *"-L SS_REDIR"*)
        echo "Chain SS_REDIR (policy ACCEPT)"
        echo "num  target     prot opt source               destination"
        echo "0    RETURN     all  --  0.0.0.0/0            0.0.0.0/0            /* reserved */"
        echo "1    REDIRECT   tcp  --  0.0.0.0/0            0.0.0.0/0            /* ${IPSET_NAME} match-set */ tcp match-set ${IPSET_NAME} dst REDIRECT --to-ports 10800"
        exit 0
        ;;
esac
exit 0
EOS

    # fake ipset ---------------------------------------------------------
    cat >"${dir}/bin/ipset" <<'EOS'
#!/bin/sh
case "$1" in
    list)
        echo "Name: vpn_proxy_domains"
        echo "Number of entries: 9"
        echo "1.2.3.4"
        echo "5.6.7.8"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOS

    # fake pgrep / pkill / curl / dig / logger ---------------------------
    # ss-redir presence is driven by FAKE_SS_REDIR in the environment.
    cat >"${dir}/bin/pgrep" <<'EOS'
#!/bin/sh
[ "${FAKE_SS_REDIR:-0}" = "1" ] || exit 1
exit 0
EOS
    cat >"${dir}/bin/pkill" <<'EOS'
#!/bin/sh
exit 0
EOS
    cat >"${dir}/bin/curl" <<'EOS'
#!/bin/sh
echo '{"ip":"203.0.113.9","country":"XX"}'
exit 0
EOS
    cat >"${dir}/bin/dig" <<'EOS'
#!/bin/sh
echo "1.2.3.4"
exit 0
EOS
    cat >"${dir}/bin/logger" <<'EOS'
#!/bin/sh
exit 0
EOS

    chmod +x "${dir}/bin/"*

    SANDBOX_DIR="$dir"
    export SANDBOX_DIR
}

teardown_sandbox() {
    [[ -n "${SANDBOX_DIR:-}" && -d "$SANDBOX_DIR" ]] && rm -rf "$SANDBOX_DIR"
    SANDBOX_DIR=""
}

# Run the real proxy.sh inside the sandbox. Args: <cmd> [args...]
run_proxy() {
    local flavour="$1"; shift
    make_sandbox "$flavour"
    PATH="${SANDBOX_DIR}/bin:${PATH}" \
    XDG_RUNTIME_DIR="${SANDBOX_DIR}/xdg" \
    VPN_PROXY_ACTIVE_MODE_FILE="${SANDBOX_DIR}/missing-active-mode" \
    VP_LOG_DIR="${SANDBOX_DIR}/log" \
    VP_LOG_FILE="${SANDBOX_DIR}/log/vpn-proxy.log" \
    PROXY_IP="1.2.3.4" \
    SS_START_ATTEMPTS=1 \
    SS_START_DNS_TRIES=1 \
    SS_START_DNS_DELAY=0 \
        bash "$PROXY_SH" "$@" 2>&1
}

# Same, but with a readable root active-mode file containing $2.
run_proxy_with_active_mode() {
    local flavour="$1" mode="$2"; shift 2
    make_sandbox "$flavour"
    printf '%s\n' "$mode" >"${SANDBOX_DIR}/run/vpn-proxy/active-mode"
    chmod 644 "${SANDBOX_DIR}/run/vpn-proxy/active-mode"
    PATH="${SANDBOX_DIR}/bin:${PATH}" \
    XDG_RUNTIME_DIR="${SANDBOX_DIR}/xdg" \
    VPN_PROXY_ACTIVE_MODE_FILE="${SANDBOX_DIR}/run/vpn-proxy/active-mode" \
    VP_LOG_DIR="${SANDBOX_DIR}/log" \
    VP_LOG_FILE="${SANDBOX_DIR}/log/vpn-proxy.log" \
    PROXY_IP="1.2.3.4" \
        bash "$PROXY_SH" "$@" 2>&1
}

# Per-test environment: FAKE_SS_REDIR controls the fake pgrep.
export FAKE_SS_REDIR=0

echo "=== status-degrade sandbox (non-root, faked sudo/iptables/ipset/pgrep) ==="
echo "repo: ${REPO_DIR}"
echo "user: $(id -un) (uid=$(id -u))"
echo

# --------------------------------------------------------------------------
echo "[1] sudo unusable + ss-redir running -> UNKNOWN, never 'INACTIVE (direct)'"
FAKE_SS_REDIR=1
out="$(run_proxy sudo-fail status)"
teardown_sandbox
assert_contains "$out" "UNKNOWN" "status prints UNKNOWN"
assert_not_contains "$out" "INACTIVE (direct connection)" "status does not claim INACTIVE (direct connection)"
assert_contains "$out" "cannot be read without root" "status says the rules are unreadable, and why"

echo "[1b] sudo unusable + no ss-redir -> still UNKNOWN, never 'INACTIVE (direct)'"
FAKE_SS_REDIR=0
out="$(run_proxy sudo-fail status)"
teardown_sandbox
assert_contains "$out" "UNKNOWN" "status prints UNKNOWN with no listener either"
assert_not_contains "$out" "INACTIVE (direct connection)" "status does not claim INACTIVE (direct connection)"
assert_not_contains "$out" "Internet is now DIRECT" "status never claims a direct connection"
echo

# --------------------------------------------------------------------------
echo "[2] sudo unusable + no ss-redir + stop -> unverifiable WARN, never 'Internet is now DIRECT'"
FAKE_SS_REDIR=0
out="$(run_proxy sudo-fail stop)"
teardown_sandbox
assert_contains "$out" "Could not verify iptables without root" "stop warns that iptables is unverifiable"
assert_contains "$out" "traffic may STILL be redirected" "stop warns traffic may still be redirected"
assert_not_contains "$out" "Internet is now DIRECT" "stop does not claim the internet is direct"
echo

# --------------------------------------------------------------------------
echo "[3] sudo works + fake SS_REDIR matches the ipset -> ACTIVE (mode=selective)"
FAKE_SS_REDIR=1
out="$(run_proxy_with_active_mode sudo-exec selective status)"
assert_contains "$out" "ACTIVE" "status reports ACTIVE"
assert_contains "$out" "(mode=selective" "status reports the selective mode"
assert_not_contains "$out" "UNKNOWN" "status is not UNKNOWN when the rules are verifiable"
teardown_sandbox
# Same fake iptables, reached through the fake sudo: proves the non-root
# probe path really is exercised (it used to be the dead branch).
out="$(run_proxy_with_active_mode sudo-exec selective stop)"
teardown_sandbox
assert_contains "$out" "iptables rules still active" "sudo probe reaches the fake iptables (rules are seen)"
assert_not_contains "$out" "Internet is now DIRECT" "stop still refuses to claim direct"
echo

# --------------------------------------------------------------------------
echo "[4] readable active-mode file is honoured with no sudo at all"
FAKE_SS_REDIR=1
out="$(run_proxy_with_active_mode sudo-fail selective status)"
teardown_sandbox
assert_contains "$out" "ACTIVE" "world-readable /run active-mode is read without sudo"
assert_contains "$out" "(mode=selective" "the mode comes from that file, not from a sudo probe"
assert_not_contains "$out" "UNKNOWN" "a readable state file is enough, no sudo needed"
echo

# --------------------------------------------------------------------------
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0