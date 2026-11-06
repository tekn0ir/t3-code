#!/usr/bin/env bash
# Add (or update) a T3 Code provider instance that runs Claude Code against the CLIProxyAPI hub,
# on a remote host running the T3 service.
#
#   ./scripts/t3-hub-provider.sh anders@teknoir.airgapped
#   ./scripts/t3-hub-provider.sh --model deepseek-flash --id deepseek-hub \
#       --name "DeepSeek Flash (hub)" --context 1000000 anders@delegated.local
#
# What it writes into ~/.t3/userdata/settings.json on the host (backed up first; T3 reloads the
# file live, no restart):
#   - driver `claudeAgent` (T3's id for Claude; `claude` is "not registered in this build"),
#   - CLAUDE_CONFIG_DIR ~/.claude-hub, so this instance never sees the host's claude.ai login and
#     the host's other Claude processes (Remote Control services) never see the hub,
#   - ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN for the hub, every model role mapped to --model,
#     and CLAUDE_CODE_MAX_CONTEXT_TOKENS so Claude Code knows the model's real window.
# The hub client key is read locally from deploy/cliproxyapi/secret.yaml and sent over ssh stdin,
# never on a command line.
#
# Options (defaults in brackets):
#   --model ID      model id the hub serves [deepseek-flash]
#   --id ID         T3 provider instance id [deepseek-hub]
#   --name TEXT     display name [DeepSeek Flash (hub)]
#   --context N     model context window in tokens [1000000]
#   --hub URL       hub base URL [https://cliproxy.teknoir.cloud:8317]
#   --remove        remove the instance instead
set -euo pipefail

MODEL=deepseek-flash
INSTANCE=deepseek-hub
NAME="DeepSeek Flash (hub)"
CONTEXT=1000000
HUB=https://cliproxy.teknoir.cloud:8317
REMOVE=0
SECRET="$(cd "$(dirname "$0")/.." && pwd)/deploy/cliproxyapi/secret.yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift ;;
    --id) INSTANCE="$2"; shift ;;
    --name) NAME="$2"; shift ;;
    --context) CONTEXT="$2"; shift ;;
    --hub) HUB="${2%/}"; shift ;;
    --remove) REMOVE=1 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) HOST="$1" ;;
  esac
  shift
done
[ -n "${HOST:-}" ] || { echo "usage: $0 [options] user@host" >&2; exit 2; }

if [ "$REMOVE" = 1 ]; then
  KEY=""
else
  [ -r "$SECRET" ] || { echo "cannot read $SECRET (see README: Deploying the hub)" >&2; exit 1; }
  KEY="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(yaml.safe_load(d["stringData"]["config.yaml"])["access"]["api-keys"][0])' "$SECRET")"
fi

printf '%s\n' "$KEY" | ssh -o BatchMode=yes "$HOST" \
  "MODEL='$MODEL' INSTANCE='$INSTANCE' NAME='$NAME' CONTEXT='$CONTEXT' HUB='$HUB' REMOVE='$REMOVE' python3 -c '
import json, os, shutil, sys, time
e = os.environ
p = os.path.expanduser(\"~/.t3/userdata/settings.json\")
if not os.path.exists(p):
    sys.exit(\"no T3 settings at \" + p + \"; install the T3 service first (scripts/install-t3.sh --service)\")
key = sys.stdin.readline().strip()
shutil.copy2(p, p + \".bak.\" + time.strftime(\"%Y%m%d-%H%M%S\"))
d = json.load(open(p))
inst = d.setdefault(\"providerInstances\", {})
if e[\"REMOVE\"] == \"1\":
    inst.pop(e[\"INSTANCE\"], None)
    print(\"removed\", e[\"INSTANCE\"])
else:
    if not key or key.startswith(\"CHANGE-ME\"):
        sys.exit(\"no hub API key received\")
    home = os.path.expanduser(\"~/.claude-hub\")
    os.makedirs(home, mode=0o700, exist_ok=True)
    m = e[\"MODEL\"]
    env = {
        \"ANTHROPIC_BASE_URL\": e[\"HUB\"],
        \"ANTHROPIC_MODEL\": m,
        \"ANTHROPIC_DEFAULT_OPUS_MODEL\": m,
        \"ANTHROPIC_DEFAULT_SONNET_MODEL\": m,
        \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": m,
        \"CLAUDE_CODE_SUBAGENT_MODEL\": m,
        \"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": e[\"CONTEXT\"],
        \"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\": \"1\",
    }
    inst[e[\"INSTANCE\"]] = {
        \"driver\": \"claudeAgent\",
        \"displayName\": e[\"NAME\"],
        \"enabled\": True,
        \"environment\": [{\"name\": k, \"value\": v, \"sensitive\": False} for k, v in env.items()]
        + [{\"name\": \"ANTHROPIC_AUTH_TOKEN\", \"value\": key, \"sensitive\": True}],
        \"config\": {\"homePath\": home, \"customModels\": [m]},
    }
    print(\"wrote\", e[\"INSTANCE\"], \"->\", m, \"via\", e[\"HUB\"])
tmp = p + \".tmp\"
json.dump(d, open(tmp, \"w\"), indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
'"
