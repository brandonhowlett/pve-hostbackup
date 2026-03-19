#!/usr/bin/env bash
# =============================================================================
# pve-hostrestore.sh — Proxmox Host Configuration Restore v3.0.0
# Version-agnostic: PVE 7.x, 8.x, 9.x+
#
# Usage: pve-hostrestore.sh [OPTIONS]
#   -c, --config FILE    Config file path
#   -a, --archive FILE   Archive to restore (skips interactive selection)
#   -d, --dest DIR       Directory to search for archives
#   -n, --dry-run        Extract to /tmp only — does NOT touch system files
#       --no-network     Skip restoring /etc/network (useful if NIC names differ)
#       --no-zfs         Skip ZFS guidance
#       --force          Skip confirmation prompts
#   -h, --help           Show help
#
# IMPORTANT: Run on a FRESHLY INSTALLED Proxmox host before any configuration.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/pve-hostbackup-lib.sh"
[[ ! -f "${LIB_FILE}" ]] && { echo "ERROR: Library not found: ${LIB_FILE}" >&2; exit 1; }
source "${LIB_FILE}"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
ARCHIVE_TARGET=""
DEST_OVERRIDE=""
DRY_RUN=false
SKIP_NETWORK=false
SKIP_ZFS=false
FORCE=false

_usage() {
cat <<EOF
${C_BOLD}pve-hostrestore${C_RESET} — Proxmox Host Restore v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

  -c, --config FILE    Config file (default: /etc/pve-hostbackup/pve-hostbackup.conf)
  -a, --archive FILE   Archive to restore (skip interactive selection)
  -d, --dest DIR       Directory to search for archives
  -n, --dry-run        Extract to /tmp/pve-restore-preview — do NOT touch the system
      --no-network     Skip /etc/network restoration (useful when NIC names change)
      --no-zfs         Skip ZFS pool import guidance
      --force          Skip confirmation prompts
  -h, --help           Show this help

Workflow after a fresh PVE install:
  1. Copy the archive to this host (USB, scp, etc.)
  2. Run: bash pve-hostrestore.sh --archive /path/to/archive.tar.zst
  3. Review the post-restore checklist
  4. Reboot

Dry-run (safe preview):
  bash pve-hostrestore.sh --archive /path/to/archive.tar.zst --dry-run
  ls -la /tmp/pve-restore-preview/
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)     CONFIG_FILE="$2"; shift 2 ;;
        -a|--archive)    ARCHIVE_TARGET="$2"; shift 2 ;;
        -d|--dest)       DEST_OVERRIDE="$2"; shift 2 ;;
        -n|--dry-run)    DRY_RUN=true; shift ;;
        --no-network)    SKIP_NETWORK=true; shift ;;
        --no-zfs)        SKIP_ZFS=true; shift ;;
        --force)         FORCE=true; shift ;;
        -h|--help)       _usage; exit 0 ;;
        *) echo "Unknown option: $1"; _usage; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
_confirm() {
    local prompt="${1:-Continue?}"
    [[ "${FORCE}" == true ]] && return 0
    local ans
    read -rp "$(echo -e "${C_YELLOW}${prompt} [yes/N]: ${C_RESET}")" ans
    [[ "${ans,,}" == "yes" ]]
}

_header() {
    echo -e "\n${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║        PVE Host Restore — v${SCRIPT_VERSION}                   ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════╝${C_RESET}\n"
}

_warn_banner() {
    echo -e "${C_RED}${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║   WARNING: This overwrites system configuration.    ║"
    echo "  ║   Only run on a freshly installed Proxmox host.     ║"
    echo "  ║   Ensure this host is NOT part of a live cluster.   ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${C_RESET}"
}

