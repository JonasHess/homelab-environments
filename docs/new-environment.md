# Adding a new environment

This guide walks through creating a new homelab environment from scratch.
The concrete examples use `hess.pm` as the reference and show what the
equivalent would look like for a new environment named `raspi.zimmermann.lat`.

---

## Prerequisites

Before you start, you need:

| Requirement | Notes |
|---|---|
| Kubernetes cluster running | MicroK8s / Kind / kubeadm; `kubectl` context pointing at it |
| MetalLB installed | L2 mode; an IP range reserved for LoadBalancer services |
| `kubectl`, `helm`, `yq` on your workstation | `yq` ≥ 4.x (mikefarah) |
| Akeyless account + API key | `AKEYLESS_ACCESS_ID`, `AKEYLESS_ACCESS_TYPE_PARAM` env vars set |
| Cloudflare account managing the domain | Zone already exists in Cloudflare |
| `openssl` available locally | For generating the mTLS CA cert |

---

## Step 1 — Create the environment directory and `values.yaml`

```bash
mkdir homelab-environments/<env>
```

**`hess.pm` example → `raspi.zimmermann.lat` mapping:**

| `hess.pm` | `raspi.zimmermann.lat` |
|---|---|
| `global.domain: hess.pm` | `global.domain: raspi.zimmermann.lat` |
| `global.akeyless.path: /hess.pm` | `global.akeyless.path: /raspi.zimmermann.lat` |
| `global.cluster.serverip: 192.168.1.3` | your cluster node IP |
| `global.cluster.ip-range: 192.168.1.80-192.168.1.90` | your MetalLB range |
| `global.gateway.loadBalancerIP: 192.168.1.80` | first IP in your MetalLB range |
| `global.oidc.cookieDomain: hess.pm` | `raspi.zimmermann.lat` |
| `global.security.cloudflareOriginCA` | generate fresh (Step 3 below) |

Minimal `values.yaml` template — fill in every `<placeholder>`:

```yaml
global:
  cluster:
    serverip: <node-ip>
    username: root
    cluster-name: <env>          # e.g. raspi.zimmermann.lat
    ip-range: <metallb-range>    # e.g. 192.168.x.80-192.168.x.90

  domain: <env>                  # e.g. raspi.zimmermann.lat

  akeyless:
    path: /<env>                 # e.g. /raspi.zimmermann.lat

  email: <your-email>
  cloudflare:
    email: <your-cloudflare-email>
  letsencrypt:
    email: <your-email>

  oidc:
    issuerUrl: "https://cognito-idp.eu-central-1.amazonaws.com/eu-central-1_t9DQfKlSX"
    clientId: "6e1bl5i55ao7bhhcufk85ussm"
    cookieDomain: "<env>"        # e.g. raspi.zimmermann.lat
    # Keep pointing at the old Akeyless path until you decide to rename it.
    clientSecretAkeylessPath: /oidc/oauth2-proxy/client_secret

  # Gateway LoadBalancer IP (MetalLB assigns this to the Envoy proxy Service).
  # Single source of truth — also used by samba avahi and the lanDnsCheck probe.
  gateway:
    loadBalancerIP: <first-metallb-ip>   # e.g. 192.168.x.80

  # Two ways into the Gateway:
  #   1. LAN clients hit :443 directly (internal DNS resolves *.<env> → loadBalancerIP).
  #   2. Cloudflare-proxied requests → mTLS listener (port 4443).
  security:
    # PEM of the CA cert generated in Step 3. Public info — safe to commit.
    cloudflareOriginCA: |
      -----BEGIN CERTIFICATE-----
      <paste ca.crt content here>
      -----END CERTIFICATE-----

  argocd:
    targetRevision: main

  # Optional: fires LanInternalDnsBroken alert if internal DNS stops resolving
  # *.<env> → loadBalancerIP. Set dnsServer to your internal DNS server IP.
  # Remove this block entirely to disable.
  # lanDnsCheck:
  #   dnsServer: "<internal-dns-ip>"    # e.g. AdGuard/Pi-hole IP
  #   queryName: "argocd.<env>"

apps:
  argocd:
    enabled: true
    argocd:
      targetRevision: ~
      helm:
        values: {}

  akeyless:
    enabled: true
    argocd:
      targetRevision: ~
      helm:
        values: {}

  envoy-gateway:
    enabled: true
    argocd:
      targetRevision: ~
      helm:
        values:
          additionalExposedPorts:
            # Null out listeners for apps not deployed in this env, e.g.:
            sftpgo: null
            ftp: null
            dns: null
            samba: null

  cert-manager:
    enabled: true
    argocd:
      targetRevision: ~
      helm: {}

  homer:
    enabled: true
    argocd:
      targetRevision: ~
      helm:
        values: {}

  reloader:
    enabled: true
    argocd:
      targetRevision: ~
      helm:
        values: {}
```

