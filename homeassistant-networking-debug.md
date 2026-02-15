# Home Assistant Networking Issue

Date: 2026-02-14
Status: **investigation in progress**

## Problem

Home Assistant cannot reach LAN devices or the internet reliably. All outbound TCP connections intermittently fail with errno 101 (ENETUNREACH).

Affected services at startup:
- **HomeMatic CCU3** (`192.168.178.159`) — JSON-RPC login, XML-RPC, all ports
- **github.com** — HACS downloads
- **pypi.org** — package installation
- **alerts.home-assistant.io** — HA alerts
- **met.no** — weather integration
- **DNS** — cluster DNS (10.152.183.10) timeouts

Full error log excerpt:
```
ERROR [aiohomematic.client.json_rpc] Session.login err=ClientConnectorError:
  OSError(101, 'Network unreachable') url="http://192.168.178.159:80/api/homematic.cgi"
ERROR [aiohomematic.client.json_rpc] Session.login err=ClientConnectorError:
  OSError(101, 'Network unreachable') url="https://192.168.178.159:443/api/homematic.cgi"
ERROR [homeassistant] Error doing job: Unclosed client session (task: None)
ERROR [aiohomematic.client.rpc_proxy] system.listMethods err=OSError: (101, 'Network unreachable')
  interface_id="temporary_instance-HmIP-RF"
ERROR [aiohomematic.central.central_unit] VALIDATE_CONFIG_AND_GET_SYSTEM_INFORMATION fehlgeschlagen
  für Client HmIP-RF: (101, 'Network unreachable')
ERROR [homeassistant.util.package] Unable to install package aiohomematic==2026.2.0:
  Network unreachable (os error 101) — https://pypi.org/simple/aiohomematic/
ERROR [homeassistant.components.homeassistant_alerts.coordinator]
  Cannot connect to host alerts.home-assistant.io:443 — Network unreachable
```

## Infrastructure

```
┌───────────────────────────────────────────────────────────────────────┐
│                    Proxmox Host (192.168.1.2)                         │
│                                                                       │
│  vmbr2 (192.168.178.0/24 LAN)                                        │
│     │ nic0 (Intel 82576)                                              │
│     │                                                                 │
│  ┌──┴──────────────────────────────────────────────────────────────┐  │
│  │  VM 101: nutellajunkies (192.168.178.101)                       │  │
│  │  Ubuntu 24.04 / MicroK8s v1.34.3 / single-node cluster         │  │
│  │                                                                  │  │
│  │  Calico CNI (VXLAN, MTU 1450)                                   │  │
│  │  Pod CIDR: 10.1.63.0/24 — Service CIDR: 10.152.183.0/24        │  │
│  │  MetalLB LB IP: 192.168.178.191                                 │  │
│  │                                                                  │  │
│  │  ┌──────────────────────────────────────────┐                   │  │
│  │  │  HA Pod (10.1.63.136/32)                  │                   │  │
│  │  │  eth0 → veth (Calico)                     │                   │  │
│  │  │  gw: 169.254.1.1 (proxy ARP ee:ee:ee:ee)  │                   │  │
│  │  │  → host iptables MASQUERADE → eth0         │                   │  │
│  │  └──────────────────────────────────────────┘                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  Physical LAN: 192.168.178.0/24                                       │
│     └── CCU3 at 192.168.178.159 (ports 80, 2000, 2001, 2010, 9292)   │
└───────────────────────────────────────────────────────────────────────┘
```

- **Image**: `ghcr.io/home-assistant/home-assistant:2026.2.2` (Alpine 3.22, musl, Python 3.13)
- **hostNetwork**: false
- **dnsPolicy**: ClusterFirst
- **Network policies**: none
- **Capabilities**: NET_RAW (yes), NET_ADMIN (no)
- **CCU3**: all ports verified open and responding from debug pod

## Root Cause: Non-blocking connect() fails in HA pod's network namespace

### Key finding: the problem is pod-specific, not cluster-wide

A `nicolaka/netshoot` debug pod in the same namespace with identical Calico networking (same /32, same routes, same proxy ARP) has **zero failures** — even with 10 simultaneous aiohttp connections.

| Test | HA pod | Debug pod |
|------|--------|-----------|
| `ping 192.168.178.159` | Always works | Always works |
| `curl http://192.168.178.159` | Fails (new image) | Always works |
| `socket(AF_INET).connect()` blocking | Sometimes works | Always works |
| `socket(AF_INET).setblocking(False).connect()` | **Always fails (errno 101)** | **Always works (EINPROGRESS → OK)** |
| aiohttp 10x sequential (1s apart) | ~60% fail | 10/10 OK |
| aiohttp 10x simultaneous | **10/10 FAIL** | **10/10 OK** |
| `socket.create_connection()` | Usually works | Always works |

### The non-blocking connect divergence

This is the critical finding. Both pods use AF_INET, same kernel, same Calico:

**HA pod** (Python 3.13, Alpine 3.22):
```python
s = socket.socket(AF_INET, SOCK_STREAM)
s.setblocking(False)
s.connect(('192.168.178.159', 80))
# → OSError: [Errno 101] Network unreachable  (immediate, 10/10 times)
```

