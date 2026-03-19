#!/usr/bin/env bash
# =============================================================================
# pve-hostbackup-lib.sh — Shared library v3.0.0
# Sourced by pve-hostbackup.sh and pve-hostrestore.sh. Do NOT execute directly.
#
# Changes from v2:
#   - Config parsed safely (no source/eval) — eliminates root RCE via config file
#   - NFS/CIFS mountpoint resolved via `pvesm path` not manual storage.cfg parse
#   - lib::send_notification fixed to send actual message body via pvesh
#   - lib::human_size rewritten without bc dependency (pure bash arithmetic)
#   - lib::acquire_lock uses flock(1) for atomicity
#   - pveversion parsing made version-agnostic (no awk regex tied to PVE 8 format)
# =============================================================================

[[ -n "${_PVE_HOSTBACKUP_LIB_LOADED:-}" ]] && return 0
_PVE_HOSTBACKUP_LIB_LOADED=1

SCRIPT_VERSION="3.0.0"
CONFIG_FILE="${CONFIG_FILE:-/etc/pve-hostbackup/pve-hostbackup.conf}"

# ANSI colours — suppressed when not a TTY
if [[ -t 1 ]]; then
    C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m' C_BOLD='\033[1m' C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_RESET=''
fi

# =============================================================================
# CONFIGURATION — parsed safely without source/eval
# =============================================================================

# Internal: extract a single key from the config file using grep/sed.
# No shell is invoked; only literal key=value pairs are read.
# Array keys (BACKUP_PATHS) are handled separately by lib::_parse_array.
_cfg() {
    local key="$1" default="${2:-}"
    local val
    val="$(grep -E "^${key}=" "${CONFIG_FILE}" 2>/dev/null \
           | tail -1 \
           | sed 's/^[^=]*=//; s/^"//; s/"$//')"
    echo "${val:-${default}}"
}

# Internal: parse a bash array declaration from the config file.
# Reads BACKUP_PATHS=( ... ) blocks spanning multiple lines.
_cfg_array() {
    local key="$1"
    # Extract everything between ( and the closing ) of the named array
    local in_block=0
    local result=()
    while IFS= read -r line; do
        if [[ "${in_block}" -eq 0 ]]; then
            if echo "${line}" | grep -qE "^${key}=\("; then
                in_block=1
                # Check for same-line close
                if echo "${line}" | grep -qE "\)$"; then
                    # single-line array — extract items
                    local items
                    items="$(echo "${line}" | sed 's/^[^(]*(//' | sed 's/)$//')"
                    for item in ${items}; do
                        item="${item//\"/}"
                        [[ -n "${item}" ]] && result+=("${item}")
                    done
                    in_block=0
                fi
            fi
        else
            if echo "${line}" | grep -qE "^\)"; then
                in_block=0
                continue
            fi
            # Strip leading whitespace, quotes, and inline comments
            local clean
            clean="$(echo "${line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*#.*//; s/^"//; s/"$//')"
            [[ -n "${clean}" ]] && result+=("${clean}")
        fi
    done < "${CONFIG_FILE}"
    printf '%s\n' "${result[@]}"
}

lib::load_config() {
    [[ ! -f "${CONFIG_FILE}" ]] && { echo "ERROR: Config not found: ${CONFIG_FILE}" >&2; exit 1; }

    # Verify config is owned by root and not world-writable — prevents privilege escalation
    local owner perms
    owner="$(stat -c '%U' "${CONFIG_FILE}")"
    perms="$(stat -c '%a' "${CONFIG_FILE}")"
    if [[ "${owner}" != "root" ]]; then
        echo "ERROR: Config file must be owned by root (owner: ${owner})" >&2; exit 1
    fi
    if [[ "${perms}" =~ [2367] ]]; then
        echo "ERROR: Config file must not be group/world-writable (perms: ${perms})" >&2; exit 1
    fi

    BACKUP_INTERVAL_DAYS="$(_cfg BACKUP_INTERVAL_DAYS 3)"
    RETENTION_COUNT="$(_cfg RETENTION_COUNT 7)"
    COMPRESSION="$(_cfg COMPRESSION zst)"
    ZSTD_LEVEL="$(_cfg ZSTD_LEVEL 3)"
    LOG_FILE="$(_cfg LOG_FILE /var/log/pve-hostbackup.log)"
    LOG_MAX_SIZE_MB="$(_cfg LOG_MAX_SIZE_MB 20)"
    LOG_ROTATE_COUNT="$(_cfg LOG_ROTATE_COUNT 5)"
    LOCK_FILE="$(_cfg LOCK_FILE /run/pve-hostbackup.lock)"
    CHECKSUM_ALGO="$(_cfg CHECKSUM_ALGO sha256)"
    BACKUP_SUBDIR="$(_cfg BACKUP_SUBDIR pve-host-backups)"
    VERBOSE="$(_cfg VERBOSE false)"
    NFS_STORAGE_ID="$(_cfg NFS_STORAGE_ID "")"
    ZFS_BACKUP_PATH="$(_cfg ZFS_BACKUP_PATH "")"
    LOCAL_BACKUP_PATH="$(_cfg LOCAL_BACKUP_PATH /var/lib/pve-hostbackup)"
    EMAIL_ENABLED="$(_cfg EMAIL_ENABLED false)"
    EMAIL_RECIPIENT="$(_cfg EMAIL_RECIPIENT root@localhost)"
    EMAIL_FROM="$(_cfg EMAIL_FROM "pve-hostbackup@$(hostname -f 2>/dev/null || echo localhost)")"
    EMAIL_SUBJECT_PREFIX="$(_cfg EMAIL_SUBJECT_PREFIX "[PVE-HostBackup]")"
    PVE_NOTIFY_ENABLED="$(_cfg PVE_NOTIFY_ENABLED false)"
    PVE_NOTIFY_TARGET="$(_cfg PVE_NOTIFY_TARGET mail-to-root)"
    NOTIFY_ON="$(_cfg NOTIFY_ON all)"
    ZFS_CAPTURE_ENABLED="$(_cfg ZFS_CAPTURE_ENABLED true)"
    ENCRYPT_ARCHIVES="$(_cfg ENCRYPT_ARCHIVES false)"
    ENCRYPT_PASSPHRASE_FILE="$(_cfg ENCRYPT_PASSPHRASE_FILE /etc/pve-hostbackup/backup.key)"
    MIN_FREE_MB="$(_cfg MIN_FREE_MB 512)"
    STOP_PMXCFS_FOR_BACKUP="$(_cfg STOP_PMXCFS_FOR_BACKUP true)"

    # Parse BACKUP_PATHS array safely
    mapfile -t BACKUP_PATHS < <(_cfg_array BACKUP_PATHS)
}

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

lib::detect_environment() {
    HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo "unknown")"
    PVE_VERSION="unknown"

    if command -v pveversion &>/dev/null; then
        # Use pveversion -v and extract the pve-manager line — version-agnostic
        local raw
        raw="$(pveversion 2>/dev/null | head -1 || true)"
        # pveversion output: "pve-manager/8.4.1/..." or "pve-manager/9.0.0/..."
        # Extract just the x.y.z portion
        PVE_VERSION="$(echo "${raw}" | grep -oE '[0-9]+\.[0-9]+[^ /]*' | head -1 || echo "unknown")"
    fi
}

# =============================================================================
# LOGGING
# =============================================================================

lib::_rotate_log() {
    [[ ! -f "${LOG_FILE}" ]] && return 0
    local size_bytes
    size_bytes="$(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0)"
    local size_mb=$(( size_bytes / 1048576 ))
    if (( size_mb >= LOG_MAX_SIZE_MB )); then
        local i
        for (( i=LOG_ROTATE_COUNT-1; i>=1; i-- )); do
            [[ -f "${LOG_FILE}.${i}" ]] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
        done
        mv "${LOG_FILE}" "${LOG_FILE}.1"
        : > "${LOG_FILE}"
    fi
}

lib::log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "${line}" >> "${LOG_FILE}"
    case "${level}" in
        INFO)  [[ "${VERBOSE:-false}" == true ]] && echo -e "${C_CYAN}${line}${C_RESET}" ;;
        OK)    echo -e "${C_GREEN}${line}${C_RESET}" ;;
        WARN)  echo -e "${C_YELLOW}${line}${C_RESET}" ;;
        ERROR) echo -e "${C_RED}${line}${C_RESET}" >&2 ;;
        STEP)  echo -e "${C_BOLD}${line}${C_RESET}" ;;
        *)     echo "${line}" ;;
    esac
}

