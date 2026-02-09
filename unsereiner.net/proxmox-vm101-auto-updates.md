# VM 101 — Automatic Updates & Reboot

## Status: Applied

All settings below have been applied and verified with a dry run.

## Configuration

### 1. Enable all stable updates (not just security)

By default, only security updates are installed. To also include regular stable updates (`noble-updates`), uncomment the relevant line:

Edit `/etc/apt/apt.conf.d/50unattended-upgrades`:

```diff
 Unattended-Upgrade::Allowed-Origins {
 	"${distro_id}:${distro_codename}";
 	"${distro_id}:${distro_codename}-security";
 	"${distro_id}ESMApps:${distro_codename}-apps-security";
 	"${distro_id}ESM:${distro_codename}-infra-security";
-//	"${distro_id}:${distro_codename}-updates";
+	"${distro_id}:${distro_codename}-updates";
 };
```

### 2. Enable automatic reboot when required

Some updates (kernel, libc, systemd) require a reboot. Enable automatic reboot at a specific time to avoid running on stale kernels:

```diff
-//Unattended-Upgrade::Automatic-Reboot "false";
+Unattended-Upgrade::Automatic-Reboot "true";

-//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
+Unattended-Upgrade::Automatic-Reboot-WithUsers "true";

-//Unattended-Upgrade::Automatic-Reboot-Time "02:00";
+Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

This reboots at 04:00 if `/var/run/reboot-required` exists after an upgrade. Choose a time when the VM is least busy.

### 3. Clean up unused packages

After kernel upgrades, old kernels and unused dependencies pile up. Enable automatic cleanup:

```diff
-//Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
+Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

-//Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
+Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

-//Unattended-Upgrade::Remove-Unused-Dependencies "false";
+Unattended-Upgrade::Remove-Unused-Dependencies "true";
```

### 4. Enable syslog logging

Useful for debugging if something goes wrong:

```diff
-// Unattended-Upgrade::SyslogEnable "false";
+Unattended-Upgrade::SyslogEnable "true";
```

Logs will appear in `/var/log/syslog` and also in `/var/log/unattended-upgrades/`.

## Commands to Apply

All changes in a single script to run on the VM:

```bash
# Enable regular updates alongside security updates
sed -i 's|//\t"${distro_id}:${distro_codename}-updates";|\t"${distro_id}:${distro_codename}-updates";|' /etc/apt/apt.conf.d/50unattended-upgrades

# Enable automatic reboot at 04:00
sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
sed -i 's|//Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|Unattended-Upgrade::Automatic-Reboot-WithUsers "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time "02:00";|Unattended-Upgrade::Automatic-Reboot-Time "04:00";|' /etc/apt/apt.conf.d/50unattended-upgrades

# Clean up unused packages and kernels
sed -i 's|//Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
sed -i 's|//Unattended-Upgrade::Remove-New-Unused-Dependencies "true";|Unattended-Upgrade::Remove-New-Unused-Dependencies "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies "false";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' /etc/apt/apt.conf.d/50unattended-upgrades

# Enable syslog logging
sed -i 's|// Unattended-Upgrade::SyslogEnable "false";|Unattended-Upgrade::SyslogEnable "true";|' /etc/apt/apt.conf.d/50unattended-upgrades
```

## Verifying It Works

After applying the changes, do a dry run to confirm everything is configured correctly:

```bash
unattended-upgrades --dry-run --debug
```

Check which packages would be auto-upgraded:

```bash
apt list --upgradable 2>/dev/null
```

Check if a reboot is currently required:

```bash
cat /var/run/reboot-required 2>/dev/null && echo "Reboot needed" || echo "No reboot needed"
```

Check the update timer schedule:

```bash
systemctl list-timers | grep apt
```

Review past unattended-upgrade activity:

```bash
cat /var/log/unattended-upgrades/unattended-upgrades.log
```

## Summary

| Setting                  | Default          | Applied           |
|--------------------------|------------------|-------------------|
| Security updates         | enabled          | enabled           |
| Regular stable updates   | disabled         | **enabled**       |
| Automatic reboot         | disabled         | **enabled (04:00)** |
| Reboot with users        | disabled         | **enabled**       |
| Remove unused kernels    | disabled         | **enabled**       |
| Remove unused deps       | disabled         | **enabled**       |
| Syslog logging           | disabled         | **enabled**       |
