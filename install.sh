#!/usr/bin/env bash
# System-wide install: /opt/vpn-proxy + /usr/local/bin/vpn-proxy
#
# From clone:
#   sudo ./install.sh
#
# One line from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/main/install.sh | sudo bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/vpn-proxy}"
BIN_LINK="${BIN_LINK:-/usr/local/bin/vpn-proxy}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/vpn-proxy}"
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/vpn-proxy}"
LOG_DIR="${LOG_DIR:-/var/log/vpn-proxy}"
REPO_URL="${REPO_URL:-https://github.com/peterlianpi/vpn-proxy.git}"

# Shipped routing default. install.sh writes ONLY this key into the live
# /opt/vpn-proxy/config.sh — never SS_SERVER / SS_PORT / SS_PASSWORD /
# SS_METHOD / PROXY_IP. Override with: DEFAULT_PROXY_MODE=full ./install.sh
DEFAULT_PROXY_MODE="${DEFAULT_PROXY_MODE:-selective}"

# Canonical paths baked into the unit files in systemd/. They are replaced
# during install when INSTALL_DIR / BIN_LINK / LOG_DIR are overridden.
CANON_INSTALL_DIR="/opt/vpn-proxy"
CANON_BIN_LINK="/usr/local/bin/vpn-proxy"
CANON_LOG_DIR="${LOG_DIR:-/var/log/vpn-proxy}"

UNIT_FILES=(
    "vpn-proxy.service"
    "vpn-proxy-watchdog.service"
    "vpn-proxy-watchdog.timer"
)

# Timestamp shared by every backup written during one install run.
BACKUP_STAMP="$(date +%s)"
# How many "<file>.bak-<stamp>" snapshots to keep per file.
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

installing_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
        echo "$USER"
    else
        whoami
    fi
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || { vp_err "Run as root: sudo $0"; exit 1; }
}

# --- Non-destructive config handling -----------------------------------
# install.sh doubles as the UPDATE path, so it may be re-run at any time.
# Rule: never overwrite live operator state. Back it up first, exclude it
# from the file sync, and only ever add/set PROXY_MODE.
backup_file() {
    local target="$1"
    local tag="${2:-bak}"
    [[ -f "$target" ]] || return 0
    local dest="${target}.${tag}-${BACKUP_STAMP}"
    cp -a "$target" "$dest"
    vp_ok "Backed up ${target} -> ${dest}"
    prune_backups "${target}.${tag}-"
}

