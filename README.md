# Security Charts

Reusable Helm charts for cluster security infrastructure.

## Charts

| Chart | Description |
|---|---|
| `crowdsec-firewall-bouncer` | CrowdSec bouncer — bans IPs via iptables/nftables at the node level |

---

# crowdsec-firewall-bouncer

Blocks malicious IPs (`.env` scanners, brute‑force bots, etc.) at the **node level** using iptables, before they reach nginx.

```text
                                    ┌──────────────────┐
                                    │   Internet       │
                                    │  (attacker IP)   │
                                    └────────┬─────────┘
                                             │
                                             ▼
                              ┌──────────────────────────┐
                              │  ingress-nginx            │
                              │  (DaemonSet, hostNetwork) │
                              └────────────┬─────────────┘
                                           │
                                   ┌───────▼────────┐
                                   │  backend Pod   │
                                   │  (HTTP 200/404)│
                                   └────────────────┘
                                             ▲
                                             │ attacker bypasses
                                             │ nginx → hits node IP
                                             │
        ┌─────────────────────┐    ┌─────────┴──────────┐    ┌──────────────────┐
        │  CrowdSec Agent     │    │  CrowdSec LAPI     │    │ Firewall Bouncer │
        │  (DaemonSet)        │───▶│  (Service)         │───▶│ (DaemonSet,      │
        │  reads nginx logs   │    │  alerts→decisions  │    │  privileged)     │
        └─────────────────────┘    └────────────────────┘    └────────┬─────────┘
                                                                      │
                                                                      ▼
                                                              ┌──────────────────┐
                                                              │  iptables DROP   │
                                                              │  INPUT chain     │
                                                              │  (kernel level)  │
                                                              └──────────────────┘
```

Requires: **CrowdSec LAPI** + **ingress-nginx with `hostNetwork`** + **Kubernetes Secret** with bouncer API key.

---

## Connecting to your GitOps

### 1. Add source repo to ArgoCD Project

Add `security-charts` to `sourceRepos` in your Project (e.g. `cluster-infra`):

```yaml
spec:
  sourceRepos:
    - https://github.com/vitalykhe/security-charts.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: crowdsec
```

### 2. Create ArgoCD Application

**From Git repository** (recommended):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crowdsec-firewall-bouncer
  namespace: argocd
spec:
  project: cluster-infra
  source:
    repoURL: https://github.com/vitalykhe/security-charts.git
    targetRevision: main
    path: charts/crowdsec-firewall-bouncer
    helm:
      values: |
        existingSecret:
          name: crowdsec-firewall-bouncer-key
          key: api-key
        config:
          apiUrl: "http://crowdsec-crowdsec-lapi.crowdsec:8080"
  destination:
    server: https://kubernetes.default.svc
    namespace: crowdsec
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**From OCI registry** (GHCR):

```yaml
source:
  repoURL: oci://ghcr.io/vitalykhe/security-charts/crowdsec-firewall-bouncer
  targetRevision: 0.1.0
```

### 3. Add `KUBE_CONFIG_B64` to GitHub Secrets

In **your GitOps repository**, create a GitHub Actions Secret:

```bash
base64 < ~/.kube/config | tr -d '\n'
```

| Secret | Description |
|---|---|
| `KUBE_CONFIG_B64` | base64-encoded kubeconfig with access to the cluster and `crowdsec` namespace |

### 4. Register bouncer & create API key Secret

**Option A — GitHub Actions (recommended).**  
Place this workflow in **your GitOps repo** (`.github/workflows/crowdsec-bootstrap.yml`):

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

**Option B — Manual (one-time):**

```bash
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- \
  cscli bouncers add firewall-bouncer
# copy the returned key

kubectl -n crowdsec create secret generic crowdsec-firewall-bouncer-key \
  --from-literal=api-key='<KEY>'

kubectl -n crowdsec rollout restart daemonset crowdsec-firewall-bouncer
```

### Plain Helm (without ArgoCD)

```bash
helm repo add security-charts oci://ghcr.io/vitalykhe/security-charts
helm upgrade --install crowdsec-firewall-bouncer \
  security-charts/crowdsec-firewall-bouncer \
  --namespace crowdsec --create-namespace \
  --set existingSecret.name=crowdsec-firewall-bouncer-key \
  --set existingSecret.key=api-key \
  --set config.apiUrl=http://crowdsec-crowdsec-lapi.crowdsec:8080
```

Or with a local values file:

```bash
helm upgrade --install crowdsec-firewall-bouncer \
  oci://ghcr.io/vitalykhe/security-charts/crowdsec-firewall-bouncer \
  --namespace crowdsec --create-namespace \
  -f my-values.yaml
```

### Configuration

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

### Verifying

```bash
kubectl -n crowdsec get pods
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- cscli bouncers list
kubectl -n crowdsec logs daemonset/crowdsec-firewall-bouncer --tail 20
sudo iptables -L crowdsec-blacklists -n      # on the node
```

### Development

```bash
helm lint charts/crowdsec-firewall-bouncer/
```

---

## Русская версия

# crowdsec-firewall-bouncer

