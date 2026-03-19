# pve-hostbackup

A production-grade backup and restore suite for **Proxmox VE host configuration**.

Compatible with PVE **7.x, 8.x, and 9.x+**. Designed for single-node installations and for migrating between major versions (e.g. 8.x → 9.x).

> **Why does this exist?** Proxmox has excellent tooling for backing up VMs and containers via `vzdump`, but no native mechanism to back up the *host itself* — its network config, storage definitions, user accounts, firewall rules, and VM/LXC configuration metadata. This suite fills that gap.

---

## Quick start

If you just want to get up and running, follow these four steps. Everything else in this document is reference material.

### Step 1 — Install git and clone

Proxmox does not ship with `git` by default. Run these commands in the Proxmox shell (the terminal in the web UI, or SSH):

```bash
apt install git
git clone https://github.com/YOUR_USERNAME/pve-hostbackup.git
cd pve-hostbackup
```

> **Note:** Proxmox runs as `root` by default. There is no `sudo` on a standard Proxmox installation — just paste commands directly. If you see `sudo: command not found`, simply remove the word `sudo` from the command.

### Step 2 — Run the installer

```bash
bash install.sh
```

The installer will:
- Check for required tools and install any that are missing (`jq`, `age`)
- Copy all scripts and config files into place
- Enable the backup timer so backups run automatically
- Print your available storage IDs at the end so you know what to put in the config

### Step 3 — Edit the config

The installer prints your storage list at the end. Use that to fill in the config:

```bash
nano /etc/pve-hostbackup/pve-hostbackup.conf
```

The two settings you must change:

```bash
# Set this to a Name from `pvesm status` — e.g. "BackupUSB" or "nfs-backup"
# If you have no dedicated backup storage, leave this empty ("") and use
# LOCAL_BACKUP_PATH below instead.
NFS_STORAGE_ID="BackupUSB"

# Only used if NFS_STORAGE_ID is empty. This path must already exist.
LOCAL_BACKUP_PATH="/var/lib/pve-hostbackup"

# Your email address for notifications (optional but recommended)
EMAIL_RECIPIENT="you@example.com"
```

To save and exit nano: press `Ctrl+X`, then `Y`, then `Enter`.

### Step 4 — Verify and run your first backup

```bash
# Safe simulation — reads your config and shows what would happen, writes nothing
pve-hostbackup --dry-run

# Run a real backup
pve-hostbackup

# Confirm it was stored
pve-hostbackup --list
```

That's it. Backups will now run automatically every 3 days (configurable).

---

## Choosing a backup destination

Run `pvesm status` to see your available storages:

```
Name          Type     Status    Total      Used       Available   %
BackupUSB     dir      active    7658084    4662384    2586104     60%
local         dir      active    93052672   13854848   79197824    14%
local-zfs     zfspool  active    95263824   16065888   79197936    16%
nfs-backup    nfs      active    ...
```

| Your situation | What to set |
|---|---|
| You have a dedicated NFS share or USB drive appearing in `pvesm status` | Set `NFS_STORAGE_ID` to its exact Name (e.g. `"BackupUSB"`) |
| You only have `local` or `local-zfs` | Leave `NFS_STORAGE_ID=""` and set `LOCAL_BACKUP_PATH` to a path on that storage |
| You have a ZFS dataset you want to use directly | Leave `NFS_STORAGE_ID=""` and set `ZFS_BACKUP_PATH` to the dataset's mountpoint |

Backups stored on the same physical disk as your OS are not a true backup — if the disk fails you lose everything. A USB drive, NFS share, or separate ZFS pool on different hardware is strongly recommended.

---

## Features

- **Atomic, consistent `/etc/pve` backup** — stops `pve-cluster` briefly to flush `pmxcfs` to its SQLite backing database (`config.db`), then snapshots that file. Eliminates dirty reads from the FUSE filesystem.
- **Tiered storage** — PVE storage ID → ZFS dataset → local directory, resolved via `pvesm path` (official API)
- **Archive encryption** — `age` (recommended) or `openssl` AES-256-CBC
- **Integrity verification** — SHA-256 checksum + `tar -t` readability test on every backup and before every restore
- **Phased, safe restore** — stops `pve-cluster` first, extracts in dependency order, restores file permissions explicitly, backs up new host SSH keys before overwriting
- **ifreload validation** — validates restored network config before allowing reboot
- **Systemd-native** — timer with `Persistent=true`, `OnFailure=` handler for crash notifications
- **Dual notifications** — email (Postfix/sendmail) + PVE built-in notification system (PVE 8.1+)
- **Security hardened** — config parsed (not sourced), `flock`-based locking, secure temp dirs (`chmod 700`)
- **Configurable retention** — keep N backups; prune runs *after* new backup is confirmed good
- **Free-space gate** — aborts before writing if destination has insufficient space
- **Dry-run on both backup and restore** — safe to test at any time

