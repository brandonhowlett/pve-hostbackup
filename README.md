# pve-hostbackup

**Proxmox VE host configuration backup and restore suite.**

Proxmox VE has no native mechanism to back up the *host* configuration — the node itself, not the VMs and containers it runs. This tool fills that gap. It captures everything needed to fully restore a Proxmox host to a fresh install: network config, storage definitions, VM/CT configs, SSH keys, cron jobs, firewall rules, and more.

Compatible with **PVE 7.x, 8.x, and 9.x**.

---

## Features

- **Consistent `/etc/pve` snapshots** — briefly quiesces `pmxcfs` (the PVE cluster filesystem) and copies its backing SQLite database for a guaranteed dirty-read-free snapshot
- **Tiered storage** — writes to NFS → ZFS → local directory in priority order, using `pvesm` (the official PVE API) for storage resolution
- **Archive encryption** — optional `age`-based symmetric encryption; key stored separately from archives
- **SHA-256 integrity** — checksum written after every archive, verified before every restore
- **Pruning after success** — old archives only pruned once the new backup is fully committed and verified
- **Systemd-native** — timer with `Persistent=true` (catches missed runs after reboots), `OnFailure=` handler for crash-level alerts
- **Safe config parsing** — config is never `source`d/`eval`'d; parsed with `grep`/`sed` to prevent privilege escalation via config file tampering
- **Interactive restore wizard** — phased restore with dry-run preview, SSH key cleanup, permission restoration, and post-restore checklist

---

## Quick start

### Prerequisites

- Proxmox VE 7.x, 8.x, or 9.x
- Root access to the Proxmox host
- `git` installed (`apt-get install -y git`)

### Install

```bash
# On your Proxmox host
git clone https://github.com/YOUR_USERNAME/pve-hostbackup.git
cd pve-hostbackup
sudo bash install.sh
```

The installer will:
1. Check for and install required packages (`zstd`, `flock`, `rsync`)
2. Offer to install optional packages (`age` for encryption, `jq` for pretty manifests)
3. Install scripts, library, config, and systemd units with correct permissions
4. Enable and start the backup timer
5. Run a dry-run to verify the configuration

### Configure

```bash
sudo nano /etc/pve-hostbackup/pve-hostbackup.conf
```

Minimum required settings:

```bash
# Your PVE storage ID as shown in `pvesm status`
NFS_STORAGE_ID="nfs-backup"

# Email for notifications (requires working Postfix on the host)
EMAIL_RECIPIENT="admin@example.com"
```

### Run your first backup

```bash
# Dry-run — no files written, no services touched
pve-hostbackup --dry-run

# Real backup
pve-hostbackup

# List all archives
pve-hostbackup --list

# Verify a specific archive
pve-hostbackup --verify /path/to/archive.tar.zst
```

---

## Archive encryption (recommended)

Archives contain SSH private keys, TLS certificates, and PVE API tokens. Encrypt them, especially if the destination is a shared NFS server.

```bash
# Generate a passphrase file
head -c 48 /dev/urandom | base64 | sudo tee /etc/pve-hostbackup/backup.key
sudo chmod 400 /etc/pve-hostbackup/backup.key

# Enable in config
sudo sed -i 's/ENCRYPT_ARCHIVES="false"/ENCRYPT_ARCHIVES="true"/' \
    /etc/pve-hostbackup/pve-hostbackup.conf
```

> **Important:** Store `backup.key` somewhere other than the backup destination. If the NFS share is compromised and the key is also on it, encryption is worthless. Keep a copy offline.

---

## Restore procedure

### After reinstalling Proxmox VE

```bash
# 1. Fresh-install PVE on the target host (same or newer version)

# 2. Copy the archive to the new host
scp /mnt/nfs/pve-host-backups/pvehost-myhost-*.tar.zst root@new-host:/tmp/

# 3. Copy the restore script (or clone the repo)
scp pve-hostrestore.sh root@new-host:/tmp/

# 4. SSH into the new host and run the wizard
ssh root@new-host
bash /tmp/pve-hostrestore.sh --archive /tmp/pvehost-myhost-*.tar.zst
```

### Dry-run a restore (safe)

```bash
# Extracts to /tmp/pve-restore-preview — does NOT touch the system
bash pve-hostrestore.sh --archive /path/to/archive.tar.zst --dry-run

# Inspect what would have been written
ls -la /tmp/pve-restore-preview/
```

