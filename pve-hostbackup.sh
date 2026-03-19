#!/usr/bin/env bash
# =============================================================================
# pve-hostbackup.sh — Proxmox Host Configuration Backup v3.0.0
# Version-agnostic: PVE 7.x, 8.x, 9.x+
#
# Usage: pve-hostbackup.sh [OPTIONS]
#   -c, --config FILE    Config file path
#   -d, --dest DIR       Override backup destination
#   -v, --verbose        Verbose output
#   -n, --dry-run        Simulate without writing files
#       --list           List existing backups and exit
#       --verify FILE    Verify a specific archive and exit
#   -h, --help           Show help
#
# v3 changes (post code-review):
#   - pve-cluster stopped FIRST before touching /etc/pve (pmxcfs fix)
#   - /etc/pve backed up via pmxcfs config.db snapshot (atomic, consistent)
#   - tar --one-file-system REMOVED; /etc/pve explicitly included
#   - PIPESTATUS checked after tar pipeline (no silent failure)
#   - Free-space check before writing archive
#   - Prune runs AFTER new backup is confirmed good
#   - Optional archive encryption (age / openssl)
#   - Additional paths: /etc/pve/priv, /etc/vzdump.conf, /var/lib/pve-manager/apl-info
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/pve-hostbackup-lib.sh"

[[ ! -f "${LIB_FILE}" ]] && { echo "ERROR: Library not found: ${LIB_FILE}" >&2; exit 1; }
# shellcheck source=pve-hostbackup-lib.sh
source "${LIB_FILE}"

# =============================================================================
# Argument parsing
# =============================================================================
DRY_RUN=false
DEST_OVERRIDE=""
DO_LIST=false
VERIFY_TARGET=""

_usage() {
    cat <<EOF
${C_BOLD}pve-hostbackup${C_RESET} v${SCRIPT_VERSION} — Proxmox host configuration backup

Usage: $(basename "$0") [OPTIONS]

  -c, --config FILE    Config file (default: /etc/pve-hostbackup/pve-hostbackup.conf)
  -d, --dest DIR       Override backup destination directory
  -v, --verbose        Verbose output
  -n, --dry-run        Simulate backup without writing any files
      --list           List all available backups and exit
      --verify FILE    Verify integrity of a specific archive and exit
  -h, --help           Show this help

Examples:
  $(basename "$0")                        # Run backup with defaults
  $(basename "$0") --dry-run              # Simulate — safe to run any time
  $(basename "$0") --list                 # Show all stored backups
  $(basename "$0") --verify /path/to.tar.zst
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
        -d|--dest)    DEST_OVERRIDE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        --list)       DO_LIST=true; shift ;;
        --verify)     VERIFY_TARGET="$2"; shift 2 ;;
        -h|--help)    _usage; exit 0 ;;
        *)            echo "Unknown option: $1"; _usage; exit 1 ;;
    esac
done

# =============================================================================
# Bootstrap
# =============================================================================
lib::require_root
lib::load_config
lib::detect_environment
[[ "${VERBOSE:-false}" == true ]] && set -x
lib::_rotate_log

