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
SYSTEMD_UNIT="/etc/systemd/system/vpn-proxy.service"
LOGROTATE_FILE="/etc/logrotate.d/vpn-proxy"
SUDOERS_FILE="/etc/sudoers.d/vpn-proxy"
LOG_DIR="/var/log/vpn-proxy"
REPO_URL="${REPO_URL:-https://github.com/peterlianpi/vpn-proxy.git}"

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

install_tree() {
    local src="$1"
    vp_step "Installing to ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    if [[ -f "${INSTALL_DIR}/config.sh" ]]; then
        cp -a "${INSTALL_DIR}/config.sh" "${INSTALL_DIR}/config.sh.bak"
    fi

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude '.git/' \
            --exclude 'config.sh.bak' \
            "${src}/" "${INSTALL_DIR}/"
    else
        cp -a "${src}/." "${INSTALL_DIR}/"
        rm -rf "${INSTALL_DIR}/.git"
    fi

    if [[ -f "${INSTALL_DIR}/config.sh.bak" ]]; then
        mv -f "${INSTALL_DIR}/config.sh.bak" "${INSTALL_DIR}/config.sh"
    elif [[ ! -f "${INSTALL_DIR}/config.sh" && -f "${INSTALL_DIR}/config.sh.example" ]]; then
        cp "${INSTALL_DIR}/config.sh.example" "${INSTALL_DIR}/config.sh"
        vp_warn "Created ${INSTALL_DIR}/config.sh from example — edit your Outline key"
    fi

    chmod +x "${INSTALL_DIR}/proxy.sh" "${INSTALL_DIR}/install.sh" \
        "${INSTALL_DIR}/lib/log.sh" 2>/dev/null || true
    [[ -f "${INSTALL_DIR}/decode-key.sh" ]] && chmod +x "${INSTALL_DIR}/decode-key.sh"
    [[ -f "${INSTALL_DIR}/warp-setup.sh" ]] && chmod +x "${INSTALL_DIR}/warp-setup.sh"
    vp_ok "Files installed to ${INSTALL_DIR}"
}

install_bin_link() {
    vp_step "Linking ${BIN_LINK}"
    ln -sf "${INSTALL_DIR}/proxy.sh" "${BIN_LINK}"
    vp_ok "${BIN_LINK} -> ${INSTALL_DIR}/proxy.sh"
}

install_systemd() {
    vp_step "Creating systemd unit"
    cat >"${SYSTEMD_UNIT}" <<UNIT
[Unit]
Description=Outline VPN transparent proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
Environment=VP_LOG_DIR=${LOG_DIR}
ExecStart=${BIN_LINK} start
ExecStop=${BIN_LINK} stop
TimeoutStartSec=90
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    vp_ok "Created ${SYSTEMD_UNIT}"
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
}

main() {
    vp_log_init
    require_root
    clone_if_piped
    install_bin_link
    install_systemd
    install_logrotate
    install_sudoers
    echo ""
    vp_ok "Install complete — run from any directory:"
    echo "  vpn-proxy status"
    echo "  vpn-proxy start"
    echo "  vpn-proxy logs -f"
    echo "  systemctl enable vpn-proxy"
    echo ""
    echo "One-line install for others:"
    echo "  curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/main/install.sh | sudo bash"
}

main "$@"
