#!/usr/bin/env bash
# =============================================================================
# pve-hostbackup-lib.sh — Shared library v3.0.0
# Sourced by pve-hostbackup.sh and pve-hostrestore.sh
# Do NOT execute directly.
#
# v3 changes (post code-review):
#   - Config parsed with grep/awk instead of source (eliminates RCE vector)
#   - Storage mountpoint resolved via pvesm path, not manual storage.cfg parse
#   - lib::human_size uses awk instead of bc (removes dependency)
#   - Notification send uses correct pvesh API with message body
#   - Lock file uses flock(1) for atomic acquire (race-free)
#   - WORK_DIR uses mktemp -d with chmod 700 (no /tmp world-readable staging)
# =============================================================================

[[ -n "${_PVE_HOSTBACKUP_LIB_LOADED:-}" ]] && return 0
_PVE_HOSTBACKUP_LIB_LOADED=1

SCRIPT_VERSION="3.0.0"
CONFIG_FILE="${CONFIG_FILE:-/etc/pve-hostbackup/pve-hostbackup.conf}"
PVE_VERSION=""
HOSTNAME_SHORT=""
BACKUP_DEST_DIR=""
BACKUP_LIST=()

# ANSI colours — suppressed when not a TTY
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# =============================================================================
# CONFIG — parsed with grep/awk, never sourced (security fix)
# =============================================================================

# Internal: read a single key from the config file safely.
# Usage: _lib::cfg_get KEY [default]
_lib::cfg_get() {
    local key="$1"
    local default="${2:-}"
    local val

    # Strip comments, find key = value or key="value" or key='value'
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${CONFIG_FILE}" 2>/dev/null \
        | tail -1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
        | sed "s/^['\"]//; s/['\"][[:space:]]*$//" \
        | sed 's/[[:space:]]*#.*$//')"

    echo "${val:-${default}}"
}

# Internal: read an array value (lines between parentheses) from config.
# Usage: _lib::cfg_get_array KEY resultvar
_lib::cfg_get_array() {
    local key="$1"
    local -n _result_ref=$2
    _result_ref=()

    local in_block=0
    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "${in_block}" -eq 0 ]]; then
            if echo "${line}" | grep -qE "^[[:space:]]*${key}[[:space:]]*=\s*\("; then
                in_block=1
                # Handle single-line: KEY=( a b c )
                if echo "${line}" | grep -q ')'; then
                    local items
                    items="$(echo "${line}" | sed -E 's/.*\(//; s/\).*//')"
                    while IFS= read -r item; do
                        item="$(echo "${item}" | sed "s/^['\"]//; s/['\"]$//" | xargs)"
                        [[ -n "${item}" ]] && _result_ref+=("${item}")
                    done < <(echo "${items}" | tr ' ' '\n')
                    in_block=0
                fi
            fi
        else
            if echo "${line}" | grep -q ')'; then
                in_block=0
                continue
            fi
            local item
            item="$(echo "${line}" | sed "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^['\"]//; s/['\"]$//")"
            [[ -n "${item}" ]] && _result_ref+=("${item}")
        fi
    done < "${CONFIG_FILE}"
}

