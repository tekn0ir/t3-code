# t3-code

A home-hosted, LAN-only agentic dev setup for testing several models reviewing each other's work:

- **CLIProxyAPI** (the hub) runs on the `r415` K3s cluster, is deployed by Argo CD, and is
  reachable from the LAN at `https://cliproxy.teknoir.cloud` (API and `/management.html`).
- **T3 Code** installs with one command on `teknoir.airgapped`, `delegated.local` and the Mac
  laptop, with Claude Code and Codex pre-wired to the hub.

The plan this repo follows is [.junie/plans/agentic-dev-setup.md](.junie/plans/agentic-dev-setup.md).

## Layout

```
src/cliproxyapi/                 submodule: github.com/tekn0ir/CLIProxyAPI (fork of router-for-me/CLIProxyAPI)
src/t3code/                      submodule: github.com/tekn0ir/t3code      (fork of pingdotgg/t3code)
docker/cliproxyapi/Dockerfile    proxy image, built from src/cliproxyapi
docker/t3code/Dockerfile         optional `t3 serve --lan` image (t3 + git + claude + codex)
.github/workflows/images.yml     builds/pushes ghcr.io/tekn0ir/{cliproxyapi,t3code}
deploy/cliproxyapi/              kustomize: namespace, Deployment, PVC, Service, VirtualService, AuthorizationPolicy
deploy/cliproxyapi/secret.example.yaml   config.yaml template (applied out-of-band, never committed)
deploy/argocd/cliproxyapi-app.yaml       reference copy of the gitops Application
scripts/install-t3.sh            one-command T3 Code installer/configurator
scripts/login-accounts.md        signing Claude/Codex accounts in to the hub
```

## Forks and features

```bash
git clone --recurse-submodules https://github.com/tekn0ir/t3-code
cd src/cliproxyapi                         # same for src/t3code
git remote add upstream https://github.com/router-for-me/CLIProxyAPI.git   # once per clone
git fetch upstream && git rebase upstream/main     # follow upstream on main
git switch -c features/soonest-reset-first         # feature work on features/<name>
```

`origin` is the fork, `upstream` the original project. Feature branches are `features/<name>`;
`main` tracks upstream plus merged features. Bump the submodule pointer in this repo to deploy.

## Images

```bash
docker build -f docker/cliproxyapi/Dockerfile src/cliproxyapi -t cliproxyapi:local
docker build docker/t3code -t t3code:local --build-arg T3CODE_VERSION=0.1.7
```

CI pushes `:main`, `:sha-<short>` and tag versions to GHCR (amd64 + arm64). After the first push,
make the packages public (or add a pull secret) and pin `newTag` in
`deploy/cliproxyapi/kustomization.yaml` to a `sha-…` tag.

## Deploying the hub

1. **Secret** (once, and whenever keys change):
   ```bash
   cp deploy/cliproxyapi/secret.example.yaml deploy/cliproxyapi/secret.yaml   # gitignored
   # set the client API key and management secret
   kubectl --context r415 create namespace cliproxy --dry-run=client -o yaml | kubectl --context r415 apply -f -
   kubectl --context r415 apply -f deploy/cliproxyapi/secret.yaml
   ```
2. **Argo CD**: the gitops repo (`platform-applications-gitops`, branch `cliproxyapi`) adds the
   `cliproxyapi` Application (`cliproxy.enabled`, teknoir-cloud only) and the
   `cliproxy.teknoir.cloud:443` entry in `istio.bypassAuth`. It ships through the normal staging
   release. The Application follows `cliproxy.targetRevision` of this repo (default `main`).
3. **Accounts**: see [scripts/login-accounts.md](scripts/login-accounts.md).

Check from the LAN:

```bash
curl https://cliproxy.teknoir.cloud/v1/models -H "Authorization: Bearer $CLIPROXY_API_KEY"
```

### LAN filter (verify before relying on it)

`teknoir.cloud` resolves publicly, so `cliproxy.teknoir.cloud` is reachable from the internet
unless the AuthorizationPolicy stops it. The policy denies any client IP outside
`192.168.2.0/24` at the ingress gateway, but that only works if the gateway sees the real client IP.
With the k3s ServiceLB and `externalTrafficPolicy: Cluster` (the istio chart default) the source is
rewritten, so check both directions after the first sync:

- from the LAN, `/v1/models` returns 200;
- from outside (e.g. phone on mobile data), it returns 403.

If the LAN gets 403, the gateway sees a rewritten address: set `externalTrafficPolicy: Local` on
`istio-ingressgateway` (gitops `charts/istio`) or add the node/svclb address to the policy only
together with another way of keeping outside traffic off this host (e.g. split DNS to
`192.168.2.166` and no public DNS for `cliproxy`).

## T3 Code on a dev machine

```bash
CLIPROXY_API_KEY=... ./scripts/install-t3.sh             # installs t3, claude, codex; writes configs
./scripts/install-t3.sh --dry-run                        # preview only
./scripts/install-t3.sh --service                        # also run T3 Code as a LAN service
```

It writes `~/.claude/settings.json` (`env.ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`, merged
into existing settings) and `~/.codex/config.toml` (a `cliproxy` Responses provider set as the
default), backing up both first. Re-running is safe.

## Secrets

Nothing secret is committed: the hub's `config.yaml` lives only in the `cliproxyapi-config` Secret,
OAuth logins live on the `cliproxyapi-auths` PVC, and client keys only in each machine's home
directory (mode 600).