Блокирует вредоносные IP (`.env` сканеры, брутфорс-боты и т.д.) на **уровне ноды** через iptables, до того как они достигнут nginx.

```text
                                    ┌──────────────────┐
                                    │   Internet       │
                                    │  (атакующий IP)  │
                                    └────────┬─────────┘
                                             │
                                             ▼
                              ┌──────────────────────────┐
                              │  ingress-nginx            │
                              │  (DaemonSet, hostNetwork) │
                              └────────────┬─────────────┘
                                           │
                                   ┌───────▼────────┐
                                   │  backend Pod   │
                                   │  (HTTP 200/404)│
                                   └────────────────┘
                                             ▲
                                             │ атакующий обходит
                                             │ nginx → идёт на IP ноды
                                             │
        ┌─────────────────────┐    ┌─────────┴──────────┐    ┌──────────────────┐
        │  CrowdSec Agent     │    │  CrowdSec LAPI     │    │ Firewall Bouncer │
        │  (DaemonSet)        │───▶│  (Service)         │───▶│ (DaemonSet,      │
        │  читает логи nginx  │    │  алерты→решения    │    │  privileged)     │
        └─────────────────────┘    └────────────────────┘    └────────┬─────────┘
                                                                      │
                                                                      ▼
                                                              ┌──────────────────┐
                                                              │  iptables DROP   │
                                                              │  INPUT chain     │
                                                              │  (уровень ядра)  │
                                                              └──────────────────┘
```

Требует: **CrowdSec LAPI** + **ingress-nginx с `hostNetwork`** + **Kubernetes Secret** с API-ключом bouncer'а.

---

## Подключение к своему GitOps

### 1. Добавить source repo в ArgoCD Project

В `Project` (например, `cluster-infra`) добавить `security-charts` в `sourceRepos`:

```yaml
spec:
  sourceRepos:
    - https://github.com/vitalykhe/security-charts.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: crowdsec
```

### 2. Создать ArgoCD Application

**Из Git-репозитория** (рекомендуется):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crowdsec-firewall-bouncer
  namespace: argocd
spec:
  project: cluster-infra
  source:
    repoURL: https://github.com/vitalykhe/security-charts.git
    targetRevision: main
    path: charts/crowdsec-firewall-bouncer
    helm:
      values: |
        existingSecret:
          name: crowdsec-firewall-bouncer-key
          key: api-key
        config:
          apiUrl: "http://crowdsec-crowdsec-lapi.crowdsec:8080"
  destination:
    server: https://kubernetes.default.svc
    namespace: crowdsec
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Из OCI-регистра** (GHCR):

```yaml
source:
  repoURL: oci://ghcr.io/vitalykhe/security-charts/crowdsec-firewall-bouncer
  targetRevision: 0.1.0
```

### 3. Добавить `KUBE_CONFIG_B64` в Secrets GitHub-репозитория

В **своём GitOps-репозитории** создать GitHub Actions Secret:

```bash
base64 < ~/.kube/config | tr -d '\n'
```

| Secret | Описание |
|---|---|
| `KUBE_CONFIG_B64` | base64-encoded kubeconfig с доступом к кластеру и namespace `crowdsec` |

### 4. Зарегистрировать bouncer и создать Secret с API-ключом

**Вариант A — GitHub Actions (рекомендуется).**  
Workflow лежит в **твоём GitOps-репозитории** (`.github/workflows/crowdsec-bootstrap.yml`):

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

Запустить: **GitHub → Actions → crowdsec-bootstrap → Run workflow**

**Вариант B — Вручную (one-time):**

```bash
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- \
  cscli bouncers add firewall-bouncer
# скопировать ключ

kubectl -n crowdsec create secret generic crowdsec-firewall-bouncer-key \
  --from-literal=api-key='<KEY>'

kubectl -n crowdsec rollout restart daemonset crowdsec-firewall-bouncer
```

### Развёртывание без ArgoCD (plain Helm)

```bash
helm repo add security-charts oci://ghcr.io/vitalykhe/security-charts
helm upgrade --install crowdsec-firewall-bouncer \
  security-charts/crowdsec-firewall-bouncer \
  --namespace crowdsec --create-namespace \
  --set existingSecret.name=crowdsec-firewall-bouncer-key \
  --set existingSecret.key=api-key \
  --set config.apiUrl=http://crowdsec-crowdsec-lapi.crowdsec:8080
```

Или с локальным values-файлом:

```bash
helm upgrade --install crowdsec-firewall-bouncer \
  oci://ghcr.io/vitalykhe/security-charts/crowdsec-firewall-bouncer \
  --namespace crowdsec --create-namespace \
  -f my-values.yaml
```

### Verifying

```bash
kubectl -n crowdsec get pods
kubectl -n crowdsec exec deployment/crowdsec-crowdsec-lapi -- cscli bouncers list
kubectl -n crowdsec logs daemonset/crowdsec-firewall-bouncer --tail 20
sudo iptables -L crowdsec-blacklists -n      # на ноде
```

### Development

```bash
helm lint charts/crowdsec-firewall-bouncer/
```