lib::load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
        exit 1
    fi

    # Verify config is owned by root and not group/world-writable (security check).
    # We parse the octal permission bits directly:
    #   stat -c '%a' returns 3 or 4 digits, e.g. "600", "640", "2640"
    #   The last two digits are group and other permissions.
    #   We reject any permission where the group digit >= 2 (group-writable)
    #   or the other digit >= 2 (world-writable).
    #   Acceptable: 600, 400. Not acceptable: 640, 644, 660, 666, etc.
    local cfg_owner cfg_perms cfg_group_bit cfg_other_bit
    cfg_owner="$(stat -c '%U' "${CONFIG_FILE}")"
    cfg_perms="$(stat -c '%a' "${CONFIG_FILE}")"
    if [[ "${cfg_owner}" != "root" ]]; then
        echo "ERROR: Config file must be owned by root (current owner: ${cfg_owner})" >&2
        echo "Fix: chown root:root ${CONFIG_FILE}" >&2
        exit 1
    fi
    # Extract the last two digits (group and other permission octets)
    cfg_group_bit="${cfg_perms: -2:1}"
    cfg_other_bit="${cfg_perms: -1:1}"
    if (( cfg_group_bit >= 2 || cfg_other_bit >= 2 )); then
        echo "ERROR: Config file is group/world-writable (perms: ${cfg_perms})." >&2
        echo "Fix: chmod 600 ${CONFIG_FILE}" >&2
        exit 1
    fi

    # Scalar values
    BACKUP_INTERVAL_DAYS="$(_lib::cfg_get BACKUP_INTERVAL_DAYS 3)"
    RETENTION_COUNT="$(_lib::cfg_get RETENTION_COUNT 7)"
    COMPRESSION="$(_lib::cfg_get COMPRESSION zst)"
    ZSTD_LEVEL="$(_lib::cfg_get ZSTD_LEVEL 3)"
    LOG_FILE="$(_lib::cfg_get LOG_FILE /var/log/pve-hostbackup.log)"
    LOG_MAX_SIZE_MB="$(_lib::cfg_get LOG_MAX_SIZE_MB 20)"
    LOG_ROTATE_COUNT="$(_lib::cfg_get LOG_ROTATE_COUNT 5)"
    LOCK_FILE="$(_lib::cfg_get LOCK_FILE /run/pve-hostbackup.lock)"
    CHECKSUM_ALGO="$(_lib::cfg_get CHECKSUM_ALGO sha256)"
    BACKUP_SUBDIR="$(_lib::cfg_get BACKUP_SUBDIR pve-host-backups)"
    VERBOSE="$(_lib::cfg_get VERBOSE false)"
    EMAIL_ENABLED="$(_lib::cfg_get EMAIL_ENABLED false)"
    EMAIL_RECIPIENT="$(_lib::cfg_get EMAIL_RECIPIENT root@localhost)"
    EMAIL_FROM="$(_lib::cfg_get EMAIL_FROM "pve-hostbackup@$(hostname -f 2>/dev/null || echo localhost)")"
    EMAIL_SUBJECT_PREFIX="$(_lib::cfg_get EMAIL_SUBJECT_PREFIX "[PVE-HostBackup]")"
    PVE_NOTIFY_ENABLED="$(_lib::cfg_get PVE_NOTIFY_ENABLED false)"
    PVE_NOTIFY_TARGET="$(_lib::cfg_get PVE_NOTIFY_TARGET mail-to-root)"
    NOTIFY_ON="$(_lib::cfg_get NOTIFY_ON all)"
    NFS_STORAGE_ID="$(_lib::cfg_get NFS_STORAGE_ID "")"
    ZFS_BACKUP_PATH="$(_lib::cfg_get ZFS_BACKUP_PATH "")"
    LOCAL_BACKUP_PATH="$(_lib::cfg_get LOCAL_BACKUP_PATH /var/lib/pve-hostbackup)"
    ZFS_CAPTURE_ENABLED="$(_lib::cfg_get ZFS_CAPTURE_ENABLED true)"
    ENCRYPT_ARCHIVE="$(_lib::cfg_get ENCRYPT_ARCHIVE false)"
    ENCRYPT_PASSPHRASE_FILE="$(_lib::cfg_get ENCRYPT_PASSPHRASE_FILE "")"
    FREE_SPACE_MIN_MB="$(_lib::cfg_get FREE_SPACE_MIN_MB 512)"

    # Array value
    _lib::cfg_get_array BACKUP_PATHS BACKUP_PATHS
}

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

lib::detect_environment() {
    HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo "unknown")"

    if command -v pveversion &>/dev/null; then
        # PVE 8+ outputs: "pve-manager/8.4.1/..." — field 2 split by /
        PVE_VERSION="$(pveversion 2>/dev/null \
            | head -1 \
            | grep -oE '[0-9]+\.[0-9]+[^ ]*' \
            | head -1)"
        PVE_VERSION="${PVE_VERSION:-unknown}"
    else
        PVE_VERSION="unknown"
    fi
}

# =============================================================================
# LOGGING
# =============================================================================

lib::_rotate_log() {
    [[ ! -f "${LOG_FILE}" ]] && return
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
# SAFETY CHECKS
# =============================================================================

lib::require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${C_RED}ERROR: Must be run as root.${C_RESET}" >&2
        exit 1
    fi
}

lib::require_commands() {
    local missing=()
    for cmd in "$@"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        lib::log_error "Missing required commands: ${missing[*]}"
        lib::log_error "Install with: apt-get install -y ${missing[*]}"
        exit 1
    fi
}

# Check available disk space on the filesystem containing PATH.
# Returns 1 if less than FREE_SPACE_MIN_MB is available.
lib::check_free_space() {
    local path="$1"
    local min_mb="${FREE_SPACE_MIN_MB:-512}"
    local avail_mb
    avail_mb="$(df -m --output=avail "${path}" 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ -z "${avail_mb}" ]] || (( avail_mb < min_mb )); then
        lib::log_error "Insufficient space at ${path}: ${avail_mb}MiB available, ${min_mb}MiB required."
        return 1
    fi
    lib::log_info "Free space at ${path}: ${avail_mb}MiB (min: ${min_mb}MiB) — OK"
    return 0
}