# Handle --list
if [[ "${DO_LIST}" == true ]]; then
    lib::resolve_backup_destination || exit 1
    lib::list_backups
    if (( ${#BACKUP_LIST[@]} == 0 )); then
        echo "No backups found in ${BACKUP_DEST_DIR}"
        exit 0
    fi
    echo -e "\n${C_BOLD}Available backups in ${BACKUP_DEST_DIR}:${C_RESET}"
    printf "%-4s  %-58s  %-10s  %s\n" "NUM" "FILENAME" "SIZE" "DATE"
    printf '%0.s-' {1..90}; echo
    local_i=1
    for b in "${BACKUP_LIST[@]}"; do
        local sz; sz=$(lib::human_size "$(stat -c%s "${b}" 2>/dev/null || echo 0)")
        local dt; dt=$(stat -c '%y' "${b}" 2>/dev/null | cut -d. -f1)
        printf "%-4s  %-58s  %-10s  %s\n" "${local_i}" "$(basename "${b}")" "${sz}" "${dt}"
        (( local_i++ ))
    done
    exit 0
fi

# Handle --verify
if [[ -n "${VERIFY_TARGET}" ]]; then
    lib::verify_archive "${VERIFY_TARGET}"
    exit $?
fi

# =============================================================================
# Main backup
# =============================================================================
main() {
    local start_ts
    start_ts="$(date +%s)"
    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    local archive_base="pvehost-${HOSTNAME_SHORT}-${PVE_VERSION}-${timestamp}"
    local archive_name="${archive_base}.tar.zst"

    lib::log_step "===== PVE Host Backup v${SCRIPT_VERSION} Started ====="
    lib::log_info  "Host:        ${HOSTNAME_SHORT}"
    lib::log_info  "PVE version: ${PVE_VERSION}"
    lib::log_info  "Timestamp:   ${timestamp}"
    lib::log_info  "Dry-run:     ${DRY_RUN}"

    [[ "${DRY_RUN}" == false ]] && lib::acquire_lock

    # -------------------------------------------------------------------------
    # Resolve destination
    # -------------------------------------------------------------------------
    if [[ -n "${DEST_OVERRIDE}" ]]; then
        BACKUP_DEST_DIR="${DEST_OVERRIDE}"
        mkdir -p "${BACKUP_DEST_DIR}"
    else
        lib::resolve_backup_destination || {
            lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
                "No writable backup destination found. Check storage configuration.\nLog: ${LOG_FILE}"
            exit 1
        }
    fi
    lib::log_info "Destination: ${BACKUP_DEST_DIR}"

    # -------------------------------------------------------------------------
    # Free space check (before doing anything destructive)
    # -------------------------------------------------------------------------
    lib::check_free_space "${BACKUP_DEST_DIR}" || {
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "Insufficient disk space at ${BACKUP_DEST_DIR}.\nLog: ${LOG_FILE}"
        exit 1
    }

    local archive_path="${BACKUP_DEST_DIR}/${archive_name}"
    local manifest_path="${BACKUP_DEST_DIR}/${archive_base}.manifest.json"

    # -------------------------------------------------------------------------
    # Secure work directory (chmod 700 — not world-readable)
    # -------------------------------------------------------------------------
    local WORK_DIR
    WORK_DIR="$(lib::make_work_dir)"
    trap '[[ -d "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"' EXIT

    # -------------------------------------------------------------------------
    # Stop pve-cluster FIRST to quiesce pmxcfs before touching /etc/pve
    # pve-cluster holds the FUSE mount; stopping it flushes to config.db
    # -------------------------------------------------------------------------
    local pve_cluster_was_running=false
    if [[ "${DRY_RUN}" == false ]]; then
        if systemctl is-active --quiet pve-cluster 2>/dev/null; then
            lib::log_step "Quiescing pmxcfs (stopping pve-cluster)..."
            systemctl stop pve-cluster
            pve_cluster_was_running=true
            lib::log_info "pve-cluster stopped — /etc/pve is now quiesced."
        fi
    fi

    # Ensure pve-cluster is restarted even on unexpected exit
    _restart_cluster() {
        if [[ "${pve_cluster_was_running}" == true ]]; then
            systemctl start pve-cluster 2>/dev/null || true
            lib::log_info "pve-cluster restarted."
        fi
        [[ -d "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
    }
    trap '_restart_cluster' EXIT INT TERM HUP

    # -------------------------------------------------------------------------
    # pmxcfs config.db snapshot — atomic consistent copy of /etc/pve
    # The backing SQLite database is at a fixed path; we copy it while
    # pmxcfs is stopped, giving us a point-in-time consistent snapshot.
    # -------------------------------------------------------------------------
    local pve_config_db="/var/lib/pve-cluster/config.db"
    local pve_config_snapshot=""
    if [[ "${DRY_RUN}" == false ]] && [[ -f "${pve_config_db}" ]]; then
        lib::log_step "Snapshotting pmxcfs config.db..."
        pve_config_snapshot="${WORK_DIR}/pve-config.db.snapshot"
        cp -a "${pve_config_db}" "${pve_config_snapshot}"
        lib::log_info "pmxcfs snapshot: ${pve_config_snapshot} ($(lib::human_size "$(stat -c%s "${pve_config_snapshot}")"))"
    fi

    # Restart cluster before the potentially long tar operation
    if [[ "${pve_cluster_was_running}" == true ]] && [[ "${DRY_RUN}" == false ]]; then
        lib::log_step "Restarting pve-cluster (quiesce window complete)..."
        systemctl start pve-cluster
        pve_cluster_was_running=false
        lib::log_info "pve-cluster running. Backup continues in background."
    fi

    # -------------------------------------------------------------------------
    # Collect paths
    # -------------------------------------------------------------------------
    lib::log_step "Collecting backup paths..."
    local valid_paths=()
    local skipped_paths=()

    for p in "${BACKUP_PATHS[@]}"; do
        if [[ -e "${p}" ]]; then
            valid_paths+=("${p}")
            lib::log_info "  + ${p}"
        else
            skipped_paths+=("${p}")
            lib::log_info "  - ${p} (not found)"
        fi
    done

    # Always include the pmxcfs snapshot if we got one
    if [[ -n "${pve_config_snapshot}" ]] && [[ -f "${pve_config_snapshot}" ]]; then
        valid_paths+=("${pve_config_snapshot}")
        lib::log_info "  + ${pve_config_snapshot} (pmxcfs snapshot)"
    fi

    lib::log_info "Paths: ${#valid_paths[@]} included, ${#skipped_paths[@]} skipped."

    # -------------------------------------------------------------------------
    # ZFS metadata capture (informational — not a zfs send)
    # -------------------------------------------------------------------------
    local zfs_meta_file=""
    if [[ "${ZFS_CAPTURE_ENABLED:-true}" == true ]] && command -v zpool &>/dev/null; then
        lib::log_step "Capturing ZFS pool metadata..."
        zfs_meta_file="${WORK_DIR}/zfs-metadata.txt"
        {
            echo "=== zpool list ($(date)) ==="
            zpool list -v 2>/dev/null || echo "(no pools or zpool unavailable)"
            echo ""
            echo "=== zpool status ==="
            zpool status 2>/dev/null || true
            echo ""
            echo "=== zfs list ==="
            zfs list -o name,used,avail,refer,mountpoint 2>/dev/null || true
            echo ""
            echo "=== zpool import commands for restore ==="
            zpool list -H -o name 2>/dev/null | while IFS= read -r pool; do
                echo "  zpool import -f ${pool}"
            done
        } > "${zfs_meta_file}"
        valid_paths+=("${zfs_meta_file}")
    fi

    # -------------------------------------------------------------------------
    # Generate manifest
    # -------------------------------------------------------------------------
    lib::log_step "Writing manifest..."
    local pvesm_out=""
    pvesm_out="$(pvesm status 2>/dev/null || echo 'pvesm not available')"
    local net_json=""
    net_json="$(ip -j addr 2>/dev/null || echo '[]')"

    # Build manifest safely without relying on jq for construction
    cat > "${manifest_path}" <<MANIFEST
{
  "schema_version": "3",
  "tool_version": "${SCRIPT_VERSION}",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "${HOSTNAME_SHORT}",
  "fqdn": "$(hostname -f 2>/dev/null || echo "${HOSTNAME_SHORT}")",
  "pve_version": "${PVE_VERSION}",
  "kernel": "$(uname -r)",
  "archive_name": "${archive_name}",
  "compression": "${COMPRESSION}",
  "checksum_algo": "${CHECKSUM_ALGO}",
  "encrypted": ${ENCRYPT_ARCHIVE:-false},
  "pmxcfs_snapshot_included": $([ -n "${pve_config_snapshot}" ] && echo true || echo false),
  "pvesm_status": $(echo "${pvesm_out}" | jq -Rs . 2>/dev/null || echo '"(jq not available)"'),
  "network_interfaces": $(echo "${net_json}" | jq . 2>/dev/null || echo '[]'),
  "restore_procedure": [
    "1. Reinstall Proxmox VE (same or newer version) on the target host.",
    "2. Copy archive + manifest to the new host.",
    "3. Run: pve-hostrestore.sh --archive <path-to-archive>",
    "4. The restore wizard will stop pve-cluster, extract configs, fix permissions.",
    "5. Optionally restore pmxcfs from the included config.db snapshot.",
    "6. Review /etc/network/interfaces before rebooting.",
    "7. Re-import ZFS pools: zpool import -a",
    "8. Reboot."
  ]
}
MANIFEST
    lib::log_info "Manifest: ${manifest_path}"

    # -------------------------------------------------------------------------
    # DRY RUN exits here
    # -------------------------------------------------------------------------
    if [[ "${DRY_RUN}" == true ]]; then
        lib::log_step "[DRY-RUN] Would create: ${archive_path}"
        for p in "${valid_paths[@]}"; do echo "  ${p}"; done
        lib::log_ok "[DRY-RUN] Complete. No files written."
        rm -f "${manifest_path}"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # Create archive
    # NOTE: --one-file-system REMOVED. We explicitly list paths so /etc/pve
    # (a separate FUSE mount when pmxcfs is running) is always included.
    # We use --ignore-failed-read so missing optional paths don't abort.
    # PIPESTATUS is checked to catch any real tar failures.
    # -------------------------------------------------------------------------
    lib::log_step "Creating archive: ${archive_name}"

    local tar_args=(
        --create
        --use-compress-program="zstd -${ZSTD_LEVEL} -T0"
        --file="${archive_path}"
        --absolute-names
        --warning=no-file-changed
        --ignore-failed-read
        --preserve-permissions
        --same-owner
    )

    # Run tar, capture warnings to log, check exit code explicitly
    local tar_warnings_file="${WORK_DIR}/tar-warnings.txt"
    tar "${tar_args[@]}" "${valid_paths[@]}" 2>"${tar_warnings_file}"
    local tar_exit=${PIPESTATUS[0]:-$?}

    # tar exit code 1 = warnings only (files changed during backup) — acceptable
    # tar exit code 2 = fatal error — abort
    if [[ -s "${tar_warnings_file}" ]]; then
        while IFS= read -r line; do lib::log_warn "tar: ${line}"; done < "${tar_warnings_file}"
    fi
    if (( tar_exit >= 2 )); then
        lib::log_error "tar exited with fatal error (code ${tar_exit}). Archive may be incomplete."
        rm -f "${archive_path}"
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "tar exited with fatal error ${tar_exit}. Archive was removed.\nLog: ${LOG_FILE}"
        exit 1
    fi

    # Verify archive was actually created and is non-zero
    if [[ ! -f "${archive_path}" ]] || [[ ! -s "${archive_path}" ]]; then
        lib::log_error "Archive not created or is empty: ${archive_path}"
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "Archive creation failed — file missing or empty.\nLog: ${LOG_FILE}"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Checksum (written atomically via temp file)
    # -------------------------------------------------------------------------
    lib::log_step "Computing ${CHECKSUM_ALGO} checksum..."
    local sum_tmp="${WORK_DIR}/checksum.tmp"
    case "${CHECKSUM_ALGO}" in
        sha256) sha256sum "${archive_path}" > "${sum_tmp}" ;;
        sha512) sha512sum "${archive_path}" > "${sum_tmp}" ;;
        *)      sha256sum "${archive_path}" > "${sum_tmp}" ;;
    esac
    mv "${sum_tmp}" "${archive_path}.${CHECKSUM_ALGO}"
    lib::log_info "Checksum: ${archive_path}.${CHECKSUM_ALGO}"

    # -------------------------------------------------------------------------
    # Verify
    # -------------------------------------------------------------------------
    lib::log_step "Verifying archive integrity..."
    lib::verify_archive "${archive_path}" || {
        lib::log_error "Post-write verification FAILED. Removing corrupt archive."
        rm -f "${archive_path}" "${archive_path}.${CHECKSUM_ALGO}"
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "Archive failed post-write verification and was removed.\nLog: ${LOG_FILE}"
        exit 1
    }

    # -------------------------------------------------------------------------
    # Optional encryption (after verification of plaintext archive)
    # -------------------------------------------------------------------------
    local final_archive="${archive_path}"
    if [[ "${ENCRYPT_ARCHIVE:-false}" == true ]]; then
        lib::log_step "Encrypting archive..."
        final_archive="$(lib::encrypt_archive "${archive_path}")" || {
            lib::log_error "Encryption failed. Plaintext archive left in place for safety."
            lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
                "Archive encryption failed. Plaintext archive at: ${archive_path}\nLog: ${LOG_FILE}"
            exit 1
        }
        # Re-checksum the encrypted file
        local sum_enc_tmp="${WORK_DIR}/checksum-enc.tmp"
        sha256sum "${final_archive}" > "${sum_enc_tmp}"
        mv "${sum_enc_tmp}" "${final_archive}.${CHECKSUM_ALGO}"
        lib::log_info "Encrypted archive checksum: ${final_archive}.${CHECKSUM_ALGO}"
    fi

    # -------------------------------------------------------------------------
    # Prune — only AFTER new backup is confirmed good (fixes ordering bug)
    # -------------------------------------------------------------------------
    lib::log_step "Pruning old backups (retain: ${RETENTION_COUNT})..."
    lib::prune_old_backups

    # -------------------------------------------------------------------------
    # Report
    # -------------------------------------------------------------------------
    local end_ts
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))
    local archive_size
    archive_size="$(lib::human_size "$(stat -c%s "${final_archive}")")"

    lib::log_ok "===== Backup Complete ====="
    lib::log_ok "Archive:  ${final_archive}"
    lib::log_ok "Size:     ${archive_size}"
    lib::log_ok "Duration: ${elapsed}s"
    lib::log_ok "Encrypted: ${ENCRYPT_ARCHIVE:-false}"

    local notify_body
    notify_body="Proxmox Host Backup — SUCCESS

Host:        ${HOSTNAME_SHORT}
PVE Version: ${PVE_VERSION}
Timestamp:   $(date)
Archive:     ${final_archive}
Size:        ${archive_size}
Encrypted:   ${ENCRYPT_ARCHIVE:-false}
Duration:    ${elapsed}s
Log:         ${LOG_FILE}

Storage:   ${BACKUP_DEST_DIR}
Retention: ${RETENTION_COUNT} backups"
    lib::send_notification "success" "SUCCESS on ${HOSTNAME_SHORT}" "${notify_body}"
}

main "$@"
