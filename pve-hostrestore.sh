#!/usr/bin/env bash
# =============================================================================
# pve-hostrestore.sh — Proxmox Host Configuration Restore v3.0.0
# Version-agnostic: PVE 7.x, 8.x, 9.x+
#
# Usage: pve-hostrestore.sh [OPTIONS]
#   -c, --config FILE    Config file path
#   -a, --archive FILE   Archive to restore
#   -d, --dest DIR       Directory to search for archives
#   -n, --dry-run        Extract to /tmp only — safe preview
#       --no-network     Skip network configuration restore
#       --no-zfs         Skip ZFS guidance
#       --pmxcfs-restore Restore /etc/pve from embedded config.db snapshot
#       --force          Skip confirmation prompts
#   -h, --help           Show help
#
# v3 changes (post code-review):
#   - pve-cluster stopped FIRST (owns /etc/pve FUSE lock)
#   - Path-anchored tar extraction (no wildcard over-match)
#   - Explicit chmod/chown pass on critical paths after extraction
#   - SSH host key collision prevention (old keys backed up, then replaced)
#   - Dry-run uses mktemp -d (secure, not /tmp/hardcoded)
#   - Optional pmxcfs config.db restore for full consistency
#   - ifreload --dry-run network validation before commit
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/pve-hostbackup-lib.sh"

[[ ! -f "${LIB_FILE}" ]] && { echo "ERROR: Library not found: ${LIB_FILE}" >&2; exit 1; }
source "${LIB_FILE}"

# =============================================================================
# Argument parsing
# =============================================================================
ARCHIVE_TARGET=""
DEST_OVERRIDE=""
DRY_RUN=false
SKIP_NETWORK=false
SKIP_ZFS=false
DO_PMXCFS_RESTORE=false
FORCE=false
EXTRACT_ROOT="/"
DRY_RUN_DIR=""

_usage() {
    cat <<EOF
${C_BOLD}pve-hostrestore${C_RESET} v${SCRIPT_VERSION} — Proxmox host restore wizard

Usage: $(basename "$0") [OPTIONS]

  -c, --config FILE      Config file (default: /etc/pve-hostbackup/pve-hostbackup.conf)
  -a, --archive FILE     Archive to restore (skips interactive selection)
  -d, --dest DIR         Search directory for archives
  -n, --dry-run          Extract to secure temp dir — no system files touched
      --no-network       Skip network configuration restore
      --no-zfs           Skip ZFS import guidance
      --pmxcfs-restore   Restore /etc/pve via embedded config.db snapshot (recommended)
      --force            Skip confirmation prompts
  -h, --help             Show this help

Typical post-reinstall workflow:
  1. Copy archive to new host (SCP or mount NFS)
  2. Run: $(basename "$0") --archive /path/to/pvehost-backup.tar.zst --pmxcfs-restore
  3. Follow the checklist printed at completion
  4. Reboot

Safe preview (no system changes):
  $(basename "$0") --archive /path/to/archive.tar.zst --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)        CONFIG_FILE="$2"; shift 2 ;;
        -a|--archive)       ARCHIVE_TARGET="$2"; shift 2 ;;
        -d|--dest)          DEST_OVERRIDE="$2"; shift 2 ;;
        -n|--dry-run)       DRY_RUN=true; shift ;;
        --no-network)       SKIP_NETWORK=true; shift ;;
        --no-zfs)           SKIP_ZFS=true; shift ;;
        --pmxcfs-restore)   DO_PMXCFS_RESTORE=true; shift ;;
        --force)            FORCE=true; shift ;;
        -h|--help)          _usage; exit 0 ;;
        *)                  echo "Unknown option: $1"; _usage; exit 1 ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

_confirm() {
    local prompt="${1:-Continue?}"
    [[ "${FORCE}" == true ]] && return 0
    read -rp "$(echo -e "${C_YELLOW}${prompt} [yes/N]: ${C_RESET}")" ans
    [[ "${ans}" == "yes" ]]
}

