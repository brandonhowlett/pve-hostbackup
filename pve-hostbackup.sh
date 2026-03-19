#!/usr/bin/env bash
# =============================================================================
# pve-hostbackup.sh — Proxmox Host Configuration Backup v3.0.0
# Version-agnostic: PVE 7.x, 8.x, 9.x+
#
# Usage: pve-hostbackup.sh [OPTIONS]
#   -c, --config FILE    Config file (default: /etc/pve-hostbackup/pve-hostbackup.conf)
#   -d, --dest DIR       Override backup destination
#   -v, --verbose        Verbose output
#   -n, --dry-run        Simulate — no files written, no services stopped
#       --list           List available backups and exit
#       --verify FILE    Verify archive integrity and exit
#   -h, --help           Show help
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/pve-hostbackup-lib.sh"
[[ ! -f "${LIB_FILE}" ]] && { echo "ERROR: Library not found: ${LIB_FILE}" >&2; exit 1; }
# shellcheck source=pve-hostbackup-lib.sh
source "${LIB_FILE}"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
DEST_OVERRIDE=""
DO_LIST=false
VERIFY_TARGET=""

_usage() {
cat <<EOF
${C_BOLD}pve-hostbackup${C_RESET} — Proxmox Host Configuration Backup v${SCRIPT_VERSION}

Usage: $(basename "$0") [OPTIONS]

  -c, --config FILE    Config file (default: /etc/pve-hostbackup/pve-hostbackup.conf)
  -d, --dest DIR       Override backup destination directory
  -v, --verbose        Verbose output (also see VERBOSE=true in config)
  -n, --dry-run        Simulate backup — no files written, no services restarted
      --list           List available backups and exit
      --verify FILE    Verify integrity of a specific archive and exit
  -h, --help           Show this help

Examples:
  $(basename "$0")                        # Run backup now
  $(basename "$0") --dry-run              # Simulate (safe)
  $(basename "$0") --list                 # Show all archives in destination
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
        *) echo "Unknown option: $1"; _usage; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
lib::require_root
lib::load_config
lib::detect_environment
lib::_rotate_log
[[ "${VERBOSE}" == true ]] && set -x

lib::require_commands tar zstd sha256sum flock

