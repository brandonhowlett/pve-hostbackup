#!/usr/bin/env bash
# =============================================================================
# install.sh — pve-hostbackup v3 Installer
# Run as root on your Proxmox host:
#   git clone https://github.com/YOUR_USERNAME/pve-hostbackup.git
#   cd pve-hostbackup && bash install.sh
# =============================================================================

set -euo pipefail

INSTALL_SBIN="/usr/local/sbin"
INSTALL_LIB="/usr/local/lib/pve-hostbackup"
INSTALL_CONF="/etc/pve-hostbackup"
SYSTEMD_DIR="/etc/systemd/system"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'
C_RED='\033[0;31m'; C_BOLD='\033[1m'; C_RESET='\033[0m'

_log()  { echo -e "${C_BOLD}[INSTALL]${C_RESET} $*"; }
_ok()   { echo -e "${C_GREEN}[  OK  ]${C_RESET} $*"; }
_warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*"; }
_err()  { echo -e "${C_RED}[ ERR  ]${C_RESET} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { _err "Must be run as root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\n${C_BOLD}================================================="
echo -e "  pve-hostbackup v3 Installer"
echo -e "=================================================${C_RESET}\n"

# --- Proxmox check ---
_log "Checking Proxmox environment..."
if command -v pveversion &>/dev/null; then
    _ok "Proxmox: $(pveversion 2>/dev/null | head -1)"
else
    _warn "pveversion not found. Are you sure this is a Proxmox host?"
    read -rp "Continue anyway? [y/N]: " _ans
    [[ "${_ans}" =~ ^[Yy]$ ]] || exit 0
fi

# --- Required tools ---
_log "Checking required tools..."
_missing=()
for _tool in tar zstd sha256sum flock awk; do
    command -v "${_tool}" &>/dev/null && _ok "${_tool}" || _missing+=("${_tool}")
done
if (( ${#_missing[@]} > 0 )); then
    _warn "Missing: ${_missing[*]} — attempting install..."
    apt-get install -y "${_missing[@]}" 2>/dev/null \
        || _warn "apt-get failed. Please install manually: ${_missing[*]}"
fi

# Optional: jq (pretty manifests), age (recommended encryption)
for _opt in jq age; do
    if ! command -v "${_opt}" &>/dev/null; then
        _warn "${_opt} not installed. Installing (optional but recommended)..."
        apt-get install -y "${_opt}" 2>/dev/null \
            && _ok "${_opt} installed" \
            || _warn "${_opt} not available in apt — skipping."
    else
        _ok "${_opt} already installed"
    fi
done

# --- Directories ---
_log "Creating directories..."
mkdir -p "${INSTALL_LIB}" "${INSTALL_CONF}" "${SYSTEMD_DIR}"
_ok "Directories created."

# --- Library ---
_log "Installing shared library..."
install -m 644 "${SCRIPT_DIR}/pve-hostbackup-lib.sh" "${INSTALL_LIB}/pve-hostbackup-lib.sh"
_ok "Library → ${INSTALL_LIB}/pve-hostbackup-lib.sh"

# --- Scripts (patch LIB_FILE path at install time) ---
_log "Installing scripts..."
for _script in pve-hostbackup.sh pve-hostrestore.sh; do
    [[ ! -f "${SCRIPT_DIR}/${_script}" ]] && { _err "Source not found: ${_script}"; exit 1; }
    sed "s|LIB_FILE=.*|LIB_FILE=\"${INSTALL_LIB}/pve-hostbackup-lib.sh\"|" \
        "${SCRIPT_DIR}/${_script}" \
        > "${INSTALL_SBIN}/${_script}"
    chmod 750 "${INSTALL_SBIN}/${_script}"
    _ok "${_script} → ${INSTALL_SBIN}/${_script}"
done

ln -sf "${INSTALL_SBIN}/pve-hostbackup.sh"  "${INSTALL_SBIN}/pve-hostbackup"
ln -sf "${INSTALL_SBIN}/pve-hostrestore.sh" "${INSTALL_SBIN}/pve-hostrestore"
_ok "Symlinks: pve-hostbackup, pve-hostrestore"

# --- OnFailure notification helper ---
_log "Installing failure notifier..."
cat > "${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /usr/local/lib/pve-hostbackup/pve-hostbackup-lib.sh
lib::load_config
lib::detect_environment
BODY="Proxmox Host Backup FAILED on ${HOSTNAME_SHORT}

Time:    $(date)
Host:    $(hostname -f 2>/dev/null || echo unknown)
PVE:     $(pveversion 2>/dev/null | head -1 || echo unknown)

Diagnose:
  journalctl -u pve-hostbackup.service --since '1 hour ago'
  tail -50 ${LOG_FILE}
"
lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" "${BODY}"
EOF
chmod 750 "${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh"
_ok "Notifier → ${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh"

# --- Config (never overwrite existing) ---
_log "Installing config..."
if [[ -f "${INSTALL_CONF}/pve-hostbackup.conf" ]]; then
    _warn "Config already exists — not overwriting."
    _warn "New config saved as: ${INSTALL_CONF}/pve-hostbackup.conf.new"
    install -m 640 "${SCRIPT_DIR}/pve-hostbackup.conf" \
        "${INSTALL_CONF}/pve-hostbackup.conf.new"
else
    install -m 600 "${SCRIPT_DIR}/pve-hostbackup.conf" \
        "${INSTALL_CONF}/pve-hostbackup.conf"
    chown root:root "${INSTALL_CONF}/pve-hostbackup.conf"
    _ok "Config → ${INSTALL_CONF}/pve-hostbackup.conf (chmod 600)"
fi

# Set up encryption key placeholder if it doesn't exist
if [[ ! -f "${INSTALL_CONF}/.archive-key" ]]; then
    touch "${INSTALL_CONF}/.archive-key"
    chmod 400 "${INSTALL_CONF}/.archive-key"
    _warn "Encryption key placeholder created: ${INSTALL_CONF}/.archive-key"
    _warn "To enable encryption: echo 'YourPassphrase' > ${INSTALL_CONF}/.archive-key && chmod 400 ${INSTALL_CONF}/.archive-key"
    _warn "Then set ENCRYPT_ARCHIVE=true in the config."
fi

# --- Systemd units ---
_log "Installing systemd units..."
for _unit in pve-hostbackup.service pve-hostbackup.timer pve-hostbackup-notify-fail.service; do
    _src="${SCRIPT_DIR}/systemd/${_unit}"
    if [[ -f "${_src}" ]]; then
        install -m 644 "${_src}" "${SYSTEMD_DIR}/${_unit}"
        _ok "${_unit} → ${SYSTEMD_DIR}/${_unit}"
    else
        _warn "Unit not found: ${_src}"
    fi
done

# --- Enable timer ---
_log "Enabling systemd timer..."
systemctl daemon-reload
systemctl enable --now pve-hostbackup.timer
_ok "Timer enabled."

systemctl status pve-hostbackup.timer --no-pager 2>/dev/null || true

# --- Summary ---
echo ""
echo -e "${C_BOLD}${C_GREEN}================================================="
echo -e "  Installation complete!"
echo -e "=================================================${C_RESET}"

# Show available PVE storages inline so the user doesn't need to run pvesm separately
echo ""
echo -e "${C_BOLD}Your current PVE storage IDs (pvesm status):${C_RESET}"
echo -e "${C_CYAN}"
pvesm status 2>/dev/null || echo "  (pvesm not available)"
echo -e "${C_RESET}"
echo -e "  Use one of the ${C_BOLD}Name${C_RESET} values above as ${C_BOLD}NFS_STORAGE_ID${C_RESET} in the config."
echo -e "  Pick a storage that is always online and has sufficient free space."
echo -e "  If you only have 'local' or 'local-zfs', leave NFS_STORAGE_ID empty"
echo -e "  and set LOCAL_BACKUP_PATH to a path on that storage instead."
echo ""
echo -e "${C_BOLD}Required: edit the config before running your first backup${C_RESET}"
echo ""
echo -e "  ${C_CYAN}nano ${INSTALL_CONF}/pve-hostbackup.conf${C_RESET}"
echo ""
echo -e "  Minimum settings to review:"
echo -e "    ${C_YELLOW}NFS_STORAGE_ID${C_RESET}   — storage Name from the table above (or leave empty)"
echo -e "    ${C_YELLOW}LOCAL_BACKUP_PATH${C_RESET} — used only if NFS_STORAGE_ID is empty"
echo -e "    ${C_YELLOW}EMAIL_RECIPIENT${C_RESET}  — your email address for notifications"
echo ""
echo -e "  After editing, verify your config with a dry-run (nothing is written):"
echo -e "    ${C_BOLD}pve-hostbackup --dry-run${C_RESET}"
echo ""
echo -e "${C_BOLD}Quick reference:${C_RESET}"
echo -e "  pve-hostbackup                    — run backup now"
echo -e "  pve-hostbackup --dry-run          — safe simulation, no files written"
echo -e "  pve-hostbackup --list             — list stored backups"
echo -e "  pve-hostbackup --verify <file>    — verify an archive"
echo -e "  pve-hostrestore                   — interactive restore wizard"
echo ""
echo -e "${C_BOLD}Schedule and logs:${C_RESET}"
echo -e "  systemctl list-timers pve-hostbackup.timer   — next scheduled run"
echo -e "  journalctl -u pve-hostbackup.service -f      — live log output"
echo -e "  cat /var/log/pve-hostbackup.log              — full log file"
echo ""