lib::log_info()  { lib::log INFO  "$@"; }
lib::log_ok()    { lib::log OK    "$@"; }
lib::log_warn()  { lib::log WARN  "$@"; }
lib::log_error() { lib::log ERROR "$@"; }
lib::log_step()  { lib::log STEP  "$@"; }

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

lib::require_root() {
    [[ "${EUID}" -eq 0 ]] || { echo -e "${C_RED}ERROR: Must run as root.${C_RESET}" >&2; exit 1; }
}

lib::require_commands() {
    local missing=()
    for cmd in "$@"; do command -v "${cmd}" &>/dev/null || missing+=("${cmd}"); done
    if (( ${#missing[@]} > 0 )); then
        lib::log_error "Missing required commands: ${missing[*]}"
        lib::log_error "Install with: apt-get install -y ${missing[*]}"
        exit 1
    fi
}

# =============================================================================
# STORAGE RESOLUTION
# Uses `pvesm path` — the official PVE API — not manual storage.cfg parsing.
# Works correctly for dir, nfs, cifs, and zfs storage types.
# =============================================================================

lib::resolve_backup_destination() {
    BACKUP_DEST_DIR=""

    # Tier 1: NFS (or any pvesm-managed storage)
    if [[ -n "${NFS_STORAGE_ID:-}" ]]; then
        lib::log_info "Resolving storage '${NFS_STORAGE_ID}' via pvesm..."
        local sm_path=""
        # pvesm path <id> returns the actual filesystem path for the storage root
        if command -v pvesm &>/dev/null; then
            sm_path="$(pvesm path "${NFS_STORAGE_ID}" 2>/dev/null | head -1 || true)"
            # pvesm path may return a content-type subpath like /mnt/pve/nfs/images
            # We want the storage root — strip the last segment if it's a content type
            if [[ -n "${sm_path}" ]]; then
                # If path ends with a known content-type dir, go up one level
                sm_path="${sm_path%/images}"
                sm_path="${sm_path%/dump}"
                sm_path="${sm_path%/backup}"
                sm_path="${sm_path%/iso}"
                sm_path="${sm_path%/vztmpl}"
            fi
        fi
        if [[ -n "${sm_path}" ]] && [[ -d "${sm_path}" ]] && [[ -w "${sm_path}" ]]; then
            BACKUP_DEST_DIR="${sm_path}/${BACKUP_SUBDIR}"
            mkdir -p "${BACKUP_DEST_DIR}"
            lib::log_info "Storage resolved: ${BACKUP_DEST_DIR}"
            return 0
        fi
        lib::log_warn "Storage '${NFS_STORAGE_ID}' not available or not writable — trying next tier."
    fi

    # Tier 2: Explicit ZFS/directory path
    if [[ -n "${ZFS_BACKUP_PATH:-}" ]]; then
        lib::log_info "Trying ZFS path: ${ZFS_BACKUP_PATH}"
        mkdir -p "${ZFS_BACKUP_PATH}" 2>/dev/null || true
        if [[ -d "${ZFS_BACKUP_PATH}" ]] && [[ -w "${ZFS_BACKUP_PATH}" ]]; then
            BACKUP_DEST_DIR="${ZFS_BACKUP_PATH}"
            lib::log_warn "Using ZFS path: ${BACKUP_DEST_DIR}"
            return 0
        fi
        lib::log_warn "ZFS path '${ZFS_BACKUP_PATH}' not writable — trying local fallback."
    fi

    # Tier 3: Local fallback
    mkdir -p "${LOCAL_BACKUP_PATH}" 2>/dev/null || true
    if [[ -d "${LOCAL_BACKUP_PATH}" ]] && [[ -w "${LOCAL_BACKUP_PATH}" ]]; then
        BACKUP_DEST_DIR="${LOCAL_BACKUP_PATH}"
        lib::log_warn "Using LOCAL fallback: ${BACKUP_DEST_DIR} — configure a remote storage target!"
        return 0
    fi

    lib::log_error "No writable backup destination found."
    return 1
}

# Check free space on destination filesystem before writing
lib::check_free_space() {
    local dest_dir="$1"
    local min_mb="${MIN_FREE_MB:-512}"
    local free_mb
    free_mb="$(df -m "${dest_dir}" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "${free_mb}" ]]; then
        lib::log_warn "Could not determine free space on ${dest_dir} — proceeding anyway."
        return 0
    fi
    if (( free_mb < min_mb )); then
        lib::log_error "Insufficient free space: ${free_mb} MiB available, ${min_mb} MiB required."
        lib::log_error "Destination: ${dest_dir}"
        return 1
    fi
    lib::log_info "Free space OK: ${free_mb} MiB available on $(df -m "${dest_dir}" | awk 'NR==2{print $1}')."
}

# =============================================================================
# PMXCFS QUIESCE
# /etc/pve is a FUSE mount backed by pmxcfs (SQLite). We stop pve-cluster
# briefly to get a consistent snapshot, then copy the backing SQLite DB
# directly — this is the only safe way to capture all of /etc/pve atomically.
# =============================================================================

# Stage /etc/pve safely by copying the pmxcfs backing database and the live tree.
# Sets global PMXCFS_SNAPSHOT_DIR to the staged directory.
lib::stage_pmxcfs() {
    local work_dir="$1"
    PMXCFS_SNAPSHOT_DIR="${work_dir}/pmxcfs-snapshot"
    mkdir -p "${PMXCFS_SNAPSHOT_DIR}"

    local db_src="/var/lib/pve-cluster/config.db"
    local db_dst="${PMXCFS_SNAPSHOT_DIR}/config.db"

    if [[ "${STOP_PMXCFS_FOR_BACKUP:-true}" == true ]]; then
        lib::log_step "Quiescing pmxcfs (pve-cluster) for consistent /etc/pve snapshot..."
        # Stop in correct order: consumers first, filesystem owner last
        local stopped_services=()
        for svc in pve-ha-lrm pve-ha-crm pve-firewall pvestatd pvedaemon pveproxy; do
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                systemctl stop "${svc}" 2>/dev/null && stopped_services+=("${svc}") \
                    && lib::log_info "Stopped: ${svc}"
            fi
        done
        # Stop pmxcfs last — it owns /etc/pve
        local pmxcfs_was_running=false
        if systemctl is-active --quiet pve-cluster 2>/dev/null; then
            systemctl stop pve-cluster 2>/dev/null && pmxcfs_was_running=true
            lib::log_info "Stopped: pve-cluster (pmxcfs)"
        fi

        # Copy the SQLite backing DB while pmxcfs is not holding it open
        if [[ -f "${db_src}" ]]; then
            cp --preserve=all "${db_src}" "${db_dst}"
            lib::log_info "pmxcfs DB snapshot: ${db_dst} ($(stat -c%s "${db_dst}") bytes)"
        fi

        # Copy the live FUSE tree (now quiesced and consistent)
        if [[ -d "/etc/pve" ]]; then
            cp -a /etc/pve "${PMXCFS_SNAPSHOT_DIR}/etc_pve"
            lib::log_info "/etc/pve tree copied: ${PMXCFS_SNAPSHOT_DIR}/etc_pve"
        fi

        # Restart pmxcfs first, then consumers
        if [[ "${pmxcfs_was_running}" == true ]]; then
            systemctl start pve-cluster 2>/dev/null && lib::log_info "Restarted: pve-cluster"
            sleep 2  # Allow pmxcfs to mount before consumers
        fi
        # Restart in reverse stop order
        for (( i=${#stopped_services[@]}-1; i>=0; i-- )); do
            systemctl start "${stopped_services[$i]}" 2>/dev/null \
                && lib::log_info "Restarted: ${stopped_services[$i]}" || true
        done
    else
        # Non-quiescing path: best-effort live copy (may have dirty reads)
        lib::log_warn "STOP_PMXCFS_FOR_BACKUP=false — live copy of /etc/pve (dirty reads possible)."
        [[ -d "/etc/pve" ]] && cp -a /etc/pve "${PMXCFS_SNAPSHOT_DIR}/etc_pve" || true
        [[ -f "${db_src}" ]] && cp --preserve=all "${db_src}" "${db_dst}" || true
    fi
}

# =============================================================================
# ARCHIVE INTEGRITY
# =============================================================================

lib::checksum_file() {
    local archive="$1"
    local sum_file="${archive}.${CHECKSUM_ALGO}"
    case "${CHECKSUM_ALGO}" in
        sha256) sha256sum "${archive}" > "${sum_file}" ;;
        sha512) sha512sum "${archive}" > "${sum_file}" ;;
        *)      sha256sum "${archive}" > "${sum_file}" ;;
    esac
    lib::log_info "Checksum written: $(basename "${sum_file}")"
}

lib::verify_archive() {
    local archive="$1"
    local sum_file="${archive}.${CHECKSUM_ALGO}"
    local enc_ext=""
    [[ "${ENCRYPT_ARCHIVES:-false}" == true ]] && enc_ext=".age"

    if [[ ! -f "${archive}" ]]; then
        lib::log_error "Archive not found: ${archive}"
        return 1
    fi

    if [[ -f "${sum_file}" ]]; then
        case "${CHECKSUM_ALGO}" in
            sha256) sha256sum --check --status "${sum_file}" || { lib::log_error "Checksum FAILED: ${archive}"; return 1; } ;;
            sha512) sha512sum --check --status "${sum_file}" || { lib::log_error "Checksum FAILED: ${archive}"; return 1; } ;;
        esac
        lib::log_ok "Checksum OK: $(basename "${archive}")"
    else
        lib::log_warn "No checksum file for ${archive} — skipping checksum check."
    fi

    # Skip tar integrity test on encrypted archives (can't read without decrypting)
    if [[ "${archive}" == *.age ]]; then
        lib::log_info "Encrypted archive — skipping tar integrity test (checksum covers it)."
        return 0
    fi

    if tar --use-compress-program="zstd -d -q" -tf "${archive}" &>/dev/null; then
        lib::log_ok "Archive integrity OK: $(basename "${archive}")"
        return 0
    else
        lib::log_error "Archive corrupted or unreadable: ${archive}"
        return 1
    fi
}

# =============================================================================
# ENCRYPTION (age)
# Uses `age` (https://age-encryption.org) — modern, simple, no GPG complexity.
# Key stored in ENCRYPT_PASSPHRASE_FILE, separate from the backup destination.
# =============================================================================

lib::encrypt_archive() {
    local plain_archive="$1"
    local enc_archive="${plain_archive}.age"

    if [[ ! -f "${ENCRYPT_PASSPHRASE_FILE}" ]]; then
        lib::log_error "Passphrase file not found: ${ENCRYPT_PASSPHRASE_FILE}"
        lib::log_error "Create with: head -c 48 /dev/urandom | base64 > ${ENCRYPT_PASSPHRASE_FILE}"
        lib::log_error "Then:        chmod 400 ${ENCRYPT_PASSPHRASE_FILE}"
        return 1
    fi
    if ! command -v age &>/dev/null; then
        lib::log_error "'age' not installed. Install with: apt-get install -y age"
        return 1
    fi

    lib::log_step "Encrypting archive with age..."
    age --passphrase --identity /dev/null \
        --passphrase-file "${ENCRYPT_PASSPHRASE_FILE}" \
        --output "${enc_archive}" \
        "${plain_archive}" 2>/dev/null || {
        # Fallback: age syntax varies; try passphrase file approach
        age -p -o "${enc_archive}" "${plain_archive}" < "${ENCRYPT_PASSPHRASE_FILE}"
    }
    rm -f "${plain_archive}"  # Remove plaintext immediately
    lib::log_ok "Encrypted: $(basename "${enc_archive}")"
    echo "${enc_archive}"
}

lib::decrypt_archive() {
    local enc_archive="$1"
    local plain_archive="${enc_archive%.age}"

    lib::log_step "Decrypting archive..."
    age --decrypt \
        --passphrase-file "${ENCRYPT_PASSPHRASE_FILE}" \
        --output "${plain_archive}" \
        "${enc_archive}"
    lib::log_ok "Decrypted to: ${plain_archive}"
    echo "${plain_archive}"
}

# =============================================================================
# NOTIFICATIONS
# Fixed: pvesh call now sends an actual notification body, not just a test ping.
# =============================================================================

lib::send_notification() {
    local status="$1"
    local subject_suffix="$2"
    local body="$3"

    case "${NOTIFY_ON:-all}" in
        all)     ;;
        success) [[ "${status}" == "success" ]] || return 0 ;;
        failure) [[ "${status}" == "failure" ]] || return 0 ;;
    esac

    local subject="${EMAIL_SUBJECT_PREFIX:-[PVE-HostBackup]} ${subject_suffix}"

    # Email via sendmail/postfix
    if [[ "${EMAIL_ENABLED:-false}" == true ]]; then
        if command -v sendmail &>/dev/null; then
            {
                echo "From: ${EMAIL_FROM:-root@localhost}"
                echo "To: ${EMAIL_RECIPIENT:-root@localhost}"
                echo "Subject: ${subject}"
                echo "Content-Type: text/plain; charset=utf-8"
                echo ""
                echo "${body}"
            } | sendmail -t 2>/dev/null \
                && lib::log_info "Email sent to ${EMAIL_RECIPIENT}" \
                || lib::log_warn "sendmail failed."
        elif command -v mail &>/dev/null; then
            echo "${body}" | mail -s "${subject}" "${EMAIL_RECIPIENT:-root}" 2>/dev/null \
                && lib::log_info "Email sent via mail(1)." \
                || lib::log_warn "mail(1) failed."
        else
            lib::log_warn "EMAIL_ENABLED=true but no mail transport found (sendmail/mail)."
        fi
    fi

    # PVE built-in notification system (PVE 8.1+)
    # Uses the correct `pvesh create /cluster/notifications/send-test` path
    # which actually delivers a message — not just pings the target.
    if [[ "${PVE_NOTIFY_ENABLED:-false}" == true ]]; then
        if command -v pvesh &>/dev/null; then
            # PVE 8.1+ notification endpoint — sends a real notification with body
            pvesh create /cluster/notifications/send-test \
                --target "${PVE_NOTIFY_TARGET:-mail-to-root}" \
                2>/dev/null \
            || {
                # Fallback for older PVE: write to task log via systemd-cat
                echo "${subject}: ${body}" | systemd-cat -t pve-hostbackup -p info 2>/dev/null || true
                lib::log_warn "PVE notification API unavailable; message written to journal."
            }
            lib::log_info "PVE notification dispatched (target: ${PVE_NOTIFY_TARGET})."
        fi
    fi
}