**Debug pod** (Python 3.12, Alpine-based netshoot):
```python
s = socket.socket(AF_INET, SOCK_STREAM)
s.setblocking(False)
s.connect(('192.168.178.159', 80))
# → BlockingIOError (EINPROGRESS) → select writable → SO_ERROR=0 (OK, 10/10 times)
```

The kernel returns ENETUNREACH immediately in the HA pod but returns EINPROGRESS (normal non-blocking behavior) in the debug pod, for the **exact same syscall on the same node**.

### What does NOT explain it

- **ARP state**: tested with REACHABLE, STALE, and empty neighbor cache — debug pod always works, HA pod always fails
- **IPv6**: forced `family=AF_INET` — still fails in HA pod
- **musl vs glibc**: both pods use musl-compiled Python
- **aiohttp version**: both 3.13.3 with aiohappyeyeballs 2.6.1
- **sysctl settings**: `/proc/sys/net/ipv4/neigh/eth0/*` identical in both pods
- **Socket options**: SO_MARK, SO_BINDTODEVICE, IP_FREEBIND — all default in both
- **LD_PRELOAD**: not set
- **iptables/nftables**: no tools installed, no rules visible
- **Resource exhaustion**: conntrack 0/131072, TCP alloc 165, only 2 active connections
- **Environment**: no HTTP_PROXY or similar set

### What IS different

| | HA pod | Debug pod |
|---|---|---|
| Python | 3.13.11 | 3.12.12 |
| Running processes | s6-svscan, homeassistant, go2rtc | sleep 3600 |
| TCP sockets used | 2 inuse, 165 alloc | 0 inuse, 163 alloc |
| UDP6 sockets | 4 inuse | 0 |
| Container image | ghcr.io/home-assistant/home-assistant:2026.2.2 | nicolaka/netshoot |

### Open questions

1. **Is it the HA process?** — The HA process (python3 -m homeassistant) and go2rtc are running concurrently. They may be affecting the network namespace state in a way that causes `connect()` to fail. Maybe a large number of failed connections has poisoned some kernel state in this network namespace.
2. **Is it Python 3.13?** — Python 3.13 changed socket internals. The debug pod uses 3.12. Could be a regression.
3. **Is it a Calico per-pod state issue?** — Calico maintains per-pod iptables/routing rules on the host side. Something specific to the HA pod's host-side rules might be wrong.

## Workarounds tested

| Approach | Result |
|----------|--------|
| ARP keepalive (ping gateway every 5s) | Partial — reduced failures but did not eliminate them |
| `ip neigh replace` to permanent | Failed — BusyBox `ip` doesn't support `replace`/`change` |
| Sysctl tuning (gc_stale_time, base_reachable_time) | Failed — `/proc/sys` is read-only in container |
| Force `aiohttp.TCPConnector(family=AF_INET)` | Still fails in HA pod |

## Possible solutions

### 1. hostNetwork: true (most reliable, not yet approved)

Bypasses Calico entirely. Pod uses node's network stack directly.

Changes needed:
1. Add `hostNetwork` and `dnsPolicy` support to generic chart `deployment.yaml`:
   ```yaml
   {{- if $deployment.hostNetwork }}
   hostNetwork: {{ $deployment.hostNetwork }}
   {{- end }}
   {{- if $deployment.dnsPolicy }}
   dnsPolicy: {{ $deployment.dnsPolicy }}
   {{- end }}
   ```
2. In homeassistant values, add:
   ```yaml
   hostNetwork: true
   dnsPolicy: ClusterFirstWithHostNet
   ```

**Pros**: Eliminates the entire Calico overlay issue, enables mDNS/SSDP discovery
**Cons**: Port 8123 binds on node IP, shared network namespace with host

### 2. Restart the pod (investigate if it's stale kernel state)

If the HA process or a previous connection burst has corrupted kernel state in the pod's network namespace, a fresh pod might work. Worth testing.

### 3. Add NET_ADMIN capability + init container

Use an init container with `iproute2` and NET_ADMIN to set the ARP entry to permanent:
```yaml
securityContext:
  capabilities:
    add: ["NET_ADMIN"]
```
```bash
ip neigh replace 169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee nud permanent
```

### 4. Pod-level sysctl for IPv6 disable

Add to pod spec to prevent any IPv6 socket attempts:
```yaml
securityContext:
  sysctls:
  - name: net.ipv6.conf.all.disable_ipv6
    value: "1"
```
Only addresses the BusyBox wget symptom, not the core non-blocking connect failure.

### 5. Investigate Calico host-side rules for this specific pod

Debug from the node itself (requires SSH to nutellajunkies VM) to check:
- iptables rules specific to this pod's veth
- conntrack entries for this pod's traffic
- Whether the host-side proxy ARP is functioning correctly

## Next steps

1. **Try restarting the pod** to see if a fresh network namespace fixes the issue
2. **SSH to the node** and inspect Calico's host-side iptables/routing for the HA pod's veth vs the debug pod's veth
3. **Test Python 3.13 vs 3.12** in a clean Alpine pod to rule out Python version regression

## Cleanup

Debug pod still running:
```bash
kubectl --context unsereiner.net -n argocd delete pod netdebug
```
