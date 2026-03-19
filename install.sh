#!/usr/bin/env bash
# =============================================================================
# install.sh — pve-hostbackup v3 Installer
#
# Run from the cloned repository directory:
#   git clone https://github.com/YOUR_USERNAME/pve-hostbackup.git
#   cd pve-hostbackup
#   sudo bash install.sh
#
# What it does:
#   1.  Verifies Proxmox environment
#   2.  Installs required packages (zstd, flock, age)
#   3.  Installs library, scripts, config, systemd units
#   4.  Sets correct ownership and permissions (no world-writable files)
#   5.  Enables the systemd timer
#   6.  Runs a dry-run to verify the installation
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

INSTALL_SBIN="/usr/local/sbin"
INSTALL_LIB="/usr/local/lib/pve-hostbackup"
INSTALL_CONF="/etc/pve-hostbackup"
SYSTEMD_DIR="/etc/systemd/system"

C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m'
C_RED='\033[0;31m' C_BOLD='\033[1m' C_RESET='\033[0m'

log()  { echo -e "${C_BOLD}[INSTALL]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[  OK  ]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[ FAIL ]${C_RESET} $*" >&2; }

[[ "${EUID}" -ne 0 ]] && { err "Must run as root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\n${C_BOLD}╔══════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}║   pve-hostbackup v3 — Installer     ║${C_RESET}"
echo -e "${C_BOLD}╚══════════════════════════════════════╝${C_RESET}\n"

# --- Proxmox check ---
log "Checking Proxmox environment..."
if command -v pveversion &>/dev/null; then
    ok "PVE detected: $(pveversion 2>/dev/null | head -1)"
else
    warn "pveversion not found — are you sure this is a Proxmox host?"
    read -rp "Continue anyway? [y/N]: " _ans
    [[ "${_ans:-n}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# --- Required packages ---
log "Checking required packages..."
REQUIRED_PKGS=(tar zstd util-linux rsync)  # util-linux provides flock(1)
OPTIONAL_PKGS=(age jq)
MISSING_REQ=()
MISSING_OPT=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    cmd="${pkg}"
    [[ "${pkg}" == "util-linux" ]] && cmd="flock"
    command -v "${cmd}" &>/dev/null && ok "${cmd}" || MISSING_REQ+=("${pkg}")
done
for pkg in "${OPTIONAL_PKGS[@]}"; do
    command -v "${pkg}" &>/dev/null && ok "${pkg}" || MISSING_OPT+=("${pkg}")
done

if (( ${#MISSING_REQ[@]} > 0 )); then
    log "Installing required packages: ${MISSING_REQ[*]}"
    apt-get install -y "${MISSING_REQ[@]}" || {
        err "Failed to install required packages: ${MISSING_REQ[*]}"
        exit 1
    }
    ok "Required packages installed."
fi

if (( ${#MISSING_OPT[@]} > 0 )); then
    warn "Optional packages not found: ${MISSING_OPT[*]}"
    warn "  age  — needed for archive encryption (ENCRYPT_ARCHIVES=true)"
    warn "  jq   — needed for pretty-printed manifests"
    read -rp "Install optional packages? [Y/n]: " _ans
    if [[ "${_ans:-y}" =~ ^[Yy]$ ]]; then
        apt-get install -y "${MISSING_OPT[@]}" 2>/dev/null \
            && ok "Optional packages installed." \
            || warn "Some optional packages failed — install manually later."
    fi
fi

# --- Create directories ---
log "Creating directories..."
mkdir -p "${INSTALL_LIB}" "${INSTALL_CONF}" "${SYSTEMD_DIR}"
# Config dir: root-only read (contains potential passphrase file path)
chown root:root "${INSTALL_CONF}"
chmod 750 "${INSTALL_CONF}"
ok "Directories ready."

# --- Install library ---
log "Installing shared library..."
install -o root -g root -m 644 \
    "${SCRIPT_DIR}/pve-hostbackup-lib.sh" \
    "${INSTALL_LIB}/pve-hostbackup-lib.sh"
ok "Library: ${INSTALL_LIB}/pve-hostbackup-lib.sh"

# --- Install and patch scripts ---
log "Installing scripts..."
for script in pve-hostbackup.sh pve-hostrestore.sh; do
    src="${SCRIPT_DIR}/${script}"
    dst="${INSTALL_SBIN}/${script}"
    [[ ! -f "${src}" ]] && { err "Source not found: ${src}"; exit 1; }
    # Patch the LIB_FILE path so installed scripts find the library
    sed "s|LIB_FILE=.*|LIB_FILE=\"${INSTALL_LIB}/pve-hostbackup-lib.sh\"|" \
        "${src}" > "${dst}"
    chown root:root "${dst}"
    chmod 750 "${dst}"
    ok "Script: ${dst}"
done

# Symlinks without .sh extension
ln -sf "${INSTALL_SBIN}/pve-hostbackup.sh"  "${INSTALL_SBIN}/pve-hostbackup"
ln -sf "${INSTALL_SBIN}/pve-hostrestore.sh" "${INSTALL_SBIN}/pve-hostrestore"
ok "Symlinks: pve-hostbackup, pve-hostrestore"

# --- Install OnFailure notification helper ---
log "Installing failure notifier..."
cat > "${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh" <<'EOF'
#!/usr/bin/env bash
# Called by systemd OnFailure — sends notification that backup failed
source /usr/local/lib/pve-hostbackup/pve-hostbackup-lib.sh
lib::load_config 2>/dev/null || {
    NOTIFY_ON="all"; EMAIL_ENABLED=false; PVE_NOTIFY_ENABLED=false
    LOG_FILE="/var/log/pve-hostbackup.log"
}
lib::detect_environment
BODY="PVE Host Backup FAILED on ${HOSTNAME_SHORT}

Time: $(date)
Host: $(hostname -f 2>/dev/null)
PVE:  $(pveversion 2>/dev/null | head -1 || echo unknown)

Diagnose:
  journalctl -u pve-hostbackup.service --since '1 hour ago'
  tail -50 ${LOG_FILE}
"
lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" "${BODY}"
EOF
chown root:root "${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh"
chmod 750 "${INSTALL_SBIN}/pve-hostbackup-notify-fail.sh"
ok "Failure notifier installed."

# --- Install config (never overwrite an existing one) ---
log "Installing config..."
if [[ -f "${INSTALL_CONF}/pve-hostbackup.conf" ]]; then
    warn "Existing config found — not overwriting."
    warn "New default config saved to: ${INSTALL_CONF}/pve-hostbackup.conf.new"
    install -o root -g root -m 640 \
        "${SCRIPT_DIR}/pve-hostbackup.conf" \
        "${INSTALL_CONF}/pve-hostbackup.conf.new"
else
    install -o root -g root -m 640 \
        "${SCRIPT_DIR}/pve-hostbackup.conf" \
        "${INSTALL_CONF}/pve-hostbackup.conf"
    ok "Config: ${INSTALL_CONF}/pve-hostbackup.conf"
fi

# --- Install systemd units ---
log "Installing systemd units..."
for unit in pve-hostbackup.service pve-hostbackup.timer pve-hostbackup-notify-fail.service; do
    src="${SCRIPT_DIR}/systemd/${unit}"
    if [[ -f "${src}" ]]; then
        install -o root -g root -m 644 "${src}" "${SYSTEMD_DIR}/${unit}"
        ok "Unit: ${SYSTEMD_DIR}/${unit}"
    else
        warn "Unit file not found: ${src}"
    fi
done

# --- Enable timer ---
log "Enabling systemd timer..."
systemctl daemon-reload
systemctl enable pve-hostbackup.timer
systemctl start pve-hostbackup.timer
ok "Timer enabled and active."

echo ""
systemctl status pve-hostbackup.timer --no-pager -l || true

# --- Dry-run verification ---
echo ""
log "Running dry-run verification..."
if "${INSTALL_SBIN}/pve-hostbackup.sh" --dry-run; then
    ok "Dry-run passed."
else
    warn "Dry-run reported issues. Edit config and re-run dry-run:"
    warn "  nano ${INSTALL_CONF}/pve-hostbackup.conf"
    warn "  pve-hostbackup --dry-run"
fi

# --- Summary ---
echo ""
echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}║   Installation complete!             ║${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════╝${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Next steps:${C_RESET}"
echo -e "    1. Edit config:   nano ${INSTALL_CONF}/pve-hostbackup.conf"
echo -e "    2. Set NFS_STORAGE_ID to match:  pvesm status"
echo -e "    3. Set EMAIL_RECIPIENT"
echo -e "    4. (Optional) Enable encryption:"
echo -e "         head -c 48 /dev/urandom | base64 > ${INSTALL_CONF}/backup.key"
echo -e "         chmod 400 ${INSTALL_CONF}/backup.key"
echo -e "         Set ENCRYPT_ARCHIVES=\"true\" in config"
echo -e "    5. Run a backup:  pve-hostbackup"
echo -e "    6. Check timer:   systemctl list-timers pve-hostbackup.timer"
echo -e "    7. View logs:     journalctl -u pve-hostbackup.service -f"
echo ""
echo -e "  ${C_BOLD}Quick reference:${C_RESET}"
echo -e "    pve-hostbackup              — run backup now"
echo -e "    pve-hostbackup --dry-run    — simulate (safe)"
echo -e "    pve-hostbackup --list       — list archives"
echo -e "    pve-hostrestore             — interactive restore wizard"
echo -e "    pve-hostrestore --dry-run   — preview restore to /tmp"
echo ""
