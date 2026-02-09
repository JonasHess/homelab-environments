# VM 101 — nutellajunkies

## Overview

| Setting      | Value                                        |
|--------------|----------------------------------------------|
| VMID         | 101                                          |
| Name         | nutellajunkies                               |
| Memory       | 6048 MB                                      |
| CPU          | 2 cores, 1 socket (x86-64-v2-AES)           |
| Boot Disk    | 64 GB (scsi0 on tank3, Ubuntu 24.04 cloud image) |
| Cloud-Init   | ide2 (tank3)                                 |
| Network      | virtio on **vmbr2** (192.168.178.x)          |
| IP Address   | 192.168.178.101 (static, via cloud-init)     |
| Gateway      | 192.168.178.1                                |
| DNS          | 192.168.178.1                                |
| OS           | Ubuntu 24.04 LTS (cloud image)               |
| SSH Access   | root (key-based)                             |
| VirtIO-fs    | nutellajunkies → /mnt/nutellajunkies         |

## Cloud-Init

The VM uses a cloud image with Proxmox cloud-init. The following was configured:

```bash
qm set 101 --ipconfig0 ip=192.168.178.101/24,gw=192.168.178.1
qm set 101 --nameserver 192.168.178.1
qm set 101 --ciuser root
qm set 101 --sshkeys /root/.ssh/authorized_keys
```

A custom vendor-data snippet (`/var/lib/vz/snippets/101-user-data.yml`) handles the virtiofs mount:

```yaml
#cloud-config
mounts:
  - [nutellajunkies, /mnt/nutellajunkies, virtiofs, "rw,relatime", "0", "0"]

runcmd:
  - mkdir -p /mnt/nutellajunkies
```

Applied with:

```bash
qm set 101 --cicustom 'vendor=local:snippets/101-user-data.yml'
```

### Cloud Image Setup

The VM was converted from a manual ISO install to a cloud image:

1. Downloaded the Ubuntu 24.04 cloud image:

```bash
wget -O /tmp/ubuntu-24.04-cloud.img https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

2. Removed the old empty disk and ISO, imported the cloud image:

```bash
qm set 101 --delete ide2
qm disk unlink 101 --idlist scsi0 --force 1
qm importdisk 101 /tmp/ubuntu-24.04-cloud.img tank3
qm set 101 --scsi0 tank3:vm-101-disk-0,iothread=1
qm disk resize 101 scsi0 64G
```

3. Added cloud-init drive and serial console:

```bash
qm set 101 --ide2 tank3:cloudinit
qm set 101 --boot order='scsi0'
qm set 101 --serial0 socket --vga serial0
```

## Storage

### Boot Disk

The VM boot disk is a ZFS volume on the `tank3` pool:

```
scsi0: tank3:vm-101-disk-0 (64 GB, virtio-scsi-single, iothread=1)
```

### Shared Directory (VirtIO-fs)

A ZFS dataset is shared into the VM via VirtIO filesystem passthrough (virtiofs).

| Property         | Value                            |
|------------------|----------------------------------|
| ZFS Dataset      | tank3/data/nutellajunkies        |
| Host Mountpoint  | /tank3/data/nutellajunkies       |
| Parent Dataset   | tank3/data                       |
| Compression      | on (inherited from tank3)        |
| Directory Mapping| nutellajunkies (Proxmox cluster) |
| VM Config        | virtiofs0: dirid=nutellajunkies, cache=auto |
| Guest Mount      | /mnt/nutellajunkies (auto-mounted via cloud-init) |

#### What Was Configured

1. Created the ZFS datasets:

```bash
zfs create tank3/data
zfs create tank3/data/nutellajunkies
```

2. Created a Proxmox directory mapping:

```bash
pvesh create /cluster/mapping/dir --id nutellajunkies --map node=pve,path=/tank3/data/nutellajunkies
```

3. Added virtiofs to the VM config:

```bash
qm set 101 -virtiofs0 dirid=nutellajunkies,cache=auto
```

4. Enabled snippets on local storage (one-time):

```bash
pvesm set local --content import,vztmpl,iso,backup,snippets
```

## Network

The VM is on **vmbr2**, connected to the 192.168.178.0/24 network.

| Setting        | Value                                |
|----------------|--------------------------------------|
| Bridge         | vmbr2                                |
| NIC            | virtio (BC:24:11:FF:C9:E4)           |
| Guest NIC      | eth0 (altname enp0s18)               |
| Firewall       | enabled                              |
| IP             | 192.168.178.101/24                   |
| Gateway        | 192.168.178.1                        |
| DNS            | 192.168.178.1 (via systemd-resolved) |

The VM is reachable via SSH from the 192.168.178.0/24 network:

```bash
ssh root@192.168.178.101
```

## Verified

All of the following have been confirmed working after first boot:

- Static IP 192.168.178.101/24 on eth0
- Default route via 192.168.178.1
- DNS resolution via systemd-resolved (192.168.178.1)
- SSH access as root (key-based)
- VirtIO-fs mount at /mnt/nutellajunkies (virtiofs)
- fstab entry present for persistent mount across reboots
- cloud-init status: done

## Automatic Updates

The VM is configured with `unattended-upgrades` to automatically install security and stable updates daily, reboot at 04:00 if required, and clean up unused packages/kernels. Logs at `/var/log/unattended-upgrades/`. See `proxmox-vm101-auto-updates.md` for full details.

## Limitations

- Memory hotplug does not work with virtiofs
- Live migration, snapshots, and hibernate are not available with virtiofs devices
- If virtiofsd crashes, the mount point will hang in the VM until it is fully stopped
