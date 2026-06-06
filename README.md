# Security Charts

Reusable Helm charts for cluster security infrastructure.

## Charts

| Chart | Description |
|---|---|
| `crowdsec-firewall-bouncer` | CrowdSec bouncer that bans IPs via iptables/nftables at the node level |

---

# crowdsec-firewall-bouncer

CrowdSec firewall bouncer blocks malicious IPs (`.env` scanners, `phpinfo` probes,
brute‑force bots, etc.) at the **node level** using iptables.

## Architecture

```text
Internet → ingress-nginx (DaemonSet, hostNetwork) → backend Pod
                │
                ▼ (attacker hits node directly)
         CrowdSec Agent (DaemonSet)
                │ reads ingress-nginx logs
                ▼
         CrowdSec LAPI (Service)
                │ alerts → decisions (ban)
                ▼
         CrowdSec Firewall Bouncer (DaemonSet, privileged)
                │ iptables DROP for banned source IPs
                ▼
         Attacker IP blocked at kernel level —
         no TCP handshake reaches nginx
```

1. **CrowdSec Agent** tails ingress-nginx container logs on each node.
2. Agent parses logs with the `crowdsecurity/nginx` collection and sends alerts to **LAPI**.
3. LAPI aggregates alerts and pushes **ban decisions** to connected bouncers.
4. **Firewall Bouncer** (DaemonSet) runs with `privileged: true` and adds `iptables DROP`
   rules for banned IPs. Because `ingress-nginx` runs with `hostNetwork`, blocked IPs
   never reach nginx — they are dropped in the `INPUT` chain.

## Prerequisites

| Requirement | Details |
|---|---|
| CrowdSec LAPI | Deployed in the same cluster (e.g. via `crowdsecurity/crowdsec` Helm chart) |
| Kubernetes Secret | `crowdsec-firewall-bouncer-key` with key `api-key` — holds the bouncer API key |
| Cluster node | `hostNetwork` for ingress-nginx (so iptables `INPUT` chain blocks before nginx) |

### GitHub Actions Secrets

If you use the bootstrap workflow, configure these secrets in your GitHub repo:

| Secret | Description |
|---|---|
| `KUBE_CONFIG_B64` | base64-encoded kubeconfig with access to the cluster and `crowdsec` namespace |

```bash
base64 < ~/.kube/config | tr -d '\n'
# Add the output as a repository Secret named KUBE_CONFIG_B64
```

## Bootstrap — Bouncer API Key

The bouncer needs an API key registered with the CrowdSec LAPI.
**Never store the key in Git.** Use one of the methods below.

### Option 1: GitHub Actions workflow (recommended)

Create a workflow in your consumer project (example: `.github/workflows/crowdsec-bootstrap.yml`):

```yaml
name: crowdsec-bootstrap
on: workflow_dispatch
permissions:
  contents: read
jobs:
  bootstrap:
    runs-on: ubuntu-latest
    env:
      KUBE_CONFIG_B64: ${{ secrets.KUBE_CONFIG_B64 }}
    steps:
      - uses: azure/setup-kubectl@v4

      - name: Write kubeconfig
        run: |
          install -m 700 -d "$HOME/.kube"
          printf '%s' "$KUBE_CONFIG_B64" | base64 -d > "$HOME/.kube/config"
          chmod 600 "$HOME/.kube/config"

      - name: Wait for LAPI
        run: |
          kubectl -n crowdsec wait --for=condition=ready pod \
            -l app.kubernetes.io/name=crowdsec-lapi --timeout=120s

      - name: Register or rotate bouncer key
        id: bouncer
        run: |
          LAPI_POD=$(kubectl -n crowdsec get pod \
            -l app.kubernetes.io/name=crowdsec-lapi -o jsonpath='{.items[0].metadata.name}')
          # Remove old bouncer if exists, then create fresh
          kubectl -n crowdsec exec "$LAPI_POD" -- cscli bouncers delete firewall-bouncer 2>/dev/null || true
          API_KEY=$(kubectl -n crowdsec exec "$LAPI_POD" -- cscli bouncers add firewall-bouncer -o raw)
          echo "::add-mask::$API_KEY"
          echo "api-key=$API_KEY" >> "$GITHUB_OUTPUT"

      - name: Create Kubernetes Secret
        run: |
          kubectl -n crowdsec create secret generic crowdsec-firewall-bouncer-key \
            --from-literal=api-key="${{ steps.bouncer.outputs.api-key }}" \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Restart bouncer DaemonSet
        run: |
          kubectl -n crowdsec rollout restart daemonset crowdsec-firewall-bouncer 2>/dev/null || true
```

Run it: **GitHub → Actions → crowdsec-bootstrap → Run workflow**

### Option 2: Manual (one-time)

```bash
# 1. Deploy CrowdSec LAPI first, then register the bouncer:
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- \
  cscli bouncers add firewall-bouncer
#    ^ copy the returned API key

# 2. Create the Kubernetes Secret:
kubectl -n crowdsec create secret generic crowdsec-firewall-bouncer-key \
  --from-literal=api-key='<KEY>'

# 3. Restart the bouncer to pick up the key:
kubectl -n crowdsec rollout restart daemonset crowdsec-firewall-bouncer
```

## Usage in ArgoCD

### From Git repository

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    repoURL: https://github.com/vitalykhe/security-charts.git
    path: charts/crowdsec-firewall-bouncer
    targetRevision: main
    helm:
      values: |
        config:
          apiUrl: "http://crowdsec-crowdsec-lapi.crowdsec:8080"
          backend: iptables
          updateFrequency: 10s
          denyAction: DROP
          denyLog: true
        existingSecret:
          name: crowdsec-firewall-bouncer-key
          key: api-key
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
```

### From OCI registry (GHCR)

Published on every push to `main`:

```bash
helm pull oci://ghcr.io/vitalykhe/security-charts/crowdsec-firewall-bouncer \
  --version 0.1.0
```

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `config.apiUrl` | `http://crowdsec-crowdsec-lapi.crowdsec:8080` | LAPI URL |
| `config.backend` | `iptables` | iptables or nftables |
| `config.updateFrequency` | `10s` | How often to pull decisions |
| `config.denyAction` | `DROP` | DROP or REJECT |
| `config.denyLog` | `true` | Log denied packets |
| `existingSecret.name` | `""` | K8s Secret name with `api-key` |
| `existingSecret.key` | `api-key` | Key in the Secret |
| `bouncerKey` | `change-me` | Inline key (dev only, not for production) |
| `resources` | see values.yaml | CPU/memory requests and limits |

## Verifying

```bash
# Pods
kubectl -n crowdsec get pods

# LAPI health
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- cscli metrics

# Active bans (scanner IPs appear here)
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- cscli decision list

# Bouncer registration
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- cscli bouncers list

# Firewall bouncer logs
kubectl -n crowdsec logs daemonset/crowdsec-firewall-bouncer --tail 20

# iptables rules (on the node, not inside a pod):
sudo iptables -L crowdsec-blacklists -n
```

## Testing

```bash
# Before ban — request reaches backend (200/404)
curl -s -o /dev/null -w "%{http_code}" https://your.domain/.env

# After CrowdSec bans the scanner IP — connection times out (iptables DROP)
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://your.domain/
```

## Development

```bash
helm lint charts/crowdsec-firewall-bouncer/
```