### Restore options

| Flag | Effect |
|---|---|
| `--archive FILE` | Skip interactive selection |
| `--dry-run` | Extract to `/tmp/pve-restore-preview` only |
| `--no-network` | Skip `/etc/network` restore (useful if NIC names differ) |
| `--no-zfs` | Skip ZFS pool import guidance |
| `--force` | Skip confirmation prompts |

---

## Scheduling

The systemd timer runs automatically. To inspect:

```bash
# Show next scheduled run
systemctl list-timers pve-hostbackup.timer

# Watch live log output
journalctl -u pve-hostbackup.service -f

# View the log file
tail -f /var/log/pve-hostbackup.log
```

To change the backup interval, update **both**:

1. `BACKUP_INTERVAL_DAYS` in `/etc/pve-hostbackup/pve-hostbackup.conf`
2. `OnUnitActiveSec` in `/etc/systemd/system/pve-hostbackup.timer`

Then reload:

```bash
systemctl daemon-reload
systemctl restart pve-hostbackup.timer
```

---

## What is backed up

| Path / source | Contents |
|---|---|
| `pmxcfs` SQLite DB | All of `/etc/pve` — VM configs, LXC configs, storage definitions, users, ACLs, HA config, firewall rules |
| `/etc/pve` tree | Live FUSE tree copy (quiesced, for inspection on restore) |
| `/var/lib/pve-*` | PVE runtime state databases |
| `/etc/network` | Network interface configuration |
| `/etc/hostname`, `/etc/hosts`, `/etc/fstab` | System identity and mounts |
| `/etc/ssh` + `/root/.ssh` | SSH host keys and authorized keys |
| `/var/spool/cron` + `/etc/cron.*` | Scheduled jobs |
| `/usr/local/bin\|sbin\|etc` | Custom scripts |
| `/etc/apt` | Repository sources |
| `/etc/postfix` | Mail transport config |
| `/etc/systemd/system` | Custom systemd units |
| `/etc/vzdump.conf` | PVE backup job configuration |
| `/etc/proxmox-backup` | PBS client config |
| `/etc/fail2ban` | Security tooling |
| `/etc/ssl/private` | TLS private keys |
| `/etc/pve-hostbackup` | This tool's own config (survives reinstall) |
| ZFS metadata text file | `zpool list`, `zpool status`, `zfs list`, import commands |

---

## Architecture

```
pve-hostbackup/
├── install.sh                          # One-shot installer
├── pve-hostbackup.conf                 # All configuration (safe key=value format)
├── pve-hostbackup-lib.sh               # Shared library (sourced, not executed)
├── pve-hostbackup.sh                   # Backup script
├── pve-hostrestore.sh                  # Restore wizard
└── systemd/
    ├── pve-hostbackup.service          # Systemd service
    ├── pve-hostbackup.timer            # Systemd timer (Persistent=true)
    └── pve-hostbackup-notify-fail.service  # OnFailure= handler
```

**Installed locations:**

| File | Destination |
|---|---|
| `pve-hostbackup-lib.sh` | `/usr/local/lib/pve-hostbackup/` |
| `pve-hostbackup.sh` | `/usr/local/sbin/pve-hostbackup.sh` |
| `pve-hostrestore.sh` | `/usr/local/sbin/pve-hostrestore.sh` |
| `pve-hostbackup.conf` | `/etc/pve-hostbackup/pve-hostbackup.conf` |
| Systemd units | `/etc/systemd/system/` |
| Log file | `/var/log/pve-hostbackup.log` |

---

## Storage priority

The backup script resolves the destination in this order:

1. **NFS/pvesm storage** (`NFS_STORAGE_ID`) — uses `pvesm path` (official PVE API); works for `dir`, `nfs`, `cifs`, and `zfspool` storage types
2. **ZFS path** (`ZFS_BACKUP_PATH`) — an explicit directory path on a ZFS dataset
3. **Local fallback** (`LOCAL_BACKUP_PATH`) — local filesystem; not protected against host disk failure

A warning is logged and emailed when falling back to a lower-priority tier.

---

## Notifications

Two notification channels are supported simultaneously:

