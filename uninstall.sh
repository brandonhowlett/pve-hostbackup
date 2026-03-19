#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — pve-hostbackup removal
# Run as root: sudo bash uninstall.sh
# This removes all installed files but does NOT delete backup archives.
# =============================================================================

set -euo pipefail

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'; C_BOLD='\033[1m'; C_RESET='\033[0m'

_log()  { echo -e "${C_BOLD}[UNINSTALL]${C_RESET} $*"; }
_ok()   { echo -e "${C_GREEN}[  OK  ]${C_RESET} $*"; }
_warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*"; }

[[ "${EUID}" -ne 0 ]] && { echo "Must be run as root."; exit 1; }

echo -e "\n${C_BOLD}pve-hostbackup Uninstaller${C_RESET}\n"
echo -e "${C_YELLOW}This removes all installed files. Backup archives are NOT deleted.${C_RESET}\n"
read -rp "Continue? [yes/N]: " _ans
[[ "${_ans}" == "yes" ]] || { echo "Aborted."; exit 0; }

# Stop and disable timer
_log "Disabling systemd timer..."
systemctl stop pve-hostbackup.timer 2>/dev/null || true
systemctl disable pve-hostbackup.timer 2>/dev/null || true
_ok "Timer disabled."

# Remove systemd units
for _unit in pve-hostbackup.service pve-hostbackup.timer pve-hostbackup-notify-fail.service; do
    rm -f "/etc/systemd/system/${_unit}"
done
systemctl daemon-reload
_ok "Systemd units removed."

# Remove scripts
for _f in pve-hostbackup.sh pve-hostrestore.sh pve-hostbackup pve-hostrestore pve-hostbackup-notify-fail.sh; do
    rm -f "/usr/local/sbin/${_f}"
done
_ok "Scripts removed."

# Remove library
rm -rf "/usr/local/lib/pve-hostbackup"
_ok "Library removed."

# Config — ask before removing (contains passphrase key file)
echo ""
_warn "Config directory: /etc/pve-hostbackup"
_warn "This may contain your encryption passphrase file (.archive-key)."
read -rp "Remove config directory? [yes/N]: " _ans2
if [[ "${_ans2}" == "yes" ]]; then
    rm -rf "/etc/pve-hostbackup"
    _ok "Config directory removed."
else
    _warn "Config directory preserved at /etc/pve-hostbackup"
fi

echo ""
_ok "pve-hostbackup removed. Backup archives are untouched."