---

## What gets backed up

| Path | Contents |
|---|---|
| `/var/lib/pve-cluster/config.db` | pmxcfs SQLite snapshot — the authoritative source for all `/etc/pve` data |
| `/etc/pve` + `/etc/pve/priv` | VM/LXC configs, storage definitions, users, ACLs, firewall rules, API tokens |
| `/etc/vzdump.conf` | Backup job definitions |
| `/etc/network/interfaces{,.d/}` | Network configuration |
| `/etc/hostname`, `/etc/hosts`, `/etc/fstab`, `/etc/resolv.conf` | System identity and mounts |
| `/etc/ssh`, `/root/.ssh` | SSH host keys and authorized keys |
| `/var/lib/pve-{manager,daemon,proxy,firewall}` | PVE runtime state |
| `/var/lib/pve-manager/apl-info` | Container template index |
| `/etc/cron.*`, `/var/spool/cron` | Scheduled jobs |
| `/usr/local/{bin,sbin,etc}` | Custom scripts |
| `/etc/systemd/system`, `/etc/systemd/network` | Custom units and network configs |
| `/etc/apt/sources.list{,.d/,.preferences.d/}` | Repository configuration |
| `/etc/postfix`, `/etc/fail2ban`, `/etc/ssl/private` | Mail, security, TLS |
| ZFS metadata | `zpool list/status/zfs list` — import commands for restore |

---

## Requirements

- Proxmox VE 7.x, 8.x, or 9.x
- Root access (standard on Proxmox — no `sudo` needed)
- `tar`, `zstd`, `sha256sum`, `flock`, `awk` — all present on PVE by default
- `jq` — optional, for pretty-printed manifests (installer will offer to install it)
- `age` — optional, for archive encryption (installer will offer to install it)

---

## Full command reference

### Backup

```bash
pve-hostbackup                        # run backup now
pve-hostbackup --dry-run              # simulate — no files written, safe at any time
pve-hostbackup --list                 # list all stored backups with sizes and dates
pve-hostbackup --verify /path/to.tar.zst  # verify a specific archive
pve-hostbackup --verbose              # show every file being processed
pve-hostbackup --dest /mnt/usb        # override backup destination
```

### Restore

```bash
# Interactive wizard — select from a list of available backups
pve-hostrestore

# Restore a specific archive (--pmxcfs-restore gives the most complete restore)
pve-hostrestore --archive /path/to/pvehost-backup.tar.zst --pmxcfs-restore

# Safe preview — extracts to a temp directory, no system files touched
pve-hostrestore --archive /path/to/archive.tar.zst --dry-run

# Skip network config (useful when restoring to different hardware with different NIC names)
pve-hostrestore --archive /path/to/archive.tar.zst --no-network
```

### Schedule and logs

```bash
systemctl list-timers pve-hostbackup.timer    # show next scheduled run time
journalctl -u pve-hostbackup.service -f       # watch live log output
journalctl -u pve-hostbackup.service --since '7 days ago'
cat /var/log/pve-hostbackup.log               # full log file
```

To change the backup interval, edit **both** of these to keep them in sync:

1. `BACKUP_INTERVAL_DAYS` in `/etc/pve-hostbackup/pve-hostbackup.conf`
2. `OnUnitActiveSec` in `/etc/systemd/system/pve-hostbackup.timer`

Then reload:
```bash
systemctl daemon-reload && systemctl restart pve-hostbackup.timer
```

---

## Enabling encryption (optional but recommended)

Archives contain SSH private keys, TLS certificates, and PVE API tokens. If your backup destination is a shared NFS or accessible USB drive, encrypting archives means that physical access to the drive cannot compromise your host.

```bash
# Generate a random passphrase file (or use your own passphrase)
head -c 48 /dev/urandom | base64 > /etc/pve-hostbackup/.archive-key
chmod 400 /etc/pve-hostbackup/.archive-key

# Enable encryption in the config
nano /etc/pve-hostbackup/pve-hostbackup.conf
# Set: ENCRYPT_ARCHIVE=true
```

The encryption key file must be stored separately from your backup archives — keep a copy in a password manager or on a different machine. Without it, encrypted backups cannot be restored.

---

## PVE 8.x → 9.x Migration

```bash
# ── On your existing PVE 8.x host ─────────────────────────────────────────

# Run a fresh backup immediately before migrating
pve-hostbackup
pve-hostbackup --list   # note the archive path

# Copy the archive somewhere safe if using local storage
# (if using NFS the archive is already on the share)
scp /var/lib/pve-hostbackup/pvehost-*.tar.zst user@somewhere:/safe/


# ── On the new PVE 9.x host (after fresh install) ─────────────────────────

apt install git
git clone https://github.com/YOUR_USERNAME/pve-hostbackup.git
cd pve-hostbackup

# Copy the archive back if needed
# scp user@somewhere:/safe/pvehost-*.tar.zst /tmp/

# Run the restore wizard
pve-hostrestore --archive /tmp/pvehost-*.tar.zst --pmxcfs-restore

# Follow the checklist printed at the end, then reboot
```

