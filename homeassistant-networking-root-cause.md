# Home Assistant Networking — Root Cause Analysis

Date: 2026-02-15
Status: **root cause narrowed — HA process corrupts pod's network state**

## Summary

~40-50% of TCP connections from the HA pod fail with `ENETUNREACH` (errno 101). The issue is **specific to the HA pod** — an identical Python 3.13 debug pod on the same node works 100%. The kernel's FIB routing is correct (verified via raw netlink: 100/100 unicast), but `connect()` still fails intermittently. Something the running Home Assistant process does corrupts the pod's networking for ALL processes sharing that network namespace.

## Key findings

### 1. The problem is HA-process-specific, not infrastructure

| Test target | HA pod | Debug pod (python:3.13-alpine) |
|---|---|---|
| Non-blocking `connect()` (30 tries) | ~50% ERR101 | **30/30 EINPROGRESS (100%)** |
| Same Python version | 3.13.11 | 3.13.x |
| Same node | nutellajunkies | nutellajunkies |
| Same Calico CNI | yes | yes |
| Same kernel | yes | yes |

### 2. Fresh HA pod works, then degrades

The pod was restarted during investigation. Immediately after restart:
```
Non-blocking connect to 192.168.178.159:80: ['EINPROGRESS(ok)' x5]  ← 5/5 success
Non-blocking connect to 8.8.8.8:443:      ['EINPROGRESS(ok)' x3]  ← 3/3 success
```

Minutes later, once HA had fully started, connects began failing intermittently.

### 3. Failures oscillate in ~5-8 second blocks, no ARP correlation

60-second test (1 connect/sec), HA pod:
```
idx | arp_state | result
  0 | REACHABLE | ERR101        ← ARP fine, connect fails
  2 | REACHABLE | EINPROGRESS   ← same ARP, connect works
  8 | REACHABLE | ERR101
 22 | REACHABLE | ERR101
 24 | REACHABLE | EINPROGRESS
 37 | STALE     | EINPROGRESS   ← ARP stale, connect works
 43 | REACHABLE | ERR101        ← ARP fresh, connect fails
```

### 4. ALL programs fail, not just Python

Side-by-side test (30 iterations, alternating Python and curl):
```
idx | py_result   | curl_result
  0 | EINPROGRESS | HTTP200
  4 | ERR101      | HTTP200
  6 | ERR101      | HTTP000      ← curl ALSO fails
 11 | EINPROGRESS | HTTP000      ← Python works, curl fails
 14 | EINPROGRESS | HTTP000
 21 | ERR101      | HTTP000
 25 | EINPROGRESS | HTTP200
```

Both Python and curl fail ~50%, independently. This is NOT a Python bug.

### 5. Kernel route lookup is correct (verified via raw netlink)

```python
# Raw netlink RTM_GETROUTE query from inside the HA pod:
# RTN_UNICAST=1, RTN_BROADCAST=3
Results over 100 route lookups for 192.168.178.159:
  unicast:   100
  broadcast: 0
```

The kernel's FIB always returns unicast. The `connect()` failure happens AFTER the route lookup.