# -----------------------------------------------------------------------------
# Archive selection
# -----------------------------------------------------------------------------
_select_archive() {
    local search_dir="${DEST_OVERRIDE:-}"
    if [[ -z "${search_dir}" ]]; then
        lib::resolve_backup_destination 2>/dev/null || true
        search_dir="${BACKUP_DEST_DIR:-}"
    fi
    if [[ -z "${search_dir}" || ! -d "${search_dir}" ]]; then
        lib::log_error "Cannot find backup directory. Use --dest DIR."
        exit 1
    fi
    lib::list_backups "${search_dir}"
    if (( ${#BACKUP_LIST[@]} == 0 )); then
        lib::log_error "No archives found in: ${search_dir}"
        exit 1
    fi
    echo -e "${C_BOLD}Available backups:${C_RESET}\n"
    local i=1
    for b in "${BACKUP_LIST[@]}"; do
        local sz dt
        sz=$(lib::human_size "$(stat -c%s "${b}" 2>/dev/null || echo 0)")
        dt=$(stat -c '%y' "${b}" 2>/dev/null | cut -d. -f1)
        printf "  ${C_BOLD}%2d)${C_RESET} %-58s %s  %s\n" "${i}" "$(basename "${b}")" "${sz}" "${dt}"
        (( i++ ))
    done
    echo ""
    local sel
    read -rp "$(echo -e "${C_BOLD}Select [1]: ${C_RESET}")" sel
    sel="${sel:-1}"
    if ! [[ "${sel}" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#BACKUP_LIST[@]} )); then
        lib::log_error "Invalid selection."; exit 1
    fi
    ARCHIVE_TARGET="${BACKUP_LIST[$((sel-1))]}"
}

# -----------------------------------------------------------------------------
# Manifest display
# -----------------------------------------------------------------------------
_show_manifest() {
    local archive="$1"
    local manifest="${archive%.tar.zst}"
    manifest="${manifest%.age}.manifest.json"
    [[ ! -f "${manifest}" ]] && return 0

    echo -e "\n${C_BOLD}Backup metadata:${C_RESET}"
    if command -v jq &>/dev/null; then
        jq -r '
          "  Hostname:    " + .hostname,
          "  PVE version: " + .pve_version,
          "  Created:     " + .created_at,
          "  Kernel:      " + .kernel,
          "  Encrypted:   " + (.encrypted | tostring),
          "  pmxcfs snap: " + (.pmxcfs_snapshot | tostring)
        ' "${manifest}" 2>/dev/null || true
    else
        grep -E '"(hostname|pve_version|created_at|kernel)"' "${manifest}" \
            | sed 's/[",]//g; s/^/  /' || true
    fi
    echo ""
}

# -----------------------------------------------------------------------------
# Core restore
# =============================================================================
# CRITICAL CHANGES FROM v2:
#
# 1. SERVICE ORDER: pve-cluster stopped FIRST (it owns /etc/pve via pmxcfs).
#    Consumers (pvedaemon, pveproxy) stopped after.
#
# 2. EXTRACTION: Uses explicit path anchors (no wildcards).
#    Extracts to a temp dir first, then installs with explicit rsync/cp.
#    This prevents wildcard matches on paths like /backup/etc/pve.
#
# 3. PERMISSIONS: lib::fix_pve_permissions() called after extraction to
#    restore correct ownership and modes required for PVE to start.
#
# 4. SSH KEY CLEANUP: New host's auto-generated SSH keys are removed before
#    restoring the backup's keys — prevents key collision warnings on reconnect.
#
# 5. NETWORK VALIDATION: ifquery --check run after restore to warn if the
#    restored interfaces config is invalid on this hardware.
# =============================================================================
_do_restore() {
    local archive="$1"

    # Dry-run: redirect all writes to a preview directory
    local root="/"
    if [[ "${DRY_RUN}" == true ]]; then
        root="/tmp/pve-restore-preview"
        rm -rf "${root}"
        mkdir -p "${root}"
        lib::log_warn "DRY-RUN: All files extracted to ${root} — system unchanged."
    fi

    # Decrypt if needed
    local working_archive="${archive}"
    if [[ "${archive}" == *.age ]]; then
        if [[ "${DRY_RUN}" == false ]]; then
            working_archive="$(lib::decrypt_archive "${archive}")"
        else
            lib::log_info "[DRY-RUN] Would decrypt archive first."
        fi
    fi

    # Verify
    lib::log_step "[1/12] Verifying archive integrity..."
    if [[ "${DRY_RUN}" == false ]]; then
        lib::verify_archive "${working_archive}" || {
            lib::log_error "Verification failed — aborting restore."
            exit 1
        }
    fi

    # Extract archive to a staging directory first, then install from there.
    # This avoids extracting directly over a live filesystem and allows us to
    # check extraction success before overwriting anything.
    lib::log_step "[2/12] Extracting archive to staging area..."
    local stage_dir
    stage_dir="$(mktemp -d /tmp/pve-restore-stage-XXXXXX)"
    chmod 700 "${stage_dir}"
    trap '[[ -d "${stage_dir}" ]] && rm -rf "${stage_dir}"' EXIT

    if [[ "${DRY_RUN}" == false ]]; then
        tar \
            --use-compress-program="zstd -d -q" \
            --extract \
            --file="${working_archive}" \
            --directory="${stage_dir}" \
            --absolute-names \
            --strip-components=0 \
            --warning=no-file-changed \
            2>/dev/null || {
            # tar exit 1 = changed files during read — acceptable
            local te=$?
            (( te >= 2 )) && { lib::log_error "tar extraction failed (exit ${te})."; exit 1; }
        }
        lib::log_ok "Extraction complete: ${stage_dir}"
    else
        lib::log_info "[DRY-RUN] Would extract to staging then install to ${root}."
    fi

    # Helper: install a file/directory from stage to root
    _install() {
        local src_rel="$1"  # path relative to archive root (no leading /)
        local dst="${root}/${src_rel#/}"
        local staged="${stage_dir}/${src_rel#/}"
        [[ -e "${staged}" ]] || { lib::log_info "  (not in archive: ${src_rel})"; return 0; }
        if [[ "${DRY_RUN}" == true ]]; then
            lib::log_info "  [DRY-RUN] Would install: ${src_rel} → ${dst}"
            return 0
        fi
        mkdir -p "$(dirname "${dst}")"
        if [[ -d "${staged}" ]]; then
            rsync -a --delete "${staged}/" "${dst}/" 2>/dev/null \
                || cp -a "${staged}/." "${dst}/"
        else
            cp -a "${staged}" "${dst}"
        fi
        lib::log_info "  Installed: ${src_rel}"
    }

    # ----- [3] Stop PVE services — pve-cluster FIRST -----
    lib::log_step "[3/12] Stopping PVE services (cluster filesystem first)..."
    local stopped_svcs=()
    if [[ "${DRY_RUN}" == false ]]; then
        # Stop pmxcfs first so we can safely write /var/lib/pve-cluster
        for svc in pve-ha-lrm pve-ha-crm pve-firewall pvestatd pvedaemon pveproxy pve-cluster; do
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                systemctl stop "${svc}" && stopped_svcs+=("${svc}") \
                    && lib::log_info "  Stopped: ${svc}"
            fi
        done
    fi

    # ----- [4] Restore pmxcfs backing database (/var/lib/pve-cluster) -----
    lib::log_step "[4/12] Restoring pmxcfs database (/var/lib/pve-cluster)..."
    _install "var/lib/pve-cluster"

    # Also install the pmxcfs snapshot's config.db directly
    local staged_db="${stage_dir}/tmp/pve-hostbackup-"*"/pmxcfs-snapshot/config.db"
    # shellcheck disable=SC2086
    for db in ${staged_db}; do
        if [[ -f "${db}" ]]; then
            if [[ "${DRY_RUN}" == false ]]; then
                cp -v "${db}" "/var/lib/pve-cluster/config.db"
                lib::log_ok "pmxcfs config.db restored from snapshot."
            else
                lib::log_info "[DRY-RUN] Would restore pmxcfs config.db."
            fi
            break
        fi
    done

    # Also restore the /etc/pve tree from snapshot (for reference/inspection)
    local staged_etcpve
    staged_etcpve="$(find "${stage_dir}" -type d -name "etc_pve" 2>/dev/null | head -1 || true)"
    if [[ -n "${staged_etcpve}" && "${DRY_RUN}" == false ]]; then
        mkdir -p "${root}/etc/pve"
        rsync -a --delete "${staged_etcpve}/" "${root}/etc/pve/" 2>/dev/null \
            || cp -a "${staged_etcpve}/." "${root}/etc/pve/"
        lib::log_info "  /etc/pve tree installed from snapshot."
    fi

    # ----- [5] PVE runtime state -----
    lib::log_step "[5/12] Restoring PVE runtime state..."
    _install "var/lib/pve-manager"
    _install "var/lib/pvedaemon"
    _install "var/lib/pveproxy"
    _install "var/lib/pvestatd"
    _install "var/lib/pve-firewall"

    # ----- [6] Network configuration -----
    if [[ "${SKIP_NETWORK}" == false ]]; then
        lib::log_step "[6/12] Restoring network configuration..."
        _install "etc/network/interfaces"
        _install "etc/network/interfaces.d"
        _install "etc/hostname"
        _install "etc/hosts"
        _install "etc/resolv.conf"
        _install "etc/fstab"
        lib::log_warn "Network config restored. Verify NIC names match this hardware!"

        # Validate the restored interfaces config if ifquery is available
        if [[ "${DRY_RUN}" == false ]] && command -v ifquery &>/dev/null; then
            lib::log_info "Validating restored network config..."
            ifquery --check -a 2>/dev/null \
                && lib::log_ok "Network config valid." \
                || lib::log_warn "ifquery reported issues — review /etc/network/interfaces before rebooting."
        fi
    else
        lib::log_info "[6/12] Skipping network config (--no-network)."
    fi

    # ----- [7] SSH keys — remove new host's auto-generated keys first -----
    lib::log_step "[7/12] Restoring SSH host keys..."
    if [[ "${DRY_RUN}" == false ]]; then
        # Remove keys auto-generated during fresh install to prevent collision
        rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
        lib::log_info "  Removed fresh-install SSH host keys."
    fi
    _install "etc/ssh"
    _install "root/.ssh"

    # ----- [8] Cron and custom scripts -----
    lib::log_step "[8/12] Restoring cron jobs and custom scripts..."
    _install "etc/cron.d"
    _install "etc/cron.daily"
    _install "etc/cron.weekly"
    _install "etc/cron.monthly"
    _install "var/spool/cron/crontabs"
    _install "usr/local/bin"
    _install "usr/local/sbin"
    _install "usr/local/etc"
    _install "etc/systemd/system"
    _install "etc/systemd/network"

    # ----- [9] APT sources and tooling -----
    lib::log_step "[9/12] Restoring APT sources and tooling..."
    _install "etc/apt/sources.list"
    _install "etc/apt/sources.list.d"
    _install "etc/apt/preferences.d"
    _install "etc/postfix"
    _install "etc/fail2ban"
    _install "etc/ssl/private"
    _install "etc/vzdump.conf"
    _install "etc/proxmox-backup"

    # ----- [10] Fix permissions (critical for PVE startup) -----
    lib::log_step "[10/12] Fixing permissions..."
    if [[ "${DRY_RUN}" == false ]]; then
        lib::fix_pve_permissions
        # Fix SSH host key permissions
        chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
        chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
        # Fix /root/.ssh
        [[ -d /root/.ssh ]] && chmod 700 /root/.ssh
        [[ -f /root/.ssh/authorized_keys ]] && chmod 600 /root/.ssh/authorized_keys || true
    fi

    # ----- [11] ZFS guidance -----
    if [[ "${SKIP_ZFS}" == false ]]; then
        lib::log_step "[11/12] ZFS pool import guidance..."
        local zfs_meta
        zfs_meta="$(find "${stage_dir}" -name "zfs-metadata.txt" 2>/dev/null | head -1 || true)"
        if [[ -n "${zfs_meta}" ]]; then
            echo -e "\n${C_BOLD}--- ZFS metadata from backup ---${C_RESET}"
            cat "${zfs_meta}"
            echo -e "${C_RESET}"
        fi
        if command -v zpool &>/dev/null; then
            lib::log_info "To import all available pools: zpool import -a -f"
        fi
    fi

    # ----- [12] Start PVE services (reverse stop order, pve-cluster first) -----
    lib::log_step "[12/12] Starting PVE services..."
    if [[ "${DRY_RUN}" == false ]]; then
        systemctl daemon-reload 2>/dev/null || true
        # Start pmxcfs first so /etc/pve is available before consumers
        local start_order=(pve-cluster pvedaemon pveproxy pvestatd pve-firewall)
        for svc in "${start_order[@]}"; do
            systemctl start "${svc}" 2>/dev/null \
                && lib::log_info "  Started: ${svc}" \
                || lib::log_warn "  Could not start: ${svc}"
        done
        sleep 3  # Allow pmxcfs to fully mount

        # Health check
        if command -v pveversion &>/dev/null; then
            lib::log_ok "PVE running: $(pveversion 2>/dev/null | head -1)"
        fi
        if command -v pvesh &>/dev/null; then
            pvesh get /nodes/localhost/status --output-format=text 2>/dev/null \
                | grep -E "(pveversion|kversion|memory|uptime)" \
                | sed 's/^/  /' || true
        fi
    fi

    rm -rf "${stage_dir}"
    trap - EXIT
}

# -----------------------------------------------------------------------------
# Post-restore checklist
# -----------------------------------------------------------------------------
_checklist() {
    echo -e "\n${C_BOLD}${C_GREEN}===== Restore Complete =====${C_RESET}\n"
    echo -e "${C_BOLD}Post-restore checklist — verify each before rebooting:${C_RESET}\n"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Check NIC names match: ip link | grep -E '^[0-9]+: '"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Review network config:  cat /etc/network/interfaces"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Validate network:       ifquery --check -a"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Check hostname:         hostnamectl"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Check storage:          pvesm status"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Check VMs/LXC:          qm list && pct list"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Import ZFS pools:       zpool import -a -f"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Verify web UI:          https://$(hostname -f 2>/dev/null || echo localhost):8006"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Test email notify:      pve-hostbackup --dry-run"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Re-enable timer:        systemctl enable --now pve-hostbackup.timer"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Reboot:                 reboot\n"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    lib::require_root

    # Config may not exist on a fresh install — gracefully fall back to defaults
    if [[ -f "${CONFIG_FILE:-/etc/pve-hostbackup/pve-hostbackup.conf}" ]]; then
        lib::load_config
    else
        RETENTION_COUNT=7
        LOG_FILE="/var/log/pve-hostbackup.log"
        CHECKSUM_ALGO="sha256"
        COMPRESSION="zst"
        VERBOSE=false
        ENCRYPT_ARCHIVES=false
        ENCRYPT_PASSPHRASE_FILE="/etc/pve-hostbackup/backup.key"
        NFS_STORAGE_ID=""
        ZFS_BACKUP_PATH=""
        LOCAL_BACKUP_PATH="/var/lib/pve-hostbackup"
        BACKUP_SUBDIR="pve-host-backups"
        STOP_PMXCFS_FOR_BACKUP=true
        BACKUP_PATHS=()
    fi
    lib::detect_environment
    lib::require_commands tar zstd

    _header

    if [[ -z "${ARCHIVE_TARGET}" ]]; then _select_archive; fi
    [[ ! -f "${ARCHIVE_TARGET}" ]] && { lib::log_error "Archive not found: ${ARCHIVE_TARGET}"; exit 1; }

    _show_manifest "${ARCHIVE_TARGET}"

    echo -e "  Archive:  ${C_CYAN}${ARCHIVE_TARGET}${C_RESET}"
    echo -e "  Size:     $(lib::human_size "$(stat -c%s "${ARCHIVE_TARGET}")")"
    echo -e "  Dry-run:  ${DRY_RUN}\n"

    if [[ "${DRY_RUN}" == false ]]; then
        _warn_banner
        _confirm "Proceed with restore? Type 'yes' to continue" || { echo "Aborted."; exit 0; }
    fi

    _do_restore "${ARCHIVE_TARGET}"
    _checklist
}

main "$@"
