# Signing accounts in to CLIProxyAPI on r415

The OAuth providers redirect your browser to a **localhost** callback:

| Provider | Callback | Container port |
|---|---|---|
| Claude (Anthropic) | `http://localhost:54545/callback` | 54545 |
| Codex (OpenAI) | `http://localhost:1455/auth/callback` | 1455 |

The proxy runs in a pod, so forward those ports from the machine whose browser you log in with.
The logins are written to the `cliproxyapi-auths` PVC (`/root/.cli-proxy-api`) and survive
restarts. Repeat for every account you want in the round-robin pool.

## Prerequisites

- A working `r415` kube context (`kubectl --context r415 get nodes`).
- The config Secret is applied and the pod is Ready:
  `kubectl --context r415 -n cliproxy get pods`.

## 1. Forward the callback ports

Keep this running in its own terminal during the login:

```bash
kubectl --context r415 -n cliproxy port-forward deploy/cliproxyapi 54545:54545 1455:1455 8317:8317
```

(8317 is optional: it lets you use the dashboard at `http://localhost:8317/management.html`
even when DNS for `cliproxy.teknoir.cloud` isn't set up yet.)

## 2a. Log in from the dashboard (recommended)

1. Open `https://cliproxy.teknoir.cloud:8317/management.html` (or `http://localhost:8317/management.html`)
   and enter the management secret.
2. Go to **OAuth / Auth files**, pick Claude or Codex, and open the login link in the **same**
   machine's browser that runs the port-forward.
3. After the provider redirects to `localhost:<port>`, the port-forward delivers the callback to the
   pod and the new auth file appears in the list.

## 2b. Log in from the CLI inside the pod

```bash
# Claude
kubectl --context r415 -n cliproxy exec -it deploy/cliproxyapi -- \
  ./CLIProxyAPI -config /config/config.yaml -claude-login -no-browser

# Codex (device-code flow needs no callback port at all)
kubectl --context r415 -n cliproxy exec -it deploy/cliproxyapi -- \
  ./CLIProxyAPI -config /config/config.yaml -codex-device-login
```

Open the printed URL in your browser. For the callback flows the port-forward from step 1 must be
running.

## 3. Check

```bash
kubectl --context r415 -n cliproxy exec deploy/cliproxyapi -- ls -l /root/.cli-proxy-api
curl -s https://cliproxy.teknoir.cloud:8317/v1/models -H "Authorization: Bearer $CLIPROXY_API_KEY" | head
```

## Backup

The auth files are OAuth refresh tokens. To keep a copy off the node:

```bash
kubectl --context r415 -n cliproxy exec deploy/cliproxyapi -- tar -C /root/.cli-proxy-api -czf - . > cliproxy-auths.tgz
```

Store that file like a password (it is gitignored only if you keep it outside the repo).