_print_header() {
    echo -e "\n${C_BOLD}${C_CYAN}======================================================${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}  PVE Host Restore — v${SCRIPT_VERSION}${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}======================================================${C_RESET}\n"
}

_print_danger_banner() {
    echo -e "${C_RED}${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  WARNING: This OVERWRITES system configuration.     ║"
    echo "  ║  Run ONLY on a freshly installed Proxmox host.      ║"
    echo "  ║  Do NOT run on a node that is part of a cluster.    ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${C_RESET}"
}

# =============================================================================
# Archive selection
# =============================================================================
_select_archive() {
    local search_dir="${DEST_OVERRIDE:-}"

    if [[ -z "${search_dir}" ]]; then
        lib::resolve_backup_destination 2>/dev/null || true
        search_dir="${BACKUP_DEST_DIR:-}"
    fi

    if [[ -z "${search_dir}" ]] || [[ ! -d "${search_dir}" ]]; then
        lib::log_error "Cannot locate backup directory. Use --dest to specify."
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
        local sz; sz=$(lib::human_size "$(stat -c%s "${b}" 2>/dev/null || echo 0)")
        local dt; dt=$(stat -c '%y' "${b}" 2>/dev/null | cut -d. -f1)
        printf "  ${C_BOLD}%2d)${C_RESET}  %-58s  %-10s  %s\n" "${i}" "$(basename "${b}")" "${sz}" "${dt}"
        (( i++ ))
    done

    echo ""
    read -rp "$(echo -e "${C_BOLD}Select backup [1]: ${C_RESET}")" sel
    sel="${sel:-1}"

    if ! [[ "${sel}" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#BACKUP_LIST[@]} )); then
        lib::log_error "Invalid selection."
        exit 1
    fi
    ARCHIVE_TARGET="${BACKUP_LIST[$((sel-1))]}"
    lib::log_info "Selected: $(basename "${ARCHIVE_TARGET}")"
}

# =============================================================================
# Read manifest from sidecar file or from inside archive
# =============================================================================
_read_manifest() {
    local archive="$1"
    local base="${archive%.enc}"
    base="${base%.tar.zst}"
    local sidecar="${base}.manifest.json"

    if [[ -f "${sidecar}" ]]; then
        echo "${sidecar}"
        return
    fi

    # Try extracting from inside the archive
    local tmp
    tmp="$(mktemp /tmp/pve-restore-manifest-XXXXXX.json)"
    if tar --use-compress-program="zstd -d" \
           --extract --to-stdout \
           --file="${archive}" \
           --wildcards "*.manifest.json" 2>/dev/null > "${tmp}" \
       && [[ -s "${tmp}" ]]; then
        echo "${tmp}"
    else
        rm -f "${tmp}"
        echo ""
    fi
}

# =============================================================================
# Display restore plan
# =============================================================================
_display_restore_plan() {
    local archive="$1"
    local manifest="$2"

    echo -e "\n${C_BOLD}=== Restore Plan ===${C_RESET}\n"
    echo -e "  Archive:  ${C_CYAN}$(basename "${archive}")${C_RESET}"
    echo -e "  Path:     ${archive}"
    echo -e "  Size:     $(lib::human_size "$(stat -c%s "${archive}" 2>/dev/null || echo 0)")"
    echo -e "  Dry-run:  ${DRY_RUN}"
    echo ""

    if [[ -n "${manifest}" ]] && command -v jq &>/dev/null; then
        echo -e "  ${C_BOLD}Backup origin:${C_RESET}"
        jq -r '
            "    Hostname:    " + .hostname,
            "    PVE version: " + .pve_version,
            "    Created:     " + .created_at,
            "    Kernel:      " + .kernel,
            "    Encrypted:   " + (.encrypted | tostring),
            "    pmxcfs snap: " + (.pmxcfs_snapshot_included | tostring)
        ' "${manifest}" 2>/dev/null || true
        echo ""
    fi

    echo -e "  ${C_BOLD}Restore phases:${C_RESET}"
    echo -e "    1.  Verify archive integrity"
    echo -e "    2.  Stop PVE services (pve-cluster first)"
    echo -e "    3.  Extract /etc/pve (core VM/LXC/storage config)"
    echo -e "    4.  Extract /var/lib/pve-*"
    [[ "${SKIP_NETWORK}" == false ]] && \
    echo -e "    5.  Restore network configuration (with ifreload validation)"
    echo -e "    6.  Restore SSH keys (back up new host keys first)"
    echo -e "    7.  Restore cron, scripts, systemd units, apt sources"
    echo -e "    8.  Fix permissions on critical directories"
    [[ "${DO_PMXCFS_RESTORE}" == true ]] && \
    echo -e "    9.  Restore pmxcfs config.db snapshot"
    [[ "${SKIP_ZFS}" == false ]] && \
    echo -e "   10.  Display ZFS pool import guidance"
    echo -e "   11.  Start PVE services"
    echo -e "   12.  Verify PVE health"
    echo ""
}

# =============================================================================
# Path-anchored extraction — avoids wildcard over-matching
# Extracts only paths that begin with the given prefix.
# =============================================================================
_extract_exact() {
    local archive="$1"; shift
    local dest="$1"; shift
    local paths=("$@")

    [[ ${#paths[@]} -eq 0 ]] && return 0

    local tar_args=(
        --use-compress-program="zstd -d"
        --extract
        --file="${archive}"
        --absolute-names
        --preserve-permissions
        --same-owner
        --warning=no-file-changed
        --overwrite
        --directory="${dest}"
    )

    # Build explicit path list — no wildcards
    tar "${tar_args[@]}" "${paths[@]}" 2>/dev/null || true
}

# =============================================================================
# List paths inside archive that start with a given prefix
# =============================================================================
_archive_paths_matching() {
    local archive="$1"
    local prefix="$2"
    tar --use-compress-program="zstd -d" -tf "${archive}" 2>/dev/null \
        | grep -E "^${prefix}" \
        | head -200 \
        || true
}

# =============================================================================
# Collect all archive members matching a path prefix, then extract them
# =============================================================================
_extract_prefix() {
    local phase_name="$1"
    local archive="$2"
    local dest="$3"
    local prefix="$4"

    lib::log_info "  Extracting '${phase_name}' (prefix: ${prefix})..."

    # Get the list of matching members
    local members=()
    mapfile -t members < <(_archive_paths_matching "${archive}" "${prefix}")

    if (( ${#members[@]} == 0 )); then
        lib::log_info "  No members found for prefix '${prefix}' — skipping."
        return
    fi

    local tar_args=(
        --use-compress-program="zstd -d"
        --extract
        --file="${archive}"
        --absolute-names
        --preserve-permissions
        --same-owner
        --warning=no-file-changed
        --overwrite
        --directory="${dest}"
    )

    tar "${tar_args[@]}" "${members[@]}" 2>/dev/null || true
    lib::log_info "  Extracted ${#members[@]} entries for '${phase_name}'."
}

# =============================================================================
# Critical path permissions (fixes restore permission fidelity)
# These must match what a fresh PVE installation sets.
# =============================================================================
_fix_permissions() {
    local root="${1:-/}"

    lib::log_step "Fixing critical directory permissions..."

    local -A dirs=(
        ["/etc/pve"]="700:root:root"
        ["/etc/pve/priv"]="700:root:root"
        ["/etc/ssh"]="700:root:root"
        ["/root/.ssh"]="700:root:root"
        ["/var/lib/pve-cluster"]="750:root:www-data"
        ["/var/lib/pvedaemon"]="750:root:root"
        ["/var/lib/pveproxy"]="750:root:www-data"
    )

    for rel_path in "${!dirs[@]}"; do
        local full_path="${root%/}${rel_path}"
        if [[ ! -d "${full_path}" ]]; then
            continue
        fi
        local spec="${dirs[$rel_path]}"
        local mode; mode="$(echo "${spec}" | cut -d: -f1)"
        local owner; owner="$(echo "${spec}" | cut -d: -f2)"
        local group; group="$(echo "${spec}" | cut -d: -f3)"

        chmod "${mode}" "${full_path}" 2>/dev/null \
            && lib::log_info "  chmod ${mode} ${full_path}" \
            || lib::log_warn "  chmod failed: ${full_path}"

        if [[ "${root}" == "/" ]]; then
            chown "${owner}:${group}" "${full_path}" 2>/dev/null \
                && lib::log_info "  chown ${owner}:${group} ${full_path}" \
                || lib::log_warn "  chown failed: ${full_path}"
        fi
    done

    # SSH authorized_keys: 600
    local ak="${root%/}/root/.ssh/authorized_keys"
    if [[ -f "${ak}" ]]; then
        chmod 600 "${ak}"
        lib::log_info "  chmod 600 ${ak}"
    fi

    lib::log_ok "Permissions fixed."
}

# =============================================================================
# Core restore
# =============================================================================
_do_restore() {
    local archive="$1"

    # Set up dry-run extraction target
    if [[ "${DRY_RUN}" == true ]]; then
        DRY_RUN_DIR="$(mktemp -d /tmp/pve-restore-XXXXXX)"
        chmod 700 "${DRY_RUN_DIR}"
        EXTRACT_ROOT="${DRY_RUN_DIR}"
        lib::log_warn "DRY-RUN: Extracting to ${EXTRACT_ROOT} — no system files touched."
    fi

    # --- 1. Verify ---
    lib::log_step "[1/12] Verifying archive integrity..."
    lib::verify_archive "${archive}" || {
        lib::log_error "Archive verification failed. Aborting."
        exit 1
    }

    # --- 2. Stop PVE services: pve-cluster FIRST ---
    lib::log_step "[2/12] Stopping PVE services..."
    local stopped_services=()
    # Order matters: pve-cluster owns /etc/pve FUSE lock — must stop first
    local services_to_stop=(
        pve-cluster
        pve-ha-crm pve-ha-lrm
        pvedaemon pveproxy pvestatd
        pve-firewall
    )
    if [[ "${DRY_RUN}" == false ]]; then
        for svc in "${services_to_stop[@]}"; do
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                systemctl stop "${svc}" \
                    && stopped_services+=("${svc}") \
                    && lib::log_info "  Stopped: ${svc}" \
                    || lib::log_warn "  Could not stop: ${svc}"
            fi
        done
    else
        lib::log_info "  [DRY-RUN] Would stop PVE services."
    fi

    # Ensure services are restarted on unexpected exit
    _restart_services() {
        lib::log_info "Restarting PVE services..."
        local start_order=(pve-cluster pvedaemon pveproxy pvestatd pve-firewall)
        for svc in "${start_order[@]}"; do
            systemctl start "${svc}" 2>/dev/null || true
        done
    }
    trap '_restart_services' EXIT INT TERM HUP

    # --- 3. /etc/pve ---
    lib::log_step "[3/12] Restoring /etc/pve..."
    mkdir -p "${EXTRACT_ROOT}/etc/pve"
    _extract_prefix "etc/pve" "${archive}" "${EXTRACT_ROOT}" "/etc/pve/"

    # --- 4. /var/lib/pve-* ---
    lib::log_step "[4/12] Restoring /var/lib/pve-*..."
    for varlibpath in /var/lib/pve-cluster /var/lib/pvedaemon /var/lib/pveproxy /var/lib/pvestatd /var/lib/pve-manager /var/lib/pve-firewall; do
        _extract_prefix "${varlibpath}" "${archive}" "${EXTRACT_ROOT}" "${varlibpath}/"
    done

    # --- 5. Network ---
    if [[ "${SKIP_NETWORK}" == false ]]; then
        lib::log_step "[5/12] Restoring network configuration..."
        for netpath in /etc/network/interfaces /etc/network/interfaces.d /etc/hostname /etc/hosts /etc/resolv.conf /etc/fstab; do
            _extract_prefix "${netpath}" "${archive}" "${EXTRACT_ROOT}" "${netpath}"
        done

        # Validate network config with ifreload before allowing reboot
        if [[ "${DRY_RUN}" == false ]] && command -v ifreload &>/dev/null; then
            lib::log_info "Validating network config with ifreload --dry-run..."
            if ifreload -a --dry-run &>/dev/null; then
                lib::log_ok "ifreload validation passed."
            else
                lib::log_warn "ifreload validation reported issues. Review /etc/network/interfaces before rebooting."
            fi
        fi
    else
        lib::log_info "[5/12] Skipping network restore (--no-network)."
    fi

    # --- 6. SSH keys — back up new host keys first to prevent collision ---
    lib::log_step "[6/12] Restoring SSH host keys..."
    if [[ "${DRY_RUN}" == false ]]; then
        local ssh_backup_dir="/etc/ssh/pre-restore-$(date +%Y%m%d%H%M%S)"
        if [[ -d /etc/ssh ]]; then
            mkdir -p "${ssh_backup_dir}"
            cp -a /etc/ssh/ssh_host_* "${ssh_backup_dir}/" 2>/dev/null || true
            lib::log_info "New host SSH keys backed up to: ${ssh_backup_dir}"
        fi
    fi
    _extract_prefix "etc/ssh" "${archive}" "${EXTRACT_ROOT}" "/etc/ssh/"
    _extract_prefix "root/.ssh" "${archive}" "${EXTRACT_ROOT}" "/root/.ssh/"

    # --- 7. Cron, scripts, systemd, apt ---
    lib::log_step "[7/12] Restoring cron, scripts, systemd units, apt sources..."
    local misc_paths=(
        /etc/cron.d
        /etc/cron.daily
        /etc/cron.weekly
        /etc/cron.monthly
        /var/spool/cron
        /usr/local/bin
        /usr/local/sbin
        /usr/local/etc
        /etc/systemd/system
        /etc/systemd/network
        /etc/apt/sources.list
        /etc/apt/sources.list.d
        /etc/apt/preferences.d
        /etc/postfix
        /etc/fail2ban
        /etc/vzdump.conf
        /etc/proxmox-backup
        /etc/corosync
        /etc/ssl/private
        /usr/local/share/ca-certificates
    )
    for mpath in "${misc_paths[@]}"; do
        _extract_prefix "${mpath}" "${archive}" "${EXTRACT_ROOT}" "${mpath}"
    done

    # --- 8. Fix permissions ---
    lib::log_step "[8/12] Fixing permissions on critical paths..."
    _fix_permissions "${EXTRACT_ROOT}"

    # --- 9. pmxcfs config.db restore (optional but recommended) ---
    if [[ "${DO_PMXCFS_RESTORE}" == true ]]; then
        lib::log_step "[9/12] Restoring pmxcfs config.db snapshot..."

        # Extract the snapshot from the archive
        local snapshot_path="${EXTRACT_ROOT}/tmp/pve-config.db.snapshot"
        _extract_prefix "pve-config.db" "${archive}" "${EXTRACT_ROOT}" "/tmp/pve-config.db.snapshot"

        local db_dest="/var/lib/pve-cluster/config.db"
        if [[ "${DRY_RUN}" == false ]] && [[ -f "${snapshot_path}" ]]; then
            # Back up the fresh install's (empty) db first
            cp -a "${db_dest}" "${db_dest}.pre-restore-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            cp -a "${snapshot_path}" "${db_dest}"
            chmod 640 "${db_dest}"
            chown root:root "${db_dest}"
            lib::log_ok "pmxcfs config.db restored from snapshot."
        elif [[ "${DRY_RUN}" == true ]]; then
            lib::log_info "  [DRY-RUN] Would restore config.db to ${db_dest}"
        else
            lib::log_warn "  pmxcfs snapshot not found in archive — /etc/pve restored from tar extraction only."
        fi
    else
        lib::log_info "[9/12] pmxcfs config.db restore skipped (use --pmxcfs-restore to enable)."
    fi

    # --- 10. ZFS guidance ---
    if [[ "${SKIP_ZFS}" == false ]]; then
        lib::log_step "[10/12] ZFS pool import guidance..."
        local zfs_meta="${EXTRACT_ROOT}/tmp/zfs-metadata.txt"
        if [[ -f "${zfs_meta}" ]]; then
            echo -e "\n${C_BOLD}--- ZFS metadata from backup ---${C_RESET}"
            cat "${zfs_meta}"
        else
            lib::log_info "No ZFS metadata in archive."
        fi
        if command -v zpool &>/dev/null; then
            lib::log_info "After reboot, import pools with: zpool import -a"
        fi
    fi

    # --- 11. Start PVE services ---
    lib::log_step "[11/12] Starting PVE services..."
    if [[ "${DRY_RUN}" == false ]]; then
        # Cancel the EXIT trap (we're starting services ourselves)
        trap - EXIT INT TERM HUP
        _restart_services
    else
        lib::log_info "  [DRY-RUN] Would start PVE services."
        lib::log_info "  Dry-run files are in: ${EXTRACT_ROOT}"
        trap - EXIT INT TERM HUP
    fi

    # --- 12. Health check ---
    lib::log_step "[12/12] PVE health check..."
    if [[ "${DRY_RUN}" == false ]]; then
        sleep 3
        if command -v pveversion &>/dev/null; then
            lib::log_ok "PVE running: $(pveversion 2>/dev/null | head -1)"
        fi
        if command -v pvesh &>/dev/null; then
            pvesh get /nodes/localhost/status --output-format=text 2>/dev/null \
                | grep -E "^(kversion|pveversion|uptime)" \
                | while IFS= read -r ln; do lib::log_info "  ${ln}"; done \
            || lib::log_warn "pvesh status check returned errors (may be normal right after restore)."
        fi
    fi
}

# =============================================================================
# Post-restore checklist
# =============================================================================
_post_restore_checklist() {
    echo -e "\n${C_BOLD}${C_GREEN}===== Restore Complete =====${C_RESET}\n"
    echo -e "${C_BOLD}Post-restore checklist:${C_RESET}"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Verify NIC names match backup: ip link show"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Review network config: cat /etc/network/interfaces"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Verify hostname: hostnamectl"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Verify storage mounts: pvesm status"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Verify VMs/LXC: qm list && pct list"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Import ZFS pools if on separate disks: zpool import -a"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Confirm web UI accessible: https://$(hostname -f 2>/dev/null || echo "<host>"):8006"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Reinstall pve-hostbackup and re-enable timer"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Test email notifications"
    echo -e "  ${C_YELLOW}[ ]${C_RESET} Reboot to confirm clean startup\n"
    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "  ${C_CYAN}Dry-run output: ${EXTRACT_ROOT}${C_RESET}\n"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    lib::require_root
    lib::require_commands tar zstd

    # Config is optional on a fresh install
    if [[ -f "${CONFIG_FILE:-/etc/pve-hostbackup/pve-hostbackup.conf}" ]]; then
        lib::load_config
    else
        RETENTION_COUNT=7
        LOG_FILE="/var/log/pve-hostbackup.log"
        CHECKSUM_ALGO="sha256"
        COMPRESS="zst"
        VERBOSE=false
        ENCRYPT_ARCHIVE=false
        ENCRYPT_PASSPHRASE_FILE=""
        FREE_SPACE_MIN_MB=512
    fi
    lib::detect_environment

    _print_header

    [[ -z "${ARCHIVE_TARGET}" ]] && _select_archive

    if [[ ! -f "${ARCHIVE_TARGET}" ]]; then
        lib::log_error "Archive not found: ${ARCHIVE_TARGET}"
        exit 1
    fi

    local manifest
    manifest="$(_read_manifest "${ARCHIVE_TARGET}")"

    _display_restore_plan "${ARCHIVE_TARGET}" "${manifest}"

    if [[ "${DRY_RUN}" == false ]]; then
        _print_danger_banner
        _confirm "Proceed with restore? Type 'yes' to confirm" || { echo "Aborted."; exit 0; }
    fi

    _do_restore "${ARCHIVE_TARGET}"

    [[ -n "${manifest}" ]] && [[ "${manifest}" == /tmp/* ]] && rm -f "${manifest}"

    _post_restore_checklist
}

main "$@"