> Add more apps from `base-chart/values.yaml` as needed; enable each with
> `enabled: true` and supply the required `pvcMounts.hostPath` values.

---

## Step 2 — Create Akeyless secrets

Every environment needs a **minimum of two secrets** in Akeyless under its
own path prefix (`/<env>/...`).

### 2a. OIDC client secret

The Cognito app client is shared across all environments (same user pool,
same client ID). Copy the value from an existing environment.

```
Akeyless path:  /<env>/oidc/oauth2-proxy/client_secret
Value:          <cognito-app-client-secret>
```

**Example for raspi.zimmermann.lat:**
```
/raspi.zimmermann.lat/oidc/oauth2-proxy/client_secret
```

To look up the value from the existing hess.pm secret:
```bash
akeyless get-secret-value --name "/hess.pm/oidc/oauth2-proxy/client_secret"
```

### 2b. ArgoCD GitHub webhook secret

A random string ArgoCD uses to verify GitHub webhook payloads.

```
Akeyless path:  /<env>/argocd/webhook/github/secret
Value:          <random-string>    # e.g. openssl rand -hex 32
```

### 2c. App-specific secrets

Add these only for apps you enable. Common ones:

| App | Akeyless path | Notes |
|---|---|---|
| `cert-manager` | `/<env>/cloudflare/dns-api-token` | Cloudflare API token with `Zone:DNS:Edit` for DNS-01 challenge |
| `samba` | `/<env>/samba/password-<username>` | One per user |
| `sftpgo` | `/<env>/sftpgo/...` | See `apps/sftpgo/templates/` |

---

## Step 3 — Generate the Cloudflare mTLS certificate pair

Run these commands **once per environment** (each env gets its own CA):

```bash
# Generate a self-signed CA (valid 10 years)
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -subj "/CN=<env> Origin CA" \
  -keyout ca.key -out ca.crt

# Generate a leaf cert signed by the CA (presented by Cloudflare to Envoy)
openssl req -new -newkey rsa:2048 -nodes \
  -subj "/CN=cloudflare-origin" \
  -keyout leaf.key -out leaf.csr
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -out leaf.crt \
  -extfile <(printf "extendedKeyUsage=clientAuth")
```

**What to do with each file:**

| File | Where it goes |
|---|---|
| `ca.crt` | Paste into `global.security.cloudflareOriginCA` in `values.yaml` |
| `leaf.crt` + `leaf.key` | Upload to Cloudflare (Step 4) |
| `ca.key` | **Keep secret, never commit.** Store in a password manager. |
| `leaf.csr` | Discard |

> Verify you have the leaf (not the CA) before uploading:
> `openssl x509 -in leaf.crt -noout -subject` should show `CN=cloudflare-origin`.

---

## Step 4 — Cloudflare setup

### 4a. DNS records

Create an `A` record pointing the wildcard and apex to your **router's WAN IP**
(for the Cloudflare-proxied path). Cloudflare proxies this to your gateway.

```
Type   Name                   Value               Proxy
A      *.<env>                <WAN-IP>            Proxied (orange cloud)
A      <env>                  <WAN-IP>            Proxied (orange cloud)
```

**Example for raspi.zimmermann.lat:**
```
A   *.raspi.zimmermann.lat   <WAN-IP>   Proxied
A   raspi.zimmermann.lat     <WAN-IP>   Proxied
```