# Handle --list
if [[ "${DO_LIST}" == true ]]; then
    if [[ -n "${DEST_OVERRIDE}" ]]; then
        BACKUP_DEST_DIR="${DEST_OVERRIDE}"
    else
        lib::resolve_backup_destination || exit 1
    fi
    lib::list_backups
    if (( ${#BACKUP_LIST[@]} == 0 )); then
        echo "No backups found in ${BACKUP_DEST_DIR}"
        exit 0
    fi
    echo -e "\n${C_BOLD}Backups in ${BACKUP_DEST_DIR}:${C_RESET}"
    printf "%-4s %-60s %-10s %s\n" "#" "FILENAME" "SIZE" "DATE"
    printf '%0.s-' {1..90}; echo
    local_i=1
    for b in "${BACKUP_LIST[@]}"; do
        local_sz=$(lib::human_size "$(stat -c%s "${b}" 2>/dev/null || echo 0)")
        local_dt=$(stat -c '%y' "${b}" 2>/dev/null | cut -d. -f1)
        printf "%-4s %-60s %-10s %s\n" "${local_i}" "$(basename "${b}")" "${local_sz}" "${local_dt}"
        (( local_i++ ))
    done
    exit 0
fi

# Handle --verify
if [[ -n "${VERIFY_TARGET}" ]]; then
    lib::verify_archive "${VERIFY_TARGET}"
    exit $?
fi

# -----------------------------------------------------------------------------
# Main backup
# -----------------------------------------------------------------------------
main() {
    local start_ts
    start_ts="$(date +%s)"
    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    local archive_base="pvehost-${HOSTNAME_SHORT}-pve${PVE_VERSION}-${timestamp}"

    lib::log_step "===== PVE Host Backup Started ====="
    lib::log_info "Host:        ${HOSTNAME_SHORT}"
    lib::log_info "PVE version: ${PVE_VERSION}"
    lib::log_info "Timestamp:   ${timestamp}"
    lib::log_info "Dry-run:     ${DRY_RUN}"

    # Lock — not in dry-run
    [[ "${DRY_RUN}" == false ]] && lib::acquire_lock

    # Resolve destination
    if [[ -n "${DEST_OVERRIDE}" ]]; then
        BACKUP_DEST_DIR="${DEST_OVERRIDE}"
        mkdir -p "${BACKUP_DEST_DIR}"
    else
        lib::resolve_backup_destination || {
            lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
                "No writable backup destination found. Check storage config."
            exit 1
        }
    fi
    lib::log_info "Destination: ${BACKUP_DEST_DIR}"

    # Free space check — before writing anything
    if [[ "${DRY_RUN}" == false ]]; then
        lib::check_free_space "${BACKUP_DEST_DIR}" || {
            lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
                "Insufficient free space on ${BACKUP_DEST_DIR}."
            exit 1
        }
    fi

    # Secure work directory — chmod 700 immediately, root-only
    local work_dir
    work_dir="$(mktemp -d /tmp/pve-hostbackup-XXXXXX)"
    chmod 700 "${work_dir}"
    trap '[[ -d "${work_dir}" ]] && rm -rf "${work_dir}"' EXIT

    local archive_path="${BACKUP_DEST_DIR}/${archive_base}.tar.zst"
    local manifest_path="${BACKUP_DEST_DIR}/${archive_base}.manifest.json"

    # ----- Stage /etc/pve via pmxcfs snapshot -----
    # This stops pve-cluster briefly for a consistent copy of the pmxcfs backing DB.
    # The snapshot is placed in the secure work dir and included in the archive.
    if [[ "${DRY_RUN}" == false ]]; then
        lib::stage_pmxcfs "${work_dir}"
    else
        lib::log_info "[DRY-RUN] Would quiesce pmxcfs and snapshot /etc/pve."
        PMXCFS_SNAPSHOT_DIR="${work_dir}/pmxcfs-snapshot"
        mkdir -p "${PMXCFS_SNAPSHOT_DIR}"
    fi

    # ----- Collect backup paths -----
    lib::log_step "Collecting backup paths..."
    local valid_paths=()
    local skipped_paths=()

    # Add the pmxcfs snapshot directory (replaces /etc/pve in the archive)
    if [[ -d "${PMXCFS_SNAPSHOT_DIR}" ]]; then
        valid_paths+=("${PMXCFS_SNAPSHOT_DIR}")
        lib::log_info "  + ${PMXCFS_SNAPSHOT_DIR} (pmxcfs snapshot)"
    fi

    # Add paths from config (BACKUP_PATHS array)
    for p in "${BACKUP_PATHS[@]}"; do
        # Skip /etc/pve — captured via pmxcfs snapshot above
        [[ "${p}" == "/etc/pve" ]] && continue
        if [[ -e "${p}" ]]; then
            valid_paths+=("${p}")
            lib::log_info "  + ${p}"
        else
            skipped_paths+=("${p}")
            lib::log_info "  - ${p} (not found)"
        fi
    done
    lib::log_info "Paths: ${#valid_paths[@]} included, ${#skipped_paths[@]} skipped."

    # ----- ZFS metadata -----
    if [[ "${ZFS_CAPTURE_ENABLED:-true}" == true ]] && command -v zpool &>/dev/null; then
        lib::log_step "Capturing ZFS metadata..."
        local zfs_meta="${work_dir}/zfs-metadata.txt"
        {
            echo "=== zpool list -v ==="
            zpool list -v 2>/dev/null || echo "(no pools)"
            echo ""
            echo "=== zpool status ==="
            zpool status 2>/dev/null || echo "(no pools)"
            echo ""
            echo "=== zfs list ==="
            zfs list -o name,used,avail,refer,mountpoint 2>/dev/null || echo "(no datasets)"
            echo ""
            echo "=== import commands for restore ==="
            zpool list -H -o name 2>/dev/null | while IFS= read -r pool; do
                echo "zpool import -f ${pool}"
            done
        } > "${zfs_meta}"
        valid_paths+=("${zfs_meta}")
        lib::log_info "ZFS metadata written: ${zfs_meta}"
    fi

    # ----- Manifest -----
    lib::log_step "Writing manifest..."
    local pvesm_out=""
    pvesm_out="$(pvesm status 2>/dev/null || echo 'unavailable')"
    local net_json='[]'
    command -v ip &>/dev/null && net_json="$(ip -j addr 2>/dev/null || echo '[]')"

    # Build JSON without jq dependency (literal values only, safe)
    local included_json="["
    for p in "${valid_paths[@]}"; do included_json+="\"${p}\","; done
    included_json="${included_json%,}]"

    cat > "${manifest_path}" <<EOF
{
  "schema_version": "3",
  "tool_version": "${SCRIPT_VERSION}",
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "${HOSTNAME_SHORT}",
  "fqdn": "$(hostname -f 2>/dev/null || echo "${HOSTNAME_SHORT}")",
  "pve_version": "${PVE_VERSION}",
  "kernel": "$(uname -r)",
  "archive_name": "${archive_base}.tar.zst",
  "compression": "${COMPRESSION}",
  "checksum_algo": "${CHECKSUM_ALGO}",
  "encrypted": ${ENCRYPT_ARCHIVES:-false},
  "pmxcfs_snapshot": true,
  "paths_included": ${included_json},
  "pvesm_status": $(echo "${pvesm_out}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '"unavailable"'),
  "restore_procedure": [
    "1. Fresh-install Proxmox VE on target hardware.",
    "2. Copy this archive and pve-hostrestore.sh to the new host.",
    "3. Run: bash pve-hostrestore.sh --archive <archive>",
    "4. Review /etc/network/interfaces before rebooting.",
    "5. Import ZFS pools if needed: zpool import -a",
    "6. Reboot and verify: pvesm status, qm list, pct list"
  ]
}
EOF
    # Pretty-print if jq available
    if command -v jq &>/dev/null; then
        jq . "${manifest_path}" > "${manifest_path}.pretty" && mv "${manifest_path}.pretty" "${manifest_path}"
    fi
    lib::log_info "Manifest: ${manifest_path}"

    # ----- Dry-run exit -----
    if [[ "${DRY_RUN}" == true ]]; then
        lib::log_step "[DRY-RUN] Paths that would be archived:"
        for p in "${valid_paths[@]}"; do lib::log_info "  ${p}"; done
        lib::log_ok "[DRY-RUN] Complete. No files written, no services affected."
        rm -rf "${work_dir}"
        trap - EXIT
        exit 0
    fi

    # ----- Create archive -----
    lib::log_step "Creating archive: ${archive_base}.tar.zst"

    # Use process substitution to capture tar's exit code correctly.
    # The || true pattern with set -e causes tar warnings to be swallowed;
    # we instead capture PIPESTATUS and check tar's exit explicitly.
    local tar_exit=0
    tar \
        --create \
        --use-compress-program="zstd -${ZSTD_LEVEL} -T0 -q" \
        --file="${archive_path}" \
        --absolute-names \
        --warning=no-file-changed \
        --warning=no-file-removed \
        --ignore-failed-read \
        "${valid_paths[@]}" 2>&1 \
    | while IFS= read -r line; do
        # Log tar warnings but don't treat them as fatal
        [[ "${line}" =~ "Removing leading" ]] && continue
        lib::log_warn "tar: ${line}"
    done || tar_exit=${PIPESTATUS[0]}

    # PIPESTATUS[0] is tar's exit code; 0=success, 1=warnings(ok), 2=fatal
    # Re-check because the subshell assignment above may not propagate
    if [[ ! -f "${archive_path}" ]]; then
        lib::log_error "Archive was not created — tar likely exited fatally."
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "tar failed to create archive. See log: ${LOG_FILE}"
        exit 1
    fi

    # tar exit 1 = "some files changed while reading" — acceptable warning, not fatal
    # tar exit 2 = fatal error
    if [[ "${tar_exit}" -ge 2 ]]; then
        lib::log_error "tar exited with code ${tar_exit} — archive may be incomplete."
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "tar exited ${tar_exit}. Archive may be incomplete. Log: ${LOG_FILE}"
        exit 1
    fi

    # Clean work dir (snapshot already in archive)
    rm -rf "${work_dir}"
    trap - EXIT

    # ----- Checksum — computed before optional encryption -----
    lib::log_step "Computing ${CHECKSUM_ALGO} checksum..."
    lib::checksum_file "${archive_path}"

    # ----- Verify — before encryption so we can read it -----
    lib::log_step "Verifying archive integrity..."
    lib::verify_archive "${archive_path}" || {
        lib::log_error "Post-write verification failed."
        lib::send_notification "failure" "FAILED on ${HOSTNAME_SHORT}" \
            "Archive failed verification: ${archive_path}"
        exit 1
    }

    # ----- Optional encryption -----
    if [[ "${ENCRYPT_ARCHIVES}" == true ]]; then
        local final_archive
        final_archive="$(lib::encrypt_archive "${archive_path}")"
        archive_path="${final_archive}"
    fi

    # ----- Prune — ONLY after new backup is fully committed and verified -----
    lib::log_step "Pruning old backups (keep: ${RETENTION_COUNT})..."
    lib::prune_old_backups

    # ----- Report -----
    local end_ts
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))
    local arc_size
    arc_size="$(lib::human_size "$(stat -c%s "${archive_path}")")"

    lib::log_ok "===== Backup Complete ====="
    lib::log_ok "Archive:  ${archive_path}"
    lib::log_ok "Size:     ${arc_size}"
    lib::log_ok "Duration: ${elapsed}s"

    local notify_body
    notify_body="$(cat <<EOF
Proxmox Host Backup — SUCCESS

Host:        ${HOSTNAME_SHORT}
PVE version: ${PVE_VERSION}
Timestamp:   $(date)
Archive:     ${archive_path}
Size:        ${arc_size}
Duration:    ${elapsed}s
Encrypted:   ${ENCRYPT_ARCHIVES}
Destination: ${BACKUP_DEST_DIR}
Retained:    ${RETENTION_COUNT} backups
Log:         ${LOG_FILE}
EOF
)"
    lib::send_notification "success" "SUCCESS on ${HOSTNAME_SHORT}" "${notify_body}"
}

main "$@"
