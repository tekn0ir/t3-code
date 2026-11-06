#!/usr/bin/env bash
# Add (or update) a T3 Code provider instance that runs Claude Code against the CLIProxyAPI hub,
# on a host running a T3 server: a remote dev host over ssh, or this machine's T3 Desktop.
#
#   ./scripts/t3-hub-provider.sh anders@teknoir.airgapped          # add/update on a dev host
#   ./scripts/t3-hub-provider.sh --local --exclusive                 # T3 Desktop here, hub only
#   ./scripts/t3-hub-provider.sh --model deepseek-v4-pro --id deepseek-pro-hub \
#       --name "DeepSeek Pro (hub)" anders@delegated.local
#
# What it writes into ~/.t3/userdata/settings.json (backed up first; T3 reloads the file live):
#   - driver `claudeAgent` (T3's id for Claude; `claude` is "not registered in this build"),
#   - CLAUDE_CONFIG_DIR ~/.claude-hub, so the instance never sees the machine's claude.ai login and
#     the machine's other Claude processes (Remote Control services, a terminal `claude`) never
#     see the hub,
#   - ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN for the hub, every model role mapped to --model,
#     and CLAUDE_CODE_MAX_CONTEXT_TOKENS so Claude Code knows the model's real window.
# With --exclusive it also disables every built-in provider (Codex, Claude, Cursor, ...) and
# points the default, fallback, text-generation (titles, branch names) and source-control writer
# model selections at the hub instance, so nothing in that T3 environment uses another provider.
# The hub client key is read from deploy/cliproxyapi/secret.yaml and embedded in a program piped
# over stdin (to ssh or python3), never put on a command line.
#
# Options (defaults in brackets):
#   --local         this machine's T3 (Desktop) instead of user@host
#   --exclusive     hub only: disable all built-in providers, route all model defaults to the hub
#   --model ID      model id the hub serves [deepseek-flash]
#   --id ID         T3 provider instance id [deepseek-hub]
#   --name TEXT     display name [DeepSeek Flash (hub)]
#   --context N     model context window in tokens [1000000]
#   --hub URL       hub base URL [https://cliproxy.teknoir.cloud:8317]
#   --remove        remove the instance (and, with --exclusive, re-enable the built-in providers)
set -euo pipefail

MODEL=deepseek-flash
INSTANCE=deepseek-hub
NAME="DeepSeek Flash (hub)"
CONTEXT=1000000
HUB=https://cliproxy.teknoir.cloud:8317
REMOVE=0
EXCLUSIVE=0
LOCAL=0
HOST=""
SECRET="$(cd "$(dirname "$0")/.." && pwd)/deploy/cliproxyapi/secret.yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift ;;
    --id) INSTANCE="$2"; shift ;;
    --name) NAME="$2"; shift ;;
    --context) CONTEXT="$2"; shift ;;
    --hub) HUB="${2%/}"; shift ;;
    --remove) REMOVE=1 ;;
    --exclusive) EXCLUSIVE=1 ;;
    --local) LOCAL=1 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) HOST="$1" ;;
  esac
  shift
done
if [ "$LOCAL" = 0 ] && [ -z "$HOST" ]; then
  echo "usage: $0 [options] (--local | user@host)" >&2
  exit 2
fi
if [ "$REMOVE" = 0 ] && [ ! -r "$SECRET" ]; then
  echo "cannot read $SECRET (see README: Deploying the hub)" >&2
  exit 1
fi

# Built-in providers that T3 0.1.x creates a default instance for (instance id == driver id).
BUILT_INS="codex claudeAgent cursor grok fx opencode antigravity kiro pi muse"

# Build the program that runs on the target. Parameters (and the key) go in as a JSON literal.
program() {
  SECRET="$SECRET" MODEL="$MODEL" INSTANCE="$INSTANCE" NAME="$NAME" CONTEXT="$CONTEXT" HUB="$HUB" \
  REMOVE="$REMOVE" EXCLUSIVE="$EXCLUSIVE" BUILT_INS="$BUILT_INS" python3 - <<'GEN'
import json, os
e = os.environ
key = ""
if e["REMOVE"] != "1":
    import yaml
    d = yaml.safe_load(open(e["SECRET"]))
    key = yaml.safe_load(d["stringData"]["config.yaml"])["access"]["api-keys"][0]
cfg = {k: e[k] for k in ("MODEL", "INSTANCE", "NAME", "CONTEXT", "HUB")}
cfg.update(key=key, remove=e["REMOVE"] == "1", exclusive=e["EXCLUSIVE"] == "1",
           built_ins=e["BUILT_INS"].split())
print("import json")
print("CFG = json.loads(" + repr(json.dumps(cfg)) + ")")
print(r'''
import json, os, shutil, sys, time
p = os.path.expanduser("~/.t3/userdata/settings.json")
if not os.path.isdir(os.path.dirname(p)):
    sys.exit("no T3 userdata at " + os.path.dirname(p) + "; install T3 first")
d = {}
if os.path.exists(p):
    shutil.copy2(p, p + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
    d = json.load(open(p))
inst = d.setdefault("providerInstances", {})
iid, m = CFG["INSTANCE"], CFG["MODEL"]
selection_keys = ("defaultModelSelection", "fallbackModelSelection",
                  "textGenerationModelSelection", "sourceControlWriterModelSelection")
if CFG["remove"]:
    inst.pop(iid, None)
    if CFG["exclusive"]:
        for b in CFG["built_ins"]:
            if inst.get(b) == {"driver": b, "enabled": False}:
                inst.pop(b)
        for k in selection_keys:
            if (d.get(k) or {}).get("instanceId") == iid:
                d.pop(k)
    print("removed", iid)
else:
    if not CFG["key"] or CFG["key"].startswith("CHANGE-ME"):
        sys.exit("no hub API key")
    home = os.path.expanduser("~/.claude-hub")
    os.makedirs(home, mode=0o700, exist_ok=True)
    env = {
        "ANTHROPIC_BASE_URL": CFG["HUB"],
        "ANTHROPIC_MODEL": m,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": m,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": m,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": m,
        "CLAUDE_CODE_SUBAGENT_MODEL": m,
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS": CFG["CONTEXT"],
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }
    inst[iid] = {
        "driver": "claudeAgent",
        "displayName": CFG["NAME"],
        "enabled": True,
        "environment": [{"name": k, "value": v, "sensitive": False} for k, v in env.items()]
        + [{"name": "ANTHROPIC_AUTH_TOKEN", "value": CFG["key"], "sensitive": True}],
        "config": {"homePath": home, "customModels": [m]},
    }
    print("wrote", iid, "->", m, "via", CFG["HUB"])
    if CFG["exclusive"]:
        for b in CFG["built_ins"]:
            cur = inst.get(b, {"driver": b})
            cur["enabled"] = False
            inst[b] = cur
        sel = {"instanceId": iid, "model": m}
        for k in selection_keys:
            d[k] = dict(sel)
        print("exclusive: disabled", " ".join(CFG["built_ins"]) + "; all model defaults ->", iid)
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
''')
GEN
}

if [ "$LOCAL" = 1 ]; then
  program | python3 -
else
  program | ssh -o BatchMode=yes "$HOST" python3 -
fi
