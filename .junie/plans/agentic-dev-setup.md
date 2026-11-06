---
sessionId: session-261104-085318-147m
---

# Requirements

### Overview & Goals
Set up a LAN-only, home-hosted agentic dev environment so you can test several models reviewing each other's work:
- **CLIProxyAPI** runs on the `r415` K3s cluster. It is deployed by Argo CD and its dashboard is reachable from your LAN through Istio.
- **T3 Code** installs with one command on `teknoir.airgapped`, `delegated.local` and your Mac laptop. Claude Code and Codex on each machine are pre-wired to the proxy.
- **This folder** (`/Volumes/GIT/teknoir/t3-code`) becomes the git repo for the whole setup. It holds the source forks, Dockerfiles, Kubernetes manifests and install scripts.

### Scope
**In scope**
- Initialize the git repo.
- Clone `router-for-me/CLIProxyAPI` and `pingdotgg/t3code` as forks, ready for your own features.
- Dockerfiles and GitHub Actions image builds pushed to GHCR.
- Kustomize manifests for the proxy.
- One Argo CD Application in the gitops repo.
- An Istio LAN host for the proxy.
- A T3 Code install script.

**Out of scope**
- Tailscale.
- High availability.
- Writing the actual proxy features (for example soonest-reset-first routing). This plan only prepares for them.
- Signing accounts in. You complete the OAuth logins yourself.

### Functional Requirements
- The proxy runs as a single replica pinned to node `r415`.
- Account logins are stored on a persistent volume, so they survive restarts.
- Config follows Theo's guide: round-robin routing, session affinity with a 1h TTL, an API key, and a management secret.
- `https://cliproxy.teknoir.cloud` serves the API and `/management.html`, from LAN source IPs only.
  > **Revised 2026-11-06:** served at `https://cliproxy.teknoir.cloud:8317` on a dedicated
  > ingress listener that the router does not forward (`deploy/cliproxyapi/gateway.yaml`), not on
  > `teknoir-gateway:443` with an IP allowlist: the k3s ServiceLB rewrites client IPs and the LAN
  > spans 192.168.1.0/24 and 192.168.2.0/24. LAN DNS must map the name to 192.168.2.166.
- `scripts/install-t3.sh` works on Linux and macOS. It installs `t3`, `claude` and `codex`, and writes `~/.claude/settings.json` and `~/.codex/config.toml` pointing at the hub. It backs up any existing files first.
- `docker/t3code` provides an optional container image for running `t3 serve --lan`.

# Technical Design

### Key Decisions
- **Separate repo app.** Manifests live here in `deploy/`. The gitops repo gets one small Application pointing at this repo. It is added on a feature branch off `teknoir-cloud` and goes through the normal staging flow.
- **Istio LAN host.** A VirtualService on `istio-system/teknoir-gateway`, which already has the wildcard TLS cert.
  - An AuthorizationPolicy with `remoteIpBlocks` limited to the LAN CIDR keeps it LAN-only.
  - The host is added to `istio.bypassAuth` in the auth chart so oauth2-proxy doesn't block bearer-token API calls. The proxy's own API key and management secret protect it instead.
- **Forks as submodules.** `src/CLIProxyAPI` and `src/t3code` each have an `upstream` remote, so you can rebase onto upstream and develop features on branches.
- **Secrets stay out of git.** `config.yaml` is mounted from a Secret that is applied out-of-band (`deploy/cliproxyapi/secret.example.yaml` is a template). This can be swapped later for the gitops repo's `platform-secrets` pattern.

### File Structure
```
.gitignore  README.md
src/CLIProxyAPI/           # submodule (fork), upstream remote
src/t3code/                # submodule (fork), upstream remote
docker/cliproxyapi/Dockerfile   # builds from src/CLIProxyAPI
docker/t3code/Dockerfile        # node/debian + t3 + git + claude + codex; CMD t3 serve --lan
.github/workflows/images.yml    # build+push ghcr.io/<you>/{cliproxyapi,t3code}
deploy/cliproxyapi/
  kustomization.yaml namespace.yaml deployment.yaml (Recreate, nodeSelector r415)
  pvc.yaml (local-path, /root/.cli-proxy-api) service.yaml (ClusterIP 8317)
  virtualservice.yaml authorizationpolicy.yaml secret.example.yaml
deploy/argocd/cliproxyapi-app.yaml   # copied into gitops repo
scripts/install-t3.sh  scripts/login-accounts.md
```

