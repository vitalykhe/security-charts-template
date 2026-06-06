# Repository Rules

## Repository Scope

- Treat this project as an independent repository. When reading, editing, or interpreting files in this project, follow only the agent rules committed inside this repository; do not apply rules from sibling projects or parent workspace directories across repository boundaries.

## External Configuration

- Keep the runtime image environment-neutral. Values that differ between local, staging, and production must come from `CONFIG_PATH`, the YAML config rendered by deployment, environment variables referenced by that YAML, or mounted secret files.
- Keep deployment ownership in the GitOps repository. Helm charts, environment values, Kubernetes manifests, ConfigMaps, Secrets templates, webhook jobs, and image promotion workflows must not live in this backend repository.
- Never hardcode secrets, tokens, private keys, API keys, passwords, or production endpoints in Go code, Dockerfile, local examples, or docs. Use environment variables, Kubernetes Secrets, external secret stores, or mounted files.
- Non-sensitive deploy-time settings belong in GitOps values or ConfigMaps. Sensitive settings belong in Secrets or mounted secret files, not ConfigMaps.
- Keep protocol invariants in code when changing them would break compatibility or security: token formats, signature algorithms, Telegram `/start` payload constraints, claim names, exact redirect allowlist behavior, and validation regexes.
- If a numeric/string value controls runtime behavior or operational policy, make it configurable with a safe default and validation. Examples: TTL bounds, rate-limit windows, HTTP/client timeouts, title/state length limits, trusted proxy CIDRs.
- Example values may use placeholders such as `Example App`, `client_1`, and localhost URLs, but real credentials and production values must not be committed.

## Secrets Management

- **Design with external secrets from day one.** Every new component that requires API keys, tokens, passwords, or any sensitive credential must accept them through one of these mechanisms:
  - **Kubernetes Secret** referenced by `existingSecret` or `secretKeyRef` in the Helm chart values — the Secret itself is created outside of ArgoCD (by a GitHub Actions workflow, External Secrets Operator, or manual bootstrap).
  - **GitHub Actions secrets** injected at deploy time via `env:` or `secrets:` in the workflow YAML.
  - **External Secrets Operator** (ESO) `ExternalSecret` resource that syncs from a vault or cloud secret store.
- **GitHub Actions is the default bootstrap mechanism.** For MVP and cluster-level infra, create a dedicated workflow (e.g., `crowdsec-bootstrap.yml`) that registers credentials with the target service and writes the corresponding Kubernetes Secret. The workflow reads from GitHub Actions secrets and never exposes the value in logs or Git.
- **A Helm chart `values.yaml` must NOT contain a real credential, even as a placeholder.** If a default value is needed for local development, use a clearly fake value (e.g., `change-me`) and document the bootstrap procedure in the chart's `values.yaml` or the project README.
- **ArgoCD Application manifests must reference external Secrets, not embed them.** Use `existingSecret` patterns in the Helm values stanza. If the chart does not support external secret references, fork the chart or add the parameter before committing.
- **When proposing a new feature, always specify how its credentials will be bootstrapped.** Include a GitHub Actions workflow or a documented one-time manual step in the proposal. Retrofitting secret externalization after implementation is not acceptable.

## Git Operations

- Never run `git commit` automatically.
- Run any `git` operation only after explicit manual user confirmation in the dialogue or after the user gives a direct command for that specific operation.
- If `git status` is clean and the current branch is `main` with `main` matching its configured remote, get any required Git-operation confirmation and always create a new working branch before starting work or making project changes.
- Editing files is allowed without separate Git confirmation; this restriction applies to `git` commands, not ordinary file changes.

## Collaboration Rules

- Never run `git commit` automatically. Always ask first or wait for a direct user command.
