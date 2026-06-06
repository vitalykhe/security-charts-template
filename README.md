# Security Charts

Reusable Helm charts for cluster security infrastructure.

## Charts

| Chart | Description |
|---|---|
| `crowdsec-firewall-bouncer` | CrowdSec bouncer that bans IPs via iptables/nftables at the node level |

## Usage

### Directly from Git (ArgoCD)

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
        existingSecret:
          name: crowdsec-firewall-bouncer-key
          key: api-key
```

### From OCI registry (GHCR)

```bash
helm pull oci://ghcr.io/vitalykhe/helm-charts/crowdsec-firewall-bouncer \
  --version 0.1.0
```

### Bootstrap the API key

After deploying CrowdSec LAPI, register the bouncer:

```bash
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- \
  cscli bouncers add firewall-bouncer
# ^ returns an API key

kubectl -n crowdsec create secret generic crowdsec-firewall-bouncer-key \
  --from-literal=api-key='<KEY>'
```

## Development

```bash
helm lint charts/crowdsec-firewall-bouncer/
```
