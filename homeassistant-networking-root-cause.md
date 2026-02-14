# Home Assistant Networking — Root Cause Found

Date: 2026-02-15
Status: **root cause identified, fix pending**

## Root Cause: Kernel intermittently classifies destination as broadcast

The Linux kernel inside the HA pod **randomly returns `RTN_BROADCAST`** for route lookups to `192.168.178.159` (and likely all non-pod destinations). When a destination is classified as broadcast, TCP `connect()` fails immediately with `ENETUNREACH` (errno 101) because TCP connections to broadcast addresses are not allowed.

### Proof

Running `ip route get 192.168.178.159` five times in rapid succession inside the pod:

```
192.168.178.159 via 169.254.1.1 dev eth0  src 10.1.63.144       ← unicast (OK)
broadcast 192.168.178.159 via 169.254.1.1 dev eth0  src 10.1.63.144  ← BROADCAST (FAIL)
broadcast 192.168.178.159 via 169.254.1.1 dev eth0  src 10.1.63.144  ← BROADCAST (FAIL)
192.168.178.159 via 169.254.1.1 dev eth0  src 10.1.63.144       ← unicast (OK)
192.168.178.159 via 169.254.1.1 dev eth0  src 10.1.63.144       ← unicast (OK)
```

The route lookup is **non-deterministic** — identical queries return different route types. This directly correlates with the ~40-50% TCP connection failure rate observed in all tests.

### Correlation proof (60-second test, 1 connect/sec)

Non-blocking `connect()` results oscillate between success (`EINPROGRESS`) and failure (`ERR101`) in blocks of 4-8 seconds, independent of ARP neighbor cache state:

```
idx | arp_state | result
  0 | REACHABLE | ERR101        ← ARP is fine, connect fails
  2 | REACHABLE | EINPROGRESS   ← same ARP state, connect works
  8 | REACHABLE | ERR101        ← fails again
 22 | REACHABLE | ERR101
 24 | REACHABLE | EINPROGRESS
 37 | STALE     | EINPROGRESS   ← ARP stale but connect works
 43 | REACHABLE | ERR101        ← ARP fresh but connect fails
```

### What is NOT the cause

| Hypothesis | Status | Evidence |
|---|---|---|
| NetworkPolicies | Ruled out | Zero NetworkPolicies in any namespace |
| Calico iptables rules | Ruled out | All egress ACCEPTED, 0 drops, profiles allow all |
| Calico BPF dataplane | Ruled out | BPF mode not enabled, no connect-time BPF hooks |
| ARP cache state | Ruled out | Failures occur with ARP in REACHABLE state |
| Python 3.13 bug | Ruled out | curl (C/libcurl) and bash `/dev/tcp` also fail ~50% |
| DNS resolution | Ruled out | Tests use numeric IP, no DNS involved |
| conntrack exhaustion | Ruled out | 349/131072 entries, no entries for destination |
| Pod network namespace | Partially ruled out | Fresh pod works initially, degrades after HA starts |

### Affected components

**Everything using TCP from this pod** fails intermittently:
- Python `socket.connect()` (blocking and non-blocking)
- Python `ctypes` direct C `connect()` syscall
- bash `/dev/tcp`
- curl (~50% HTTP 000)
- All HA integrations (HomeMatic, weather, HACS, alerts, pip)

### Pod network configuration

```
eth0@if37: 10.1.63.144/32 (Calico /32 with proxy ARP)
Routes:
  default via 169.254.1.1 dev eth0
  169.254.1.1 dev eth0 scope link
No 192.168.178.x address assigned to any interface.
No broadcast entry for 192.168.178.159 in local routing table.
```

The local routing table contains only:
```
local 10.1.63.144 dev eth0
local 127.0.0.0/8 dev lo
local 127.0.0.1 dev lo
broadcast 127.255.255.255 dev lo
```

There is **no legitimate reason** for the kernel to classify 192.168.178.159 as broadcast.

## Likely mechanism

The host VM (`nutellajunkies`, 192.168.178.101) has eth0 on the `192.168.178.0/24` subnet. Its local routing table includes broadcast entries like `broadcast 192.168.178.255`.

Calico's VXLAN overlay or the veth pair's proxy ARP setup may be **leaking the host's routing table state into the pod's route lookup path**. When the kernel resolves the route for 192.168.178.159, it sometimes consults the host-side FIB (via the VXLAN datapath or veth internals) and gets a broadcast classification from a different routing context.

This would explain:
- Why it's intermittent (race condition between pod FIB and host FIB lookups)
- Why it oscillates in time blocks (caching of bad route decisions)
- Why a fresh pod works initially (clean FIB cache, no cross-contamination yet)
- Why the debug pod worked better (no active traffic to trigger the race)

## Next steps to confirm and fix

### Confirm from host side
```bash
# SSH to nutellajunkies or exec into calico-node pod:
ip route get 192.168.178.159                     # check host route type
ip route show table local | grep 192.168.178     # check host broadcast entries
ip -d link show type vxlan                        # check VXLAN config
bridge fdb show dev vxlan.calico | grep 192.168   # check VXLAN FDB
```

### Fix options (in order of preference)

1. **`hostNetwork: true`** — Bypasses Calico entirely. Pod uses host networking directly. Eliminates the veth/VXLAN route lookup issue completely. Requires chart changes (already documented in `homeassistant-networking-debug.md`).

2. **Move to a dedicated namespace** — While not a fix for the broadcast route issue, it isolates HA from ArgoCD and follows best practices.

3. **Investigate kernel/Calico version** — Check if this is a known bug in the kernel version (Ubuntu 24.04's kernel) or Calico version (MicroK8s v1.34.3's bundled Calico). Check Calico GitHub issues for VXLAN + broadcast route contamination.

4. **Switch Calico from VXLAN to direct routing** — If the VXLAN overlay is the source of the route contamination, switching to `ipipMode: Always` or direct routing (if on the same L2 segment) might fix it.

## Related files

- [`homeassistant-networking-debug.md`](homeassistant-networking-debug.md) — Full investigation log with infrastructure diagram, test matrix, and workaround attempts
- [`unsereiner.net/values.yaml`](unsereiner.net/values.yaml) — Cluster deployment values (homeassistant at lines 74-128)