# =============================================================================
# STORAGE RESOLUTION
# Uses pvesm path <id> — the official API — instead of parsing storage.cfg
# =============================================================================

lib::resolve_backup_destination() {
    BACKUP_DEST_DIR=""

    # --- Tier 1: NFS/CIFS/PBS storage via pvesm ---
    if [[ -n "${NFS_STORAGE_ID:-}" ]]; then
        lib::log_info "Trying PVE storage: ${NFS_STORAGE_ID}"
        if command -v pvesm &>/dev/null; then
            # pvesm path returns the usable local filesystem path for any storage type
            local sm_path
            sm_path="$(pvesm path "${NFS_STORAGE_ID}" 2>/dev/null || true)"
            # pvesm path may return a content-type path like /mnt/pve/nfs-backup/dump
            # We want the storage root: strip trailing content-type directory
            local sm_root
            sm_root="$(dirname "${sm_path}")"
            # If pvesm gave us the mount root directly (dir-type), use it
            [[ "${sm_root}" == "." || "${sm_root}" == "/" ]] && sm_root="${sm_path}"
            # Prefer the /mnt/pve/<id> convention used by NFS/CIFS
            local mnt_pve="/mnt/pve/${NFS_STORAGE_ID}"
            if [[ -d "${mnt_pve}" ]]; then
                sm_root="${mnt_pve}"
            fi
            if [[ -n "${sm_root}" ]] && [[ -d "${sm_root}" ]] && [[ -w "${sm_root}" ]]; then
                BACKUP_DEST_DIR="${sm_root}/${BACKUP_SUBDIR}"
                mkdir -p "${BACKUP_DEST_DIR}"
                lib::log_info "Using PVE storage destination: ${BACKUP_DEST_DIR}"
                return 0
            fi
        fi
        lib::log_warn "PVE storage '${NFS_STORAGE_ID}' not reachable or not writable."
    fi

    # --- Tier 2: ZFS dataset mount path ---
    if [[ -n "${ZFS_BACKUP_PATH:-}" ]]; then
        lib::log_info "Trying ZFS path: ${ZFS_BACKUP_PATH}"
        if [[ -d "${ZFS_BACKUP_PATH}" ]] && [[ -w "${ZFS_BACKUP_PATH}" ]]; then
            BACKUP_DEST_DIR="${ZFS_BACKUP_PATH}"
            mkdir -p "${BACKUP_DEST_DIR}"
            lib::log_info "Using ZFS destination: ${BACKUP_DEST_DIR}"
            return 0
        fi
        lib::log_warn "ZFS path '${ZFS_BACKUP_PATH}' not available or not writable."
    fi

    # --- Tier 3: Local directory fallback ---
    if [[ -n "${LOCAL_BACKUP_PATH:-}" ]]; then
        lib::log_info "Trying local fallback: ${LOCAL_BACKUP_PATH}"
        mkdir -p "${LOCAL_BACKUP_PATH}" 2>/dev/null || true
        if [[ -d "${LOCAL_BACKUP_PATH}" ]] && [[ -w "${LOCAL_BACKUP_PATH}" ]]; then
            BACKUP_DEST_DIR="${LOCAL_BACKUP_PATH}"
            lib::log_warn "Falling back to LOCAL destination: ${BACKUP_DEST_DIR}"
            return 0
        fi
    fi

    lib::log_error "No writable backup destination found. Check storage configuration."
    return 1
}

# =============================================================================
# SECURE WORK DIRECTORY
# =============================================================================

# Create a secure temporary work directory (chmod 700, not world-readable)
lib::make_work_dir() {
    local work
    work="$(mktemp -d /tmp/pve-hostbackup-XXXXXX)"
    chmod 700 "${work}"
    echo "${work}"
}

# =============================================================================
# ARCHIVE — CHECKSUM & ENCRYPTION
# =============================================================================

lib::checksum_file() {
    local archive="$1"
    local sum_file="${archive}.${CHECKSUM_ALGO}"
    case "${CHECKSUM_ALGO}" in
        sha256) sha256sum "${archive}" > "${sum_file}" ;;
        sha512) sha512sum "${archive}" > "${sum_file}" ;;
        *)      sha256sum "${archive}" > "${sum_file}" ;;
    esac
    lib::log_info "Checksum written: ${sum_file}"
}