# Keep the newest KEEP_BACKUPS snapshots of our own "<file>.bak-*"
# pattern; nothing else is ever removed.
prune_backups() {
    local prefix="$1"
    local -a old=()
    mapfile -t old < <(ls -1t "${INSTALL_DIR}/$(basename "$prefix")"* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
    if ((${#old[@]} > 0)); then
        rm -f "${old[@]}"
        vp_ok "Pruned ${#old[@]} old backup(s) matching ${prefix}*"
    fi
}

config_backup_path() {
    echo "${INSTALL_DIR}/config.sh.bak-${BACKUP_STAMP}"
}

domains_backup_path() {
    echo "${INSTALL_DIR}/domains.txt.bak-${BACKUP_STAMP}"
}

install_tree() {
    local src="$1"
    vp_step "Installing to ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    # Snapshot operator state before anything is written.
    backup_file "${INSTALL_DIR}/config.sh" bak
    backup_file "${INSTALL_DIR}/domains.txt" bak

    if command -v rsync >/dev/null 2>&1; then
        # config.sh is excluded outright so the live key material can never
        # be clobbered, and backups are excluded so --delete keeps them.
        rsync -a --delete \
            --exclude '.git/' \
            --exclude '/config.sh' \
            --exclude 'config.sh.bak*' \
            --exclude 'domains.txt.bak*' \
            "${src}/" "${INSTALL_DIR}/"
    else
        vp_warn "rsync not found — falling back to cp"
        cp -a "${src}/." "${INSTALL_DIR}/"
        rm -rf "${INSTALL_DIR}/.git"
        # cp cannot exclude, so put the snapshots back.
        if [[ -f "${INSTALL_DIR}/config.sh.bak-${BACKUP_STAMP}" ]]; then
            cp -a "${INSTALL_DIR}/config.sh.bak-${BACKUP_STAMP}" "${INSTALL_DIR}/config.sh"
        fi
        if [[ -f "$(domains_backup_path)" ]]; then
            cp -a "$(domains_backup_path)" "${INSTALL_DIR}/domains.txt"
        fi
    fi

    if [[ ! -f "${INSTALL_DIR}/config.sh" && -f "${INSTALL_DIR}/config.sh.example" ]]; then
        cp "${INSTALL_DIR}/config.sh.example" "${INSTALL_DIR}/config.sh"
        vp_warn "Created ${INSTALL_DIR}/config.sh from example — edit your Outline key"
    fi

    if [[ ! -f "${INSTALL_DIR}/domains.txt" && -f "${INSTALL_DIR}/domains.txt.example" ]]; then
        cp "${INSTALL_DIR}/domains.txt.example" "${INSTALL_DIR}/domains.txt"
        vp_ok "Seeded ${INSTALL_DIR}/domains.txt from domains.txt.example"
    fi

    chmod +x "${INSTALL_DIR}/proxy.sh" "${INSTALL_DIR}/install.sh" \
        "${INSTALL_DIR}/lib/log.sh" "${INSTALL_DIR}/lib/wait-network.sh" \
        "${INSTALL_DIR}/lib/watchdog.sh" 2>/dev/null || true
    [[ -f "${INSTALL_DIR}/decode-key.sh" ]] && chmod +x "${INSTALL_DIR}/decode-key.sh"
    [[ -f "${INSTALL_DIR}/set-key.sh" ]] && chmod +x "${INSTALL_DIR}/set-key.sh"
    [[ -f "${INSTALL_DIR}/warp-setup.sh" ]] && chmod +x "${INSTALL_DIR}/warp-setup.sh"
    vp_ok "Files installed to ${INSTALL_DIR}"
}

# Only PROXY_MODE is ever written into the live config. Everything else in
# config.sh (SS_SERVER, SS_PORT, SS_PASSWORD, SS_METHOD, PROXY_IP, …) is
# the operator's and is left exactly as found.
ensure_proxy_mode() {
    local cfg="${INSTALL_DIR}/config.sh"
    [[ -f "$cfg" ]] || { vp_warn "No ${cfg} — skipping PROXY_MODE"; return 0; }

    local mode="$DEFAULT_PROXY_MODE"
    if grep -qE '^[[:space:]]*PROXY_MODE=' "$cfg"; then
        if grep -qE "^[[:space:]]*PROXY_MODE=[\"']?${mode}[\"']?([[:space:]]*#.*)?$" "$cfg"; then
            vp_ok "PROXY_MODE already '${mode}' in ${cfg}"
            return 0
        fi
        sed -i -E "s|^[[:space:]]*PROXY_MODE=.*|PROXY_MODE=\"${mode}\"|" "$cfg"
        vp_ok "PROXY_MODE -> '${mode}' in ${cfg} (previous state: $(config_backup_path))"
    else
        printf '\n# --- Routing mode (added by install.sh) ---\nPROXY_MODE="%s"\n' "$mode" >>"$cfg"
        vp_ok "Added PROXY_MODE=\"${mode}\" to ${cfg}"
    fi
    vp_ok "Routing mode switch: sudo vpn-proxy start full | local | selective"
}

install_bin_link() {
    vp_step "Linking ${BIN_LINK}"
    ln -sf "${INSTALL_DIR}/proxy.sh" "${BIN_LINK}"
    vp_ok "${BIN_LINK} -> ${INSTALL_DIR}/proxy.sh"
}

install_systemd() {
    local src_dir="${SCRIPT_DIR}/systemd"

    vp_step "Installing systemd units"
    if [[ ! -d "$src_dir" ]]; then
        vp_err "systemd/ not found at ${src_dir} — run install.sh from the repo"
        exit 1
    fi

    local name tmp mismatch=false
    for name in "${UNIT_FILES[@]}"; do
        if [[ ! -f "${src_dir}/${name}" ]]; then
            vp_err "Missing unit source: ${src_dir}/${name}"
            exit 1
        fi
        # The unit files in systemd/ are the single source of truth and
        # carry the canonical paths as literals; rewrite them only when
        # this install overrides those paths.
        tmp="$(mktemp)"
        sed -e "s|${CANON_INSTALL_DIR}|${INSTALL_DIR}|g" \
            -e "s|${CANON_BIN_LINK}|${BIN_LINK}|g" \
            -e "s|${CANON_LOG_DIR}|${LOG_DIR}|g" \
            "${src_dir}/${name}" >"$tmp"
        install -m 644 "$tmp" "${SYSTEMD_UNIT_DIR}/${name}"
        rm -f "$tmp"
        vp_ok "Installed ${SYSTEMD_UNIT_DIR}/${name}"
    done

    # Parity check: with the default paths the installed units must match
    # the repo copies byte for byte, so the two can never drift apart.
    if [[ "$INSTALL_DIR" == "$CANON_INSTALL_DIR" \
       && "$BIN_LINK" == "$CANON_BIN_LINK" \
       && "$LOG_DIR" == "$CANON_LOG_DIR" ]]; then
        for name in "${UNIT_FILES[@]}"; do
            if ! cmp -s "${src_dir}/${name}" "${SYSTEMD_UNIT_DIR}/${name}"; then
                vp_warn "Unit differs from repo copy: ${name}"
                mismatch=true
            fi
        done
        if ! $mismatch; then
            vp_ok "Installed units are byte-identical to systemd/ in the repo"
        fi
    fi

    systemctl daemon-reload
    vp_ok "Created ${SYSTEMD_UNIT_DIR}/vpn-proxy*.{service,timer}"
}

enable_systemd() {
    vp_step "Enabling vpn-proxy and its self-heal watchdog"
    # vpn-proxy.service carries Wants=vpn-proxy-watchdog.timer, so enabling
    # it is enough; the explicit enable keeps the timer tracked on its own.
    if systemctl enable vpn-proxy.service >/dev/null 2>&1; then
        vp_ok "Enabled vpn-proxy.service (starts on boot)"
    else
        vp_warn "Could not enable vpn-proxy.service — run: systemctl enable vpn-proxy"
    fi
    if systemctl enable vpn-proxy-watchdog.timer >/dev/null 2>&1; then
        vp_ok "Enabled vpn-proxy-watchdog.timer (self-heal check every 60s)"
    else
        vp_warn "Could not enable vpn-proxy-watchdog.timer — run: systemctl enable vpn-proxy-watchdog.timer"
    fi
}

install_logrotate() {
    vp_step "Creating log directory and logrotate config"
    mkdir -p "${LOG_DIR}"
    chmod 755 "${LOG_DIR}"
    cat >"${LOGROTATE_FILE}" <<'ROT'
/var/log/vpn-proxy/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
ROT
    chmod 644 "${LOGROTATE_FILE}"
    vp_ok "Logs: ${LOG_DIR}/vpn-proxy.log"
}

install_sudoers() {
    local user
    user="$(installing_user)"
    vp_step "Passwordless sudo for ${user}"
    cat >"${SUDOERS_FILE}" <<SUDO
# vpn-proxy — managed by install.sh
${user} ALL=(root) NOPASSWD: ${BIN_LINK}
${user} ALL=(root) NOPASSWD: ${INSTALL_DIR}/proxy.sh
${user} ALL=(root) NOPASSWD: ${INSTALL_DIR}/install.sh
${user} ALL=(root) NOPASSWD: /bin/systemctl start vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl stop vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl status vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl enable vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl disable vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl restart vpn-proxy
${user} ALL=(root) NOPASSWD: /bin/systemctl status vpn-proxy-watchdog.timer
${user} ALL=(root) NOPASSWD: /bin/systemctl enable vpn-proxy-watchdog.timer
${user} ALL=(root) NOPASSWD: ${INSTALL_DIR}/lib/watchdog.sh
SUDO
    chmod 440 "${SUDOERS_FILE}"
    visudo -cf "${SUDOERS_FILE}" >/dev/null || { rm -f "${SUDOERS_FILE}"; vp_err "sudoers validation failed"; exit 1; }
    vp_ok "Created ${SUDOERS_FILE}"
}

clone_if_piped() {
    if [[ -f "${SCRIPT_DIR}/proxy.sh" ]]; then
        install_tree "${SCRIPT_DIR}"
        return
    fi

    command -v git >/dev/null || { vp_err "git required for remote install"; exit 1; }
    vp_step "Cloning ${REPO_URL} to ${INSTALL_DIR}"
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        git -C "${INSTALL_DIR}" pull --ff-only
    else
        git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
    fi
    install_tree "${INSTALL_DIR}"
}

main() {
    vp_log_init
    require_root
    clone_if_piped
    ensure_proxy_mode
    install_bin_link
    install_systemd
    enable_systemd
    install_logrotate
    install_sudoers
    echo ""
    vp_ok "Install complete — run from any directory:"
    echo "  vpn-proxy status                 # current state + public IP"
    echo "  sudo vpn-proxy start             # PROXY_MODE=${DEFAULT_PROXY_MODE} (from config.sh)"
    echo "  sudo vpn-proxy start full        # temporary switch to full tunnel"
    echo "  sudo vpn-proxy logs -f"
    echo ""
    echo "Self-heal is active: vpn-proxy-watchdog.timer checks every 60s and"
    echo "restarts the unit if ss-redir, the iptables jump or the ipset dies."
    echo "A deliberate 'sudo systemctl stop vpn-proxy' is never undone."
    echo ""
    echo "Start it now:"
    echo "  sudo systemctl start vpn-proxy"
    echo ""
    local version_tag
    version_tag="$(git -C "${INSTALL_DIR}" describe --tags --abbrev=0 2>/dev/null || echo main)"
    echo "One-line install for others:"
    echo "  curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/main/install.sh | sudo bash"
    if [[ "${version_tag}" != "main" ]]; then
        echo "  curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/${version_tag}/install.sh | sudo bash"
    fi
}

main "$@"