**Email (Postfix/sendmail)**
```bash
EMAIL_ENABLED="true"
EMAIL_RECIPIENT="admin@example.com"
```
Requires a working Postfix installation. Test with:
```bash
echo "test" | sendmail -v admin@example.com
```

**Proxmox built-in notifications (PVE 8.1+)**
```bash
PVE_NOTIFY_ENABLED="true"
PVE_NOTIFY_TARGET="mail-to-root"
```
Configure notification targets under **Datacenter → Notifications** in the PVE web UI.

**Filter by event:**
```bash
NOTIFY_ON="all"      # success and failure (default)
NOTIFY_ON="failure"  # failures only (quieter)
NOTIFY_ON="success"  # successes only
```

---

## PVE 8.x → 9.x migration

```bash
# On the existing PVE 8.x host — run a fresh backup
pve-hostbackup
pve-hostbackup --list   # confirm the archive is there

# Note the archive path; copy it to safe storage (USB, another host, etc.)

# Install PVE 9.x fresh on the target hardware

# Copy the archive and restore script to the new host
scp pvehost-myhost-*.tar.zst root@new-host:/tmp/
scp pve-hostrestore.sh root@new-host:/tmp/

# Run the restore
ssh root@new-host
bash /tmp/pve-hostrestore.sh --archive /tmp/pvehost-myhost-*.tar.zst

# Verify, then reboot
pvesm status && qm list && pct list
reboot
```

---

## Uninstall

```bash
systemctl disable --now pve-hostbackup.timer pve-hostbackup.service
rm -f /etc/systemd/system/pve-hostbackup{.service,.timer,-notify-fail.service}
rm -f /usr/local/sbin/pve-hostbackup{,.sh}
rm -f /usr/local/sbin/pve-hostrestore{,.sh}
rm -f /usr/local/sbin/pve-hostbackup-notify-fail.sh
rm -rf /usr/local/lib/pve-hostbackup
# Remove config and key (destructive — keep your backup.key somewhere safe first!)
# rm -rf /etc/pve-hostbackup
systemctl daemon-reload
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| "No writable backup destination" | Run `pvesm status` and set `NFS_STORAGE_ID` to exactly match the storage name in the first column |
| Archive fails post-write verification | Check disk space on destination; check for NFS timeouts in `dmesg` |
| pmxcfs quiesce takes too long | Set `STOP_PMXCFS_FOR_BACKUP="false"` (accepts dirty-read risk) |
| "Config file must be owned by root" | `chown root:root /etc/pve-hostbackup/pve-hostbackup.conf` |
| "Config file must not be group/world-writable" | `chmod 640 /etc/pve-hostbackup/pve-hostbackup.conf` |
| Email not sending | `echo test \| sendmail -v root`; check `journalctl -u postfix` |
| PVE web UI won't start after restore | `systemctl status pve-cluster pvedaemon pveproxy`; check `/var/log/syslog` |
| ZFS pools missing after restore | `zpool import -a -f` |
| SSH fingerprint warning after restore | Expected — the host key changed. Run `ssh-keygen -R <host>` on the client. |
| Timer not firing | `systemctl status pve-hostbackup.timer`; `journalctl -u pve-hostbackup` |

---

## Security considerations

- The config file is parsed safely — never `source`d or `eval`'d — so a world-writable config cannot escalate to root code execution
- The installer enforces `chmod 640 root:root` on the config
- The work directory (`/tmp/pve-hostbackup-XXXXXX`) is created with `chmod 700` immediately — staging sensitive files is never world-readable
- Archives contain SSH private keys and PVE API tokens — **enable `ENCRYPT_ARCHIVES`** if the backup destination is shared
- The encryption key (`backup.key`) must be stored separately from the archive destination

---

## Contributing

Pull requests are welcome. Before submitting:

```bash
# Syntax check all scripts
bash -n pve-hostbackup-lib.sh
bash -n pve-hostbackup.sh
bash -n pve-hostrestore.sh
bash -n install.sh

# Optional: shellcheck (apt-get install shellcheck)
shellcheck -x pve-hostbackup.sh pve-hostrestore.sh install.sh
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgements

- [Proxmox VE](https://www.proxmox.com) — the platform this tool supports
- [age encryption](https://age-encryption.org) — the encryption backend
- [zstd](https://facebook.github.io/zstd/) — the compression backend