### Gitops repo changes (`/Volumes/GIT/ai/platform-applications-gitops`, feature branch)
- Add an Application, either `charts/app-of-apps/templates/cliproxyapi.yaml` gated by `cliproxy.enabled` or a standalone manifest. Its `repoURL` is this repo and its `path` is `deploy/cliproxyapi`.
- Add the `cliproxy.teknoir.cloud` host to `istio.bypassAuth` in `charts/auth/values.yaml`.

### Risks
- **Cluster access:** the `r415` kube context currently fails TLS verification. You need to fix the kubeconfig CA before verifying the deployment.
- **Server binding:** `server.host` must be `""` inside the pod, and the pod and gateway CIDRs must be in `trusted-proxies`. Otherwise the Service can't reach the proxy, or the LAN IP filter breaks.
- **Codex websockets:** these must pass through Istio, so check that the VirtualService allows the WebSocket upgrade.

# Testing

### Validation Approach
- `kustomize build deploy/cliproxyapi` renders without errors.
- Run `kubeconform` on the rendered output.
- `docker build` succeeds for both Dockerfiles.
- Run `shellcheck` on `scripts/install-t3.sh`.
- Run `install-t3.sh --dry-run` on macOS and confirm it produces the correct config output.
- `helm template` on the app-of-apps chart, if it is changed.
- After sync (requires a working `r415` context and cluster access):
  - `curl https://cliproxy.teknoir.cloud/v1/models -H 'Authorization: Bearer …'` returns a model list from the LAN.
  - The same request from outside the LAN gets a 403.

# Delivery Steps

###   Step 1: Initialize repo and clone forks
This folder is a git repo with both upstream projects as submodules, ready for your own features.
- `git init`, plus `.gitignore` (secrets, `.output.txt`, IDE files) and a `README.md`.
- Add `src/CLIProxyAPI` and `src/t3code` as submodules.
- Add an `upstream` remote to each, plus a `features/` branch convention.

###   Step 2: Dockerfiles and CI image builds
Images for both projects can be built locally and are pushed to GHCR from GitHub Actions.
- `docker/cliproxyapi/Dockerfile`: multi-stage Go build from `src/CLIProxyAPI`.
- `docker/t3code/Dockerfile`: installs `t3` (pinned with `T3CODE_VERSION`), `git`, `claude` and `codex`; runs `t3 serve --lan`.
- `.github/workflows/images.yml`: builds and pushes both images on push or tag.
- Verify with a local `docker build`.

###   Step 3: CLIProxyAPI Kubernetes manifests with Istio LAN exposure
`deploy/cliproxyapi` renders a complete proxy deployment for r415.
- Namespace, plus a Deployment with Recreate strategy, `nodeSelector` set to r415 and ports 8317, 54545 and 1455.
- PVC (local-path) for the account logins; config Secret template.
- ClusterIP Service.
- VirtualService on `teknoir-gateway` for `cliproxy.teknoir.cloud`, with WebSocket upgrade allowed.
- AuthorizationPolicy restricting access to the LAN CIDR.
- `scripts/login-accounts.md` describing the `kubectl exec` and port-forward steps for OAuth login.
- Validate with `kustomize build` and `kubeconform`.

###   Step 4: Wire into ArgoCD gitops repo
> **Revised 2026-11-06: self-contained, no gitops repo change.** The Application lives in
> `deploy/argocd/cliproxyapi-app.yaml` and is created once with `scripts/bootstrap-argocd.sh`
> (break-glass on `teknoir-system`, because the gitops release guard denies hand-made Application
> writes). The `istio.bypassAuth` entry is replaced by `deploy/cliproxyapi/envoyfilter-bypass-auth.yaml`.
> The points below describe the original, abandoned approach.

A feature branch in the gitops repo deploys the proxy from this repo.
- Add the Application manifest pointing at `deploy/cliproxyapi`, gated with `cliproxy.enabled` in app-of-apps.
- Add the host to `istio.bypassAuth` in `charts/auth/values.yaml`.
- Validate with `helm template`.
- Leave the branch ready for a PR and staging release.

###   Step 5: T3 Code one-command installer
`scripts/install-t3.sh` sets up T3 Code on the dev hosts and the laptop, pointed at the hub.
- Detects Linux or macOS.
- Installs `t3`, `claude` and `codex`.
- Backs up existing configs, then writes `~/.claude/settings.json` and `~/.codex/config.toml` using the hub URL and key from env or a prompt.
- Supports `--dry-run` and an optional `--service` mode (`t3 serve --lan`).
- Check with `shellcheck` and a dry run.