Note: BusyBox `ip route get` intermittently displays "broadcast" — this is a **BusyBox display bug** (BusyBox's `ip` likely calls `connect()` internally and misinterprets the ENETUNREACH).

### 6. Host-side networking is clean

Verified from calico-node pod (host network namespace):

| Check | Result |
|---|---|
| Host `ip route get 192.168.178.159` | Always unicast (5/5) |
| Host local routing table | Only `broadcast 192.168.178.255` (correct /24) |
| iptables REJECT rules | Only 1 for unrelated backrest service |
| nftables | FORWARD accepts all 10.1.0.0/16, policy accept |
| Calico iptables chains | All ACCEPT, 0 drops, profiles allow all egress |
| NetworkPolicies | Zero in any namespace |
| Calico GlobalNetworkPolicies | Zero |
| Calico BPF dataplane | Not enabled |
| conntrack | 349/131072, no entries for 192.168.178.159 |

### 7. Pod namespace is clean

| Check | Result |
|---|---|
| iptables tables inside pod | None (`/proc/net/ip_tables_names` empty) |
| xfrm (IPsec) policies | None (BusyBox doesn't support xfrm, but no state) |
| conntrack inside pod | Not available (no netfilter tables) |
| IP addresses | Only 10.1.63.144/32 on eth0 (no modifications) |
| Routes | Only default via 169.254.1.1 (no modifications) |
| Local routing table | No broadcast entry for 192.168.178.x |

## What IS different about the HA pod

| | HA pod | Debug pod |
|---|---|---|
| Processes | s6-svscan, homeassistant (Python 3.13), go2rtc | sleep 3600 |
| TCP sockets | 2 LISTEN (8123, 18554), 2 LISTEN on IPv6 | 0 |
| UDP sockets | 3 (mDNS 5353, SSDP 1900, go2rtc) | 0 |
| UDP6 sockets | 4 (mDNS x2, SSDP, go2rtc) | 0 |
| IGMP groups | 239.255.255.250 (SSDP), 224.0.0.251 (mDNS), 224.0.0.1 | none |
| IPv6 multicast | ff02::c (SSDP), ff02::fb (mDNS), solicited-node | none |
| TCP alloc | ~148-165 | ~163 |
| Active connections | Constant retries to CCU3, DNS, weather, pypi | none |

The HA process has:
- **mDNS** (Zeroconf) bound on port 5353, joined IGMP group 224.0.0.251
- **SSDP** bound on port 1900, joined IGMP group 239.255.255.250
- **go2rtc** with local/IPv6 listeners
- **Constant failing connection attempts** to HomeMatic, DNS, weather APIs, pypi

## Kernel-level mechanism (confirmed)

### The RTCF_BROADCAST flag in tcp_v4_connect()

In `tcp_v4_connect()`, after a successful route lookup, the kernel checks:

```c
if (rt->rt_flags & (RTCF_MULTICAST | RTCF_BROADCAST)) {
    ip_rt_put(rt);
    return -ENETUNREACH;  // no OutNoRoutes increment!
}
```

**Evidence:**
- 50 connects: 34 succeeded, 16 failed
- iptables MARK counter: +34 (exactly matching successes — failed connects send NO SYN)
- **`OutNoRoutes` stayed at ZERO** — the FIB lookup succeeds, but the resolved `struct rtable` intermittently has `RTCF_BROADCAST` set
- `InBcastPkts: +34`, `OutBcastPkts: +34` during the test — the pod actively sends/receives broadcast traffic (SSDP/mDNS)

The route lookup (FIB) always returns RTN_UNICAST (confirmed via raw netlink: 100/100). But the subsequent `__mkroute_output()` step, which resolves the route into a `struct rtable`, intermittently sets the RTCF_BROADCAST flag. This flag causes `tcp_v4_connect()` to return ENETUNREACH without even sending a SYN packet.

### Why the broadcast flag gets set

The HA pod's SSDP (239.255.255.250) and mDNS (224.0.0.251) activity creates broadcast/multicast route entries in the kernel's per-destination route cache. On a Calico pod with /32 addressing behind proxy ARP, the interaction between:
- Incoming broadcast packets from the LAN (via veth)
- Outgoing multicast from HA's Zeroconf/SSDP discovery
- The pod's unusual /32 + proxy ARP routing setup

...causes the kernel to intermittently flag unicast destinations in the 192.168.178.0/24 range as broadcast.

The debug pod (no mDNS, no SSDP, no broadcast traffic) has a clean route cache and works 100%.

## Hypotheses for broadcast contamination (ranked)

### 1. SSDP/mDNS broadcast traffic contaminates route cache (partially ruled out)

Joining SSDP+mDNS multicast groups and sending discovery packets from a clean debug pod did NOT reproduce the issue (30/30 success before and after). Multicast alone is not sufficient — it requires **the combination** of multicast + HA's rapid failed TCP connection storm + the /32 Calico setup.

### 2. HA's failed connection storm + multicast contamination (most likely)

HA continuously retries connections to many unreachable endpoints (DNS, CCU3, pypi, weather, alerts). Each failed TCP connect generates kernel state. Combined with active multicast/broadcast traffic, the kernel's per-destination route cache entries may get the RTCF_BROADCAST flag applied to unicast routes.

**Evidence for:** Fresh pod works → degrades after HA starts retrying; oscillating 5-8s pattern matches HA retry bursts; OutNoRoutes=0 confirms RTCF_BROADCAST path.

### 3. LAN broadcast leaking through veth

The host receives LAN broadcast traffic (ARP, DHCP, SSDP) on eth0. Some of this may leak into the pod via the veth, causing the pod's kernel to create broadcast route entries for 192.168.178.x addresses. These cached entries then affect outgoing TCP connects.

**Evidence for:** 470+ InBcastPkts received by the pod; oscillating failure pattern matches periodic LAN broadcast activity.

### 3. Kernel bug in /32 interface broadcast detection

On a /32 interface, the kernel's broadcast address detection in `__mkroute_output()` may be buggy. A /32 has no subnet broadcast address, but the kernel may derive one incorrectly when processing routes through the proxy ARP gateway (169.254.1.1).

## What has been ruled out

| Hypothesis | Evidence |
|---|---|
| NetworkPolicies | Zero policies anywhere |
| Calico iptables | All egress accepted, 0 drops |
| Calico BPF mode | Not enabled, no connect-time hooks |
| ARP cache state | No correlation (fails with REACHABLE) |
| Python 3.13 bug | curl and bash also fail; debug pod with Python 3.13 works 100% |
| DNS resolution | Tests use numeric IPs |
| conntrack exhaustion | 349/131072 |
| xfrm/IPsec | No policies |
| Pod iptables/nftables | No tables inside pod |
| Kernel route lookup | Raw netlink returns unicast 100/100 |
| Host-side routing | Always correct from host namespace |
| BusyBox broadcast display | Confirmed as BusyBox display bug |
| Resource exhaustion | All limits fine |

## Recommended fix: `hostNetwork: true`

Given the complexity of the root cause (somewhere in the kernel's TCP connect path, triggered by the HA process's network activity), the most reliable fix is **bypassing the pod overlay entirely**:

```yaml
# In generic chart deployment.yaml, add to pod spec:
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
```

This eliminates:
- The veth pair and Calico proxy ARP
- The /32 pod addressing with synthetic gateway
- Any interaction between the pod network namespace and HA's multicast/connection behavior

**Pros:** Reliable networking, enables mDNS/SSDP device discovery on LAN
**Cons:** Port 8123 binds on node IP, shared namespace with host

## Investigation still in progress

- [x] Check iptables packet counters before/after failed connect — **confirmed: failed connects produce zero packets**
- [x] Verify `OutNoRoutes` kernel counter — **confirmed: stays at zero, ruling out FIB failure**
- [ ] Inspect cgroup BPF programs (`sd_fw_egress`/`sd_fw_ingress`) attached to HA vs debug pod cgroups
- [x] Create debug pod with SSDP+mDNS multicast — **multicast alone does NOT reproduce (30/30 ok)**
- [ ] Simulate HA's failed connection storm + multicast in debug pod to reproduce
- [ ] Check kernel version and search for known bugs with /32 + multicast + RTCF_BROADCAST

## Cleanup

Debug pods still running:
```bash
kubectl --context unsereiner.net -n argocd delete pod netdebug netdebug2
```

## Related files

- [`homeassistant-networking-debug.md`](homeassistant-networking-debug.md) — Full investigation log with infrastructure diagram and workaround attempts
- [`unsereiner.net/values.yaml`](unsereiner.net/values.yaml) — Cluster deployment values (homeassistant at lines 74-128)
- [`docs/proxmox-network-setup.md`](docs/proxmox-network-setup.md) — Proxmox network topology (3 bridges, VM 101 on vmbr2)
