# Changelog

All notable changes are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [3.0.0] — 2025

### Security — critical fixes

- **Config file is no longer `source`d or `eval`'d.** The config is now parsed
  with `grep`/`sed` only. This eliminates the privilege escalation vector where
  a world-writable config file could inject arbitrary root code into the systemd
  service. The installer and the library both enforce `root:root 640` permissions
  and refuse to proceed if the config is group/world-writable.

- **Work directory is now `chmod 700` immediately after `mktemp`.** Previously
  the staging directory at `/tmp/pve-hostbackup-XXXXXX` was world-readable while
  sensitive config files were being assembled, briefly exposing `/etc/pve` content
  to any local user. Fixed.

- **Archive encryption added (`age`).** Optional symmetric encryption using
  `age` (https://age-encryption.org). The passphrase file is stored separately
  from the backup destination. Enabled via `ENCRYPT_ARCHIVES="true"` in config.

### Correctness — critical bug fixes

- **`/etc/pve` is now captured correctly.** Previously, `--one-file-system` on
  `tar` silently skipped `/etc/pve` entirely because it is a FUSE mount
  (`pmxcfs`), not on the same filesystem as `/`. Fixed by quiescing `pve-cluster`
  and copying the pmxcfs backing SQLite database (`/var/lib/pve-cluster/config.db`)
  directly, producing an atomic and consistent snapshot. Controlled by the new
  `STOP_PMXCFS_FOR_BACKUP` config option (default: `true`).

- **`--one-file-system` removed from `tar`.** The flag was silently dropping
  bind-mounted directories. Replaced with explicit path inclusion and the
  pmxcfs snapshot mechanism above.

- **`tar || true` replaced with `PIPESTATUS` check.** The previous `|| true`
  swallowed fatal tar errors (exit code 2) while appearing to succeed. The script
  now distinguishes between tar exit 1 (acceptable warnings) and exit 2 (fatal).

- **`pvesh` notification now sends an actual message body.** Previously the
  call used `test-target` which only pings the endpoint to verify it is reachable
  — no message content was ever delivered. Fixed.

- **Storage mountpoint resolution now uses `pvesm path`.** Previously the lib
  manually parsed `storage.cfg` and read the `path` directive — which does not
  exist for NFS or CIFS storage types (they use `export`, and the mount point is
  determined by PVE at runtime). Fixed by calling `pvesm path <storage-id>` which
  returns the correct local path for any storage backend.

- **`pveversion` parsing is now version-agnostic.** The previous `awk` regex was
  tied to the PVE 8.x output format and would silently produce `unknown` on PVE 9.
  Fixed with a `grep -oE '[0-9]+\.[0-9]+[^ /]*'` that works across versions.

- **`lib::human_size` rewritten without `bc`.** The previous implementation
  forked `bc` for floating-point arithmetic, adding a non-obvious dependency.
  Replaced with pure bash integer arithmetic.

- **Lock uses `flock(1)` for atomic acquisition.** The previous PID-file approach
  had a TOCTOU race: two processes could both read the lock file, both check that
  the PID was dead, and both proceed. `flock -n` is atomic.

### Restore — critical bug fixes

- **Service stop order corrected.** `pve-cluster` (the pmxcfs owner) is now
  stopped *first*, before `pvedaemon`/`pveproxy`/etc. Previously it was stopped
  last, meaning pmxcfs was still processing writes while consumers were being shut
  down and the extraction was beginning.

- **Wildcard extraction replaced with path-anchored staged extraction.** The
  previous `--wildcards "*etc/pve*"` pattern matched any path containing the
  string, including `/backup/etc/pve/` or archive entries from other tools. Fixed
  by extracting the full archive to a secure staging directory and installing files
  from there with explicit paths.

- **Permission restoration added.** `/etc/pve` requires `root:www-data 750` and
  `/etc/pve/priv` requires `root:root 700` for PVE to start. The restore script
  now calls `lib::fix_pve_permissions()` after extraction. SSH host key permissions
  (`600`/`644`) are also explicitly set.

- **SSH host key collision fixed.** A fresh PVE install generates new SSH host
  keys. If the backup's keys are simply extracted on top, both sets coexist and
  cause `REMOTE HOST IDENTIFICATION HAS CHANGED` warnings when reconnecting.
  Fixed by removing the fresh install's auto-generated keys before restoring.

- **Network config validated post-restore.** `ifquery --check -a` is run after
  restoring `/etc/network/interfaces` to warn if the restored config references
  NIC names that don't exist on this hardware.

### New features

- `STOP_PMXCFS_FOR_BACKUP` config option — controls whether pve-cluster is
  quiesced during backup (default: `true`). Set `false` only if brief service
  interruption is unacceptable.
- `MIN_FREE_MB` config option — minimum free space check on destination before
  writing any archive (default: 512 MiB). Prevents partial corrupt archives on
  full destinations.
- `ENCRYPT_ARCHIVES` / `ENCRYPT_PASSPHRASE_FILE` — optional age encryption.
- Missing paths added to default `BACKUP_PATHS`: `/etc/vzdump.conf`,
  `/var/lib/pve-manager/apl-info`, `/etc/pve-hostbackup` (self-backup).
- `LICENSE` file added (MIT).
- `CHANGELOG.md` added.
- `README.md` written for GitHub with full install/restore/troubleshooting docs.

### Removed

- `bc` dependency (replaced with bash arithmetic in `lib::human_size`)
- `--one-file-system` tar flag
- Manual `storage.cfg` parser (`_lib::storage_mountpoint`) — replaced by `pvesm path`
- `source "${CONFIG_FILE}"` — replaced by safe `grep`/`sed` parser

---

## [2.0.0] — initial release (superseded)

Initial modular implementation. See git history for details.