lib::verify_archive() {
    local archive="$1"
    local sum_file="${archive}.${CHECKSUM_ALGO}"

    if [[ ! -f "${archive}" ]]; then
        lib::log_error "Archive not found: ${archive}"
        return 1
    fi

    # Checksum verification
    if [[ -f "${sum_file}" ]]; then
        lib::log_info "Verifying checksum..."
        case "${CHECKSUM_ALGO}" in
            sha256) sha256sum --check "${sum_file}" &>/dev/null || { lib::log_error "Checksum FAILED: ${archive}"; return 1; } ;;
            sha512) sha512sum --check "${sum_file}" &>/dev/null || { lib::log_error "Checksum FAILED: ${archive}"; return 1; } ;;
        esac
        lib::log_ok "Checksum OK: $(basename "${archive}")"
    else
        lib::log_warn "No checksum file found — integrity not verified. Archive may be from an older version."
    fi

    # Archive readability test
    lib::log_info "Testing archive readability..."
    local decompress_cmd="zstd -d"
    [[ "${archive}" == *.gz ]] && decompress_cmd="gzip -d"

    if tar --use-compress-program="${decompress_cmd}" -tf "${archive}" &>/dev/null; then
        lib::log_ok "Archive readable: $(basename "${archive}")"
        return 0
    else
        lib::log_error "Archive is corrupted or unreadable: ${archive}"
        return 1
    fi
}

# Encrypt an archive file using age or openssl (fallback).
# The original archive is replaced with <archive>.age or <archive>.enc.
# Returns the path to the encrypted file.
lib::encrypt_archive() {
    local archive="$1"
    local passphrase_file="${ENCRYPT_PASSPHRASE_FILE:-}"

    if [[ -z "${passphrase_file}" ]] || [[ ! -f "${passphrase_file}" ]]; then
        lib::log_error "ENCRYPT_ARCHIVE=true but ENCRYPT_PASSPHRASE_FILE not set or not found."
        lib::log_error "Create a passphrase file: echo 'YourStrongPassphrase' > /etc/pve-hostbackup/.archive-key && chmod 400 /etc/pve-hostbackup/.archive-key"
        return 1
    fi

    local enc_archive="${archive}.enc"

    if command -v age &>/dev/null; then
        # age encryption (recommended)
        age --passphrase --passphrase-file "${passphrase_file}" \
            --output "${enc_archive}" "${archive}" \
        && rm -f "${archive}" \
        && lib::log_info "Archive encrypted with age: ${enc_archive}" \
        && echo "${enc_archive}" \
        && return 0
    elif command -v openssl &>/dev/null; then
        # openssl fallback (AES-256-CBC)
        openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
            -pass "file:${passphrase_file}" \
            -in "${archive}" -out "${enc_archive}" \
        && rm -f "${archive}" \
        && lib::log_info "Archive encrypted with openssl: ${enc_archive}" \
        && echo "${enc_archive}" \
        && return 0
    else
        lib::log_error "ENCRYPT_ARCHIVE=true but neither 'age' nor 'openssl' found."
        return 1
    fi
}

# Decrypt an archive. Returns path to decrypted file.
lib::decrypt_archive() {
    local archive="$1"
    local passphrase_file="${ENCRYPT_PASSPHRASE_FILE:-}"
    local decrypted="${archive%.enc}.tar.zst"

    [[ ! -f "${passphrase_file:-}" ]] && {
        lib::log_error "Passphrase file not found: ${passphrase_file}"
        return 1
    }

    if [[ "${archive}" == *.enc ]] && command -v age &>/dev/null; then
        age --decrypt --passphrase --passphrase-file "${passphrase_file}" \
            --output "${decrypted}" "${archive}" \
        && lib::log_info "Decrypted with age: ${decrypted}" \
        && echo "${decrypted}" && return 0
    elif [[ "${archive}" == *.enc ]] && command -v openssl &>/dev/null; then
        openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
            -pass "file:${passphrase_file}" \
            -in "${archive}" -out "${decrypted}" \
        && lib::log_info "Decrypted with openssl: ${decrypted}" \
        && echo "${decrypted}" && return 0
    else
        # Not encrypted — return as-is
        echo "${archive}"
    fi
}

# =============================================================================
# NOTIFICATIONS
# Uses correct pvesh send API with message body (not just test-target ping)
# =============================================================================

