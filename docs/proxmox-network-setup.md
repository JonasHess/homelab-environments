# Proxmox Network Configuration

## Goal

Separate the Proxmox server into three isolated networks:

- **Management network (192.168.1.0/24)** — Used exclusively to manage the Proxmox host via SSH and the web UI. Not accessible to VMs.
- **VM network (192.168.0.0/24)** — Used by select VMs that need internet access or connectivity through a different gateway. The Proxmox host has no IP on this network and is not reachable from it.
- **VM network (192.168.178.0/24)** — Used by select VMs that need connectivity on the 192.168.178.x network. The Proxmox host has no IP on this network and is not reachable from it.

## Network Topology

```
              ┌──────────────────────────────────────────────┐
              │               Proxmox Host                   │
              │               192.168.1.2                    │
              │                                              │
              │   vmbr0 (management)    vmbr1       vmbr2    │
              │       │                   │           │      │
              │     nic2              nic3          nic0     │
              │   (Realtek)     (Intel 82576)  (Intel 82576) │
              └───────┼───────────────┼───────────────┼──────┘
                      │               │               │
                      │               │               │
             ┌────────┴──────┐ ┌──────┴───────┐ ┌─────┴─────────┐
             │  192.168.1.0  │ │ 192.168.0.0  │ │ 192.168.178.0 │
             │    /24 LAN    │ │   /24 LAN    │ │    /24 LAN    │
             │               │ │              │ │               │
             │  GW: .1.1     │ │  GW: .0.1    │ │  GW: .178.1   │
             └───────────────┘ └──────────────┘ └───────────────┘
```

### Hardware

| NIC  | Chip             | PCIe Address | Role              |
|------|------------------|--------------|-------------------|
| nic2 | Realtek RTL8111  | 03:00.0      | Management (vmbr0)|
| nic3 | Intel 82576      | 01:00.1      | VM network (vmbr1)|
| nic0 | Intel 82576      | 01:00.0      | VM network (vmbr2), same PCIe card as nic3 |
| nic1 | USB NIC          | USB 1-6      | Unused            |

### Bridges

| Bridge | IP Address     | Gateway     | Bridge Port | Purpose            |
|--------|----------------|-------------|-------------|--------------------|
| vmbr0  | 192.168.1.2/24 | 192.168.1.1 | nic2        | Proxmox management |
| vmbr1  | none           | none        | nic3        | VM-only network    |
| vmbr2  | none           | none        | nic0        | VM-only network    |

## What Was Configured

### 1. Identified the correct NIC

The server has a dual-port Intel 82576 PCIe card (nic0 and nic3). A single cable was connected to one of the ports. We brought both NICs up and checked link status to determine which port had the cable:

```bash
ip link set nic0 up
ip link set nic3 up
ethtool nic0 | grep 'Link detected'  # no
ethtool nic3 | grep 'Link detected'  # yes
```

Result: the cable is connected to **nic3** (PCIe 01:00.1).

### 2. Created vmbr1 temporarily to test

Before making any persistent changes, the bridge was created live to verify it worked without disrupting SSH access:

```bash
ip link add name vmbr1 type bridge
ip link set nic3 master vmbr1
ip link set nic3 up
ip link set vmbr1 up
```

SSH connectivity was confirmed after each step.

### 3. Made the configuration persistent

A backup of the network config was created:

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak
```

Then the following block was appended to `/etc/network/interfaces`:

```
auto vmbr1
iface vmbr1 inet manual
	bridge-ports nic3
	bridge-stp off
	bridge-fd 0
```

No existing configuration was modified — the vmbr0 management bridge was left untouched.

### 4. Connected nic0 to 192.168.178.0/24 and created vmbr2

The second port on the Intel 82576 card (nic0) was connected to the 192.168.178.0/24 network. The bridge was created following the same approach as vmbr1.

Verified link:

```bash
ip link set nic0 up
ethtool nic0 | grep 'Link detected'  # yes
```

Created the bridge live:

```bash
ip link add name vmbr2 type bridge
ip link set nic0 master vmbr2
ip link set vmbr2 up
```

SSH connectivity was confirmed. Then the config was persisted by appending to `/etc/network/interfaces` (backup at `interfaces.bak2`):

```
auto vmbr2
iface vmbr2 inet manual
	bridge-ports nic0
	bridge-stp off
	bridge-fd 0
```

## Virtual Machines

### VM 100 — netbox

| Setting      | Value                              |
|--------------|------------------------------------|
| VMID         | 100                                |
| Name         | netbox                             |
| Memory       | 8048 MB                            |
| Boot Disk    | 128 GB (scsi0)                     |
| Network      | virtio on **vmbr1** (192.168.0.x)  |
| IP Address   | 192.168.0.5 (static)               |
| Gateway      | 192.168.0.1                        |
| DNS          | 192.168.0.1                        |
| OS           | Ubuntu 24.04 LTS                   |
| SSH Access   | root and jonas (key-based)         |

Previously this VM was on vmbr0 (192.168.1.x). It was moved to vmbr1 with:

```bash
qm set 100 -net0 virtio=BC:24:11:94:7F:68,bridge=vmbr1,firewall=1
```

The static IP was configured via netplan (`/etc/netplan/50-cloud-init.yaml`):

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      addresses:
        - 192.168.0.5/24
      routes:
        - to: default
          via: 192.168.0.1
      nameservers:
        addresses:
          - 192.168.0.1
```

The VM is **not reachable** from the management network (192.168.1.x) — only from the 192.168.0.x network.

### VM 101 — nutellajunkies

| Setting      | Value                                       |
|--------------|---------------------------------------------|
| VMID         | 101                                         |
| Name         | nutellajunkies                              |
| Memory       | 4096 MB                                     |
| Boot Disk    | 64 GB (scsi0 on tank3, cloud image)         |
| Network      | virtio on **vmbr2** (192.168.178.x)         |
| IP Address   | 192.168.178.101 (static, via cloud-init)    |
| Gateway      | 192.168.178.1                               |
| DNS          | 192.168.178.1                               |
| OS           | Ubuntu 24.04 LTS (cloud image)              |
| SSH Access   | root (key-based)                            |
| VirtIO-fs    | nutellajunkies → /mnt/nutellajunkies        |

This VM uses a cloud image with Proxmox cloud-init for IP configuration and SSH keys. A ZFS dataset (`tank3/data/nutellajunkies`) is shared into the VM via VirtIO filesystem passthrough and auto-mounted at `/mnt/nutellajunkies` via cloud-init vendor-data. Guest NIC is `eth0`. All settings verified working. See [`unsereiner.net/proxmox-vm101-nutellajunkies.md`](../unsereiner.net/proxmox-vm101-nutellajunkies.md) for full details.

The VM is **not reachable** from the management network (192.168.1.x) — only from the 192.168.178.x network.

## Assigning Additional VMs to a VM Network

In the Proxmox web UI:

1. Select the VM
2. Go to **Hardware** > **Network Device**
3. Set **Bridge** to the appropriate bridge:
   - `vmbr1` for the 192.168.0.0/24 network (gateway 192.168.0.1)
   - `vmbr2` for the 192.168.178.0/24 network (gateway 192.168.178.1)
4. Inside the VM, configure its IP on the chosen subnet with the corresponding gateway