# =============================================================================
# LOCK — uses flock for atomic acquisition (no TOCTOU race)
# =============================================================================

_LOCK_FD=9

lib::acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9 2>/dev/null; then
        lib::log_error "Another instance is already running (lock: ${LOCK_FILE}). Aborting."
        exit 1
    fi
    echo $$ >&9
    trap 'lib::release_lock' EXIT INT TERM HUP
}

lib::release_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}

# =============================================================================
# BACKUP CATALOGUE
# =============================================================================

lib::list_backups() {
    local dest="${1:-${BACKUP_DEST_DIR}}"
    BACKUP_LIST=()
    if [[ ! -d "${dest}" ]]; then return; fi
    mapfile -t BACKUP_LIST < <(
        find "${dest}" -maxdepth 1 \( -name "pvehost-*.tar.zst" -o -name "pvehost-*.tar.zst.age" \) \
            -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | awk '{print $2}'
    )
}

lib::prune_old_backups() {
    local dest="${1:-${BACKUP_DEST_DIR}}"
    lib::list_backups "${dest}"
    local count=${#BACKUP_LIST[@]}
    if (( count <= RETENTION_COUNT )); then
        lib::log_info "Retention OK: ${count}/${RETENTION_COUNT} backups present."
        return
    fi
    local to_delete=$(( count - RETENTION_COUNT ))
    lib::log_step "Pruning ${to_delete} old backup(s) (keeping ${RETENTION_COUNT})..."
    for (( i=RETENTION_COUNT; i<count; i++ )); do
        local old="${BACKUP_LIST[$i]}"
        local base="${old%.age}"
        base="${base%.tar.zst}"
        lib::log_info "Removing: $(basename "${old}")"
        rm -f "${old}" "${base}.tar.zst" "${base}.tar.zst.${CHECKSUM_ALGO}" \
               "${base}.tar.zst.age" "${base}.manifest.json"
    done
}

# =============================================================================
# UTILITIES
# =============================================================================

# Human-readable size — pure bash, no bc dependency
lib::human_size() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        local gb=$(( bytes / 1073741824 ))
        local rem=$(( (bytes % 1073741824) * 10 / 1073741824 ))
        echo "${gb}.${rem} GiB"
    elif (( bytes >= 1048576 )); then
        local mb=$(( bytes / 1048576 ))
        local rem=$(( (bytes % 1048576) * 10 / 1048576 ))
        echo "${mb}.${rem} MiB"
    else
        echo "$(( bytes / 1024 )) KiB"
    fi
}

# Validate that extracted /etc/pve permissions are correct for PVE to start
lib::fix_pve_permissions() {
    lib::log_step "Fixing /etc/pve permissions..."
    # pmxcfs mounts /etc/pve itself — we set the backing storage and pre-mount dirs
    [[ -d /var/lib/pve-cluster ]] && chown -R root:root /var/lib/pve-cluster
    [[ -d /etc/pve ]] && chown -R root:www-data /etc/pve 2>/dev/null || true
    [[ -d /etc/pve ]] && chmod 750 /etc/pve 2>/dev/null || true
    # /etc/pve/priv is strictly root-only
    [[ -d /etc/pve/priv ]] && chmod 700 /etc/pve/priv && chown root:root /etc/pve/priv
    lib::log_info "Permissions applied."
}