lib::send_notification() {
    local status="$1"
    local subject_suffix="$2"
    local body="$3"

    case "${NOTIFY_ON:-all}" in
        all)     true ;;
        success) [[ "${status}" == "success" ]] || return 0 ;;
        failure) [[ "${status}" == "failure" ]] || return 0 ;;
    esac

    local subject="${EMAIL_SUBJECT_PREFIX:-[PVE-HostBackup]} ${subject_suffix}"

    # --- Email via sendmail/mail ---
    if [[ "${EMAIL_ENABLED:-false}" == true ]]; then
        if command -v sendmail &>/dev/null; then
            {
                echo "From: ${EMAIL_FROM:-root@localhost}"
                echo "To: ${EMAIL_RECIPIENT:-root@localhost}"
                echo "Subject: ${subject}"
                echo "Content-Type: text/plain; charset=utf-8"
                echo "MIME-Version: 1.0"
                echo ""
                printf '%s\n' "${body}"
            } | sendmail -t 2>/dev/null \
            || lib::log_warn "sendmail failed"
            lib::log_info "Email sent to: ${EMAIL_RECIPIENT}"
        elif command -v mail &>/dev/null; then
            printf '%s\n' "${body}" \
                | mail -s "${subject}" \
                       -a "From: ${EMAIL_FROM:-root@localhost}" \
                       "${EMAIL_RECIPIENT:-root@localhost}" 2>/dev/null \
            || lib::log_warn "mail command failed"
            lib::log_info "Email sent (mail) to: ${EMAIL_RECIPIENT}"
        else
            lib::log_warn "EMAIL_ENABLED=true but no sendmail or mail binary found."
        fi
    fi

    # --- PVE notification system (PVE 8.1+) ---
    # Uses pvesh to create a notification send record with the full message body.
    if [[ "${PVE_NOTIFY_ENABLED:-false}" == true ]]; then
        if command -v pvesh &>/dev/null; then
            # The PVE notification API endpoint for sending a structured notification
            pvesh create /cluster/notifications \
                --target "${PVE_NOTIFY_TARGET:-mail-to-root}" \
                --title "${subject}" \
                --body "${body}" \
                2>/dev/null \
            || lib::log_warn "PVE pvesh notification send failed. Check target '${PVE_NOTIFY_TARGET}' in Datacenter → Notifications."
            lib::log_info "PVE notification sent via: ${PVE_NOTIFY_TARGET}"
        else
            lib::log_warn "PVE_NOTIFY_ENABLED=true but pvesh not found."
        fi
    fi
}

# =============================================================================
# LOCK — uses flock for atomic, race-free locking
# =============================================================================

_LOCK_FD=9

lib::acquire_lock() {
    # Open lock file on a dedicated file descriptor and flock it exclusively.
    # flock -n returns immediately with failure if already locked.
    eval "exec ${_LOCK_FD}>'${LOCK_FILE}'"
    if ! flock -n "${_LOCK_FD}"; then
        lib::log_error "Another instance is already running (lock held: ${LOCK_FILE}). Aborting."
        exit 1
    fi
    # Write PID for diagnostics
    echo $$ >&${_LOCK_FD}
    trap 'lib::release_lock' EXIT INT TERM HUP
    lib::log_info "Lock acquired (PID $$)"
}

lib::release_lock() {
    flock -u "${_LOCK_FD}" 2>/dev/null || true
    eval "exec ${_LOCK_FD}>&-" 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}

# =============================================================================
# BACKUP LIST & PRUNING
# =============================================================================

lib::list_backups() {
    local dest="${1:-${BACKUP_DEST_DIR}}"
    mapfile -t BACKUP_LIST < <(
        find "${dest}" -maxdepth 1 \( -name "pvehost-*.tar.zst" -o -name "pvehost-*.tar.zst.enc" \) \
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
        lib::log_info "Retention OK: ${count}/${RETENTION_COUNT} backups kept."
        return
    fi

    local to_delete=$(( count - RETENTION_COUNT ))
    lib::log_step "Pruning ${to_delete} old backup(s) (keeping ${RETENTION_COUNT})..."
    for (( i=RETENTION_COUNT; i<count; i++ )); do
        local old="${BACKUP_LIST[$i]}"
        local base="${old%.enc}"
        base="${base%.tar.zst}"
        lib::log_info "Removing: $(basename "${old}")"
        rm -f "${old}" "${base}.tar.zst.${CHECKSUM_ALGO}" "${base}.tar.zst.enc.${CHECKSUM_ALGO}" "${base}.manifest.json"
    done
}

# =============================================================================
# UTILITIES
# =============================================================================

lib::human_size() {
    local bytes="$1"
    awk -v b="${bytes}" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GiB\n", b/1073741824
        else if (b >= 1048576) printf "%.1f MiB\n", b/1048576
        else printf "%d KiB\n", int(b/1024)
    }'
}
