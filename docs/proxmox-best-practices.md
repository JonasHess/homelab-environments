# Proxmox Best Practices - Recommendations

Server: `192.168.1.2` | PVE 9.1.1 | Intel Pentium Silver J5040 | 16 GB RAM
Audited: 2026-02-09

## Summary

| Area | Status | Priority |
|------|--------|----------|
| Repository config (no-subscription) | Needs fix | **Critical** |
| Ceph repo (enterprise) | Needs fix | **Critical** |
| SSH hardening | Needs fix | **High** |
| Firewall | Needs fix | **High** |
| Backup configuration | Needs fix | **High** |
| fail2ban | Not installed | **High** |
| Locale warnings | Broken | Medium |
| No-subscription nag removal | Optional | Low |
| Unattended upgrades | Not installed | Medium |
| Memory pressure | Monitor | Medium |
| ZFS pool redundancy | Review | Medium |
| sysctl tuning | Not configured | Low |

---

## Critical: Repository Configuration

### Problem

You are using the **enterprise repositories** without a subscription. This means `apt update` will fail for PVE and Ceph packages, and you will **not receive any updates**.

Current repos:
- `pve-enterprise.sources` - requires subscription
- `ceph.sources` - points to enterprise Ceph repo

### Fix

Switch to the **no-subscription** repositories:

```bash
# Disable enterprise PVE repo
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Disable the enterprise repo
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled

# Switch Ceph to no-subscription
cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Verify
apt update
```

> **Note:** The no-subscription repo is not recommended for production but is perfectly fine for homelab use. It is the same packages, just tested slightly less.

---

## High: SSH Hardening

### Problem

- `PermitRootLogin yes` - root login via password is allowed
- No explicit `PasswordAuthentication no`
- No explicit `PubkeyAuthentication yes`

### Fix

Since you already have SSH key access working:

```bash
# Edit /etc/ssh/sshd_config
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes

# Restart SSH
systemctl restart sshd
```

> **Warning:** Make sure your SSH key is working before disabling password auth. Test in a second terminal before closing your current session.

---

## High: Firewall

### Problem

The PVE firewall is **disabled**. The server is directly exposed on the network with no host-level firewall rules.

### Fix

Enable the PVE firewall with sensible defaults:

```bash
# /etc/pve/firewall/cluster.fw
cat > /etc/pve/firewall/cluster.fw <<'EOF'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p tcp -dport 22 -log nolog   # SSH
IN ACCEPT -p tcp -dport 8006 -log nolog # PVE Web UI
IN ACCEPT -p tcp -dport 3128 -log nolog # SPICE proxy
IN ACCEPT -p icmp -log nolog            # Ping
EOF

# Enable on the node
pvesh set /nodes/$(hostname)/firewall/options -enable 1
```

Adjust rules based on your actual needs (e.g., if VMs need specific port forwarding).

---

## High: Install fail2ban

### Problem

fail2ban is not installed. Without it, brute-force attacks against SSH and the PVE web UI are not rate-limited.

### Fix

```bash
apt install fail2ban -y

# Create PVE-specific jail
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
backend = systemd
maxretry = 3
findtime = 10m
bantime = 1h
EOF

# Create PVE filter
cat > /etc/fail2ban/filter.d/proxmox.conf <<'EOF'
[Definition]
failregex = pvedaemon\[.*authentication (verification )?failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
EOF

systemctl enable --now fail2ban
```

---

## High: Backup Configuration

### Problem

`/etc/vzdump.conf` is entirely defaults (all commented out). No scheduled backups are configured.

### Fix

1. Set up a backup storage location (ideally off-host, e.g., NFS or PBS)
2. Configure scheduled backups via the PVE UI: Datacenter > Backup > Add
3. At minimum, configure:
   - A backup schedule (e.g., daily at 2 AM)
   - Retention policy (e.g., keep last 3 daily, 2 weekly)
   - Email notification on failure

Example vzdump.conf:

```bash
# /etc/vzdump.conf
storage: local
mode: snapshot
mailto: Jonas@Hess.pm
prune-backups: keep-daily=3,keep-weekly=2,keep-monthly=1
```

---

## Medium: Fix Locale Warnings

### Problem

Perl locale warnings appear on many commands, caused by an incomplete locale configuration forwarded via SSH.

### Fix

```bash
# Generate the locale
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# Set as default
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Prevent SSH from forwarding broken locale (on the server)
# In /etc/ssh/sshd_config, comment out:
# AcceptEnv LANG LC_*
```

---

## Medium: Unattended Security Updates

### Problem

No automatic security updates are configured. Debian security patches won't be applied unless you manually run `apt upgrade`.

### Fix

```bash
apt install unattended-upgrades -y

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=trixie,label=Debian-Security";
};
Unattended-Upgrade::Mail "Jonas@Hess.pm";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# Enable the timer
systemctl enable --now apt-daily.timer
systemctl enable --now apt-daily-upgrade.timer
```

> **Note:** Do **not** include Proxmox packages in unattended upgrades - PVE updates can require manual intervention (kernel updates, etc.). Only auto-update Debian security packages.

---

## Medium: Memory Pressure

### Observation

- 14 GiB of 15 GiB RAM used, only ~636 MiB free
- 681 MiB swap in use

This is not necessarily a problem (Linux uses free RAM for caching), but monitor it. If VMs are frequently swapping, consider:

- Reducing VM memory allocations
- Enabling KSM (Kernel Same-page Merging) if running similar VMs: `systemctl enable --now ksm`
- Adding more RAM if possible

---

## Medium: ZFS Pool Considerations

### Observation

- `tank3` is a single 464 GB ZFS pool (no visible redundancy - likely a single disk or stripe)
- `sda` and `sdb` are both 465.8 GB - could be mirror candidates

### Recommendation

If `tank3` holds important VM data, consider:
- **If sda + sdb are the pool as a stripe:** This has no redundancy. A single disk failure loses all data. Convert to a mirror if possible.
- **If only one disk is in the pool:** Add the other as a mirror: `zpool attach tank3 <existing-disk> <new-disk>`
- Verify current layout: `zpool status tank3`
- Enable regular scrubs (may already be scheduled): `systemctl enable --now zfs-scrub-weekly@tank3.timer`

---

## Low: Remove Subscription Nag (Optional)

The PVE web UI shows a "No valid subscription" popup on login. To remove it:

```bash
# This needs to be re-applied after PVE updates
sed -Ei.bak "s/NotFound/Active/g" /usr/share/perl5/PVE/API2/Subscription.pm
systemctl restart pveproxy.service
```

> **Note:** This is cosmetic only. Consider supporting Proxmox with a community subscription if you find the project valuable.

---

## Low: sysctl Tuning

`/etc/sysctl.conf` is empty. Consider basic tuning:

```bash
cat >> /etc/sysctl.conf <<'EOF'
# Network performance
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Reduce swap tendency (good when you have ZFS ARC)
vm.swappiness = 10
EOF

sysctl -p
```

---

## Checklist

- [ ] Switch to no-subscription repositories
- [ ] Switch Ceph to no-subscription repository
- [ ] Run `apt update && apt dist-upgrade`
- [ ] Harden SSH (disable password auth, prohibit root password login)
- [ ] Enable PVE firewall
- [ ] Install and configure fail2ban
- [ ] Set up VM backups with retention policy
- [ ] Fix locale configuration
- [ ] Install unattended-upgrades for Debian security patches
- [ ] Check ZFS pool redundancy (`zpool status tank3`)
- [ ] Apply sysctl tuning
- [ ] Remove subscription nag (optional)