### 4b. Upload the Authenticated Origin Pulls (AOP) certificate

Cloudflare → your zone → **SSL/TLS → Origin Server → Authenticated Origin Pulls**.

1. Switch to **Per-Hostname** authentication.
2. Click **Upload Certificate**.
3. Paste the contents of `leaf.crt` into "Certificate" and `leaf.key` into "Private Key".
4. Enable the rule for `*.<env>` (wildcard hostname match).

This causes Cloudflare to present `leaf.crt` as a client certificate when
connecting to your origin. Envoy validates it against `ca.crt` and rejects
anything else on the `:4443` listener.

### 4c. Router NAT rule

Forward `WAN:443 → <gateway-loadBalancerIP>:4443` on your router.
The `:443` LAN listener is reached directly via internal DNS and is **not**
exposed through Cloudflare.

```
# Example: hess.pm
WAN 443/TCP  →  192.168.1.80:4443
```

---

## Step 5 — Internal DNS

LAN clients must resolve `*.<env>` (and `<env>`) to `global.gateway.loadBalancerIP`.
Configure your internal DNS server (AdGuard, Pi-hole, router DHCP) with a
rewrite rule:

```
*.<env>  →  <loadBalancerIP>
<env>    →  <loadBalancerIP>
```

**Example for raspi.zimmermann.lat with LB IP 192.168.x.80:**
```
*.raspi.zimmermann.lat  →  192.168.x.80
raspi.zimmermann.lat    →  192.168.x.80
```

Without this, LAN traffic hairpins out through Cloudflare (slower, and LAN
access dies if the internet is down). If you enable `global.lanDnsCheck`, the
`LanInternalDnsBroken` Prometheus alert will fire if this breaks.

---

## Step 6 — Bootstrap ArgoCD

```bash
cd homelab-iac

export AKEYLESS_ACCESS_ID="<your-akeyless-access-id>"
export AKEYLESS_ACCESS_TYPE_PARAM="<your-akeyless-api-key>"

./scripts/setup.sh \
  https://github.com/JonasHess/homelab-environments.git \
  main \
  <env>/values.yaml
```

**Example for raspi.zimmermann.lat:**
```bash
./scripts/setup.sh \
  https://github.com/JonasHess/homelab-environments.git \
  main \
  raspi.zimmermann.lat/values.yaml
```

The script will:
1. Clone the environments repo
2. Create the `akeyless-secret-creds` Kubernetes secret
3. Install ArgoCD via Helm
4. Install the bootstrap chart (which creates the base ArgoCD `Application`)
5. Print the initial admin password

After it completes, restart the ArgoCD server once (the script reminds you):
```bash
kubectl rollout restart deployment argocd-server -n argocd
```

Then open the ArgoCD UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  — admin / <printed password>
```

---

## Step 7 — First-sync order

ArgoCD deploys in sync-wave order. The first sync installs the waves in sequence:

| Wave | Apps | Why first |
|---|---|---|
| 0 | ArgoCD itself | GitOps controller |
| 1 | envoy-gateway, cert-manager, reloader | Ingress + TLS before anything needs them |
| 2 | prometheus, crossplane | Monitoring + infra |
| 3–5 | adguard, akeyless, postgres | DNS + secrets + DB |
| 10+ | Application layer | All other apps |

The `envoy-gateway-controller` child ArgoCD Application sometimes needs an
explicit sync on first deploy (a Helm certgen hook timing issue):

```bash
kubectl -n argocd patch application envoy-gateway-controller \
  --type merge -p '{"operation":{"sync":{}}}'
```

Within ~30 s the certgen Job fires, the controller starts, and the Gateway
comes up.

---

## Step 8 — Verify

```bash
# Gateway listeners are programmed
kubectl get gateway -n argocd envoy-gateway

# Wildcard cert issued
kubectl get certificate -n argocd

# ArgoCD accessible via its subdomain
curl -k https://argocd.<env>/

# Check Prometheus alert is not firing (if lanDnsCheck enabled)
# → should show no active LanInternalDnsBroken alerts
```