---

## Archive format

Each backup produces three files alongside each other:

```
pvehost-<hostname>-<pve-version>-<YYYYMMDD-HHMMSS>.tar.zst         ← the archive
pvehost-<hostname>-<pve-version>-<YYYYMMDD-HHMMSS>.tar.zst.sha256  ← checksum
pvehost-<hostname>-<pve-version>-<YYYYMMDD-HHMMSS>.manifest.json   ← metadata
```

With encryption enabled, the archive becomes `.tar.zst.enc` and the checksum covers the encrypted file.

The manifest records: hostname, PVE version, kernel, timestamp, included paths, network interface snapshot, `pvesm status` output, and restore procedure steps.

---

## Security notes

- The config file is `chmod 600 root:root` and is **parsed, not sourced** — editing it cannot cause code execution
- All temporary work is done in `mktemp -d` directories with `chmod 700` — not visible to other users
- Locking uses `flock(1)` — atomic, no race condition
- Archives contain sensitive material (SSH keys, PVE tokens) — enable encryption and restrict destination permissions

---

## Notifications

### Email (Postfix)
Set `EMAIL_ENABLED=true` and `EMAIL_RECIPIENT`. Requires working Postfix on the host (standard on most PVE installs).

### PVE built-in notifications (PVE 8.1+)
Set `PVE_NOTIFY_ENABLED=true`. Configure a notification target in the PVE web UI under **Datacenter → Notifications**, then set `PVE_NOTIFY_TARGET` to its name.

Control when you get notified:
```bash
NOTIFY_ON="failure"  # only on failure — recommended to reduce noise
NOTIFY_ON="all"      # both success and failure
NOTIFY_ON="success"  # only on success
```

---

## File structure

```
pve-hostbackup/
├── install.sh                              # Installer
├── uninstall.sh                            # Removal script
├── pve-hostbackup.conf                     # All configuration settings
├── pve-hostbackup-lib.sh                   # Shared library (not run directly)
├── pve-hostbackup.sh                       # Backup script
├── pve-hostrestore.sh                      # Restore wizard
├── systemd/
│   ├── pve-hostbackup.service              # Systemd service unit
│   ├── pve-hostbackup.timer                # Systemd timer (schedule)
│   └── pve-hostbackup-notify-fail.service  # Failure notification handler
└── README.md
```

After installation, files live at:

```
/usr/local/sbin/pve-hostbackup          ← run this to take a backup
/usr/local/sbin/pve-hostrestore         ← run this to restore
/usr/local/lib/pve-hostbackup/          ← shared library
/etc/pve-hostbackup/pve-hostbackup.conf ← your configuration
/etc/pve-hostbackup/.archive-key        ← encryption passphrase (if used)
/etc/systemd/system/pve-hostbackup.*    ← systemd units
/var/log/pve-hostbackup.log             ← log file
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `sudo: command not found` | Proxmox runs as root — just remove `sudo` from the command |
| `"No writable backup destination"` | Check `NFS_STORAGE_ID` exactly matches the Name in `pvesm status` |
| `"Config file is group/world-writable"` | Run: `chmod 600 /etc/pve-hostbackup/pve-hostbackup.conf` |
| `"Config file must be owned by root"` | Run: `chown root:root /etc/pve-hostbackup/pve-hostbackup.conf` |
| Archive fails integrity check | Re-run backup; check available space on destination with `df -h` |
| Email not sending | Test with: `echo test \| sendmail -v root@localhost` |
| PVE notify fails | Check the target name in PVE web UI → Datacenter → Notifications |
| Timer not firing | `systemctl status pve-hostbackup.timer` and `journalctl -u pve-hostbackup` |
| Restore: web UI won't start | Fix permissions: `chmod 700 /etc/pve && chown root:root /etc/pve` |
| Restore: wrong NIC names | Use `--no-network` and edit `/etc/network/interfaces` manually |
| ifreload validation fails | NIC names likely differ on new hardware — check `ip link show` |
| Encrypted archive won't open | Verify `age` is installed and the passphrase file path is correct |

---

## Uninstall

```bash
bash uninstall.sh
```

This removes all installed scripts and config. Backup archives are **never deleted**.

---

## Contributing

Issues and pull requests are welcome. When reporting a bug, please include:
- PVE version: `pveversion`
- Installer or backup log: `journalctl -u pve-hostbackup.service`
- The manifest from the affected archive (redact hostnames/IPs as needed)

---

## License

MIT License. See `LICENSE` for details.
