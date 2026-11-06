#!/usr/bin/env bash
# One-command T3 Code setup for the dev hosts (teknoir.airgapped, delegated.local) and the Mac
# laptop: installs t3, claude and codex, and points Claude Code and Codex at the CLIProxyAPI hub.
#
#   CLIPROXY_API_KEY=... ./scripts/install-t3.sh            # install + configure
#   ./scripts/install-t3.sh --dry-run                       # show what would happen, change nothing
#   ./scripts/install-t3.sh --service                       # also run `t3 serve --lan` as a service
#
# Options:
#   --dry-run        Print the actions and the config files that would be written; change nothing.
#   --service        After configuring, install the T3 Code background service with LAN access
#                    (`t3 up --lan --no-connect --yes`).
#   --skip-install   Only (re)write the configs; do not install or check t3/claude/codex.
#   --hub URL        Hub base URL (default $CLIPROXY_URL or https://cliproxy.teknoir.cloud:8317).
#   -h, --help       Show this help.
#
# Environment:
#   CLIPROXY_URL       hub base URL, without /v1 (overridden by --hub)
#   CLIPROXY_API_KEY   client API key from the hub's config Secret (prompted for if unset)
#   T3CODE_VERSION     exact t3 version to install (default: latest stable); passed to t3's installer
#   T3CODE_CHANNEL     stable | nightly (passed to t3's installer)
#
# Existing ~/.claude/settings.json and ~/.codex/config.toml are copied to <file>.bak.<timestamp>
# before they are changed. settings.json is merged (other settings are kept); in config.toml the
# hub provider block is replaced and everything else is kept.
set -euo pipefail

HUB_URL="${CLIPROXY_URL:-https://cliproxy.teknoir.cloud:8317}"
DRY_RUN=0
SERVICE=0
SKIP_INSTALL=0
STAMP="$(date +%Y%m%d-%H%M%S)"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
LOCAL_BIN="${T3CODE_INSTALL_BIN_DIR:-${HOME}/.local/bin}"
MARK_BEGIN="# >>> cliproxy hub (managed by t3-code/scripts/install-t3.sh) >>>"
MARK_END="# <<< cliproxy hub <<<"

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }

# run CMD...: execute, or only print it in dry-run mode.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --service) SERVICE=1 ;;
      --skip-install) SKIP_INSTALL=1 ;;
      --hub) [ $# -ge 2 ] || die "--hub needs a URL"; HUB_URL="$2"; shift ;;
      --hub=*) HUB_URL="${1#--hub=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  HUB_URL="${HUB_URL%/}"
  HUB_URL="${HUB_URL%/v1}"
  case "$HUB_URL" in
    http://*|https://*) ;;
    *) die "hub URL must start with http:// or https://: $HUB_URL" ;;
  esac
}

detect_os() {
  case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux) OS=linux ;;
    *) die "unsupported OS: $(uname -s) (Linux and macOS only)" ;;
  esac
  log "OS: ${OS} ($(uname -m)), hub: ${HUB_URL}"
}

ensure_path() {
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *)
      export PATH="${LOCAL_BIN}:${PATH}"
      warn "${LOCAL_BIN} is not on your PATH; add it to your shell profile:"
      warn "  export PATH=\"${LOCAL_BIN}:\$PATH\""
      ;;
  esac
}

# fetch_and_run URL SHELL: download an installer script and run it with SHELL.
fetch_and_run() {
  local url="$1" shell="$2"
  have curl || die "curl is required to install from ${url}"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] curl -fsSL %s | %s\n' "$url" "$shell" >&2
  else
    curl -fsSL "$url" | "$shell"
  fi
}

install_t3() {
  if have t3; then
    log "t3 already installed: $(t3 --version 2>/dev/null || echo unknown) (upgrade with: t3 update)"
    return
  fi
  log "installing t3${T3CODE_VERSION:+ ${T3CODE_VERSION}} (T3 Code CLI)"
  # T3CODE_VERSION / T3CODE_CHANNEL / T3CODE_INSTALL_BIN_DIR are read by t3's installer.
  fetch_and_run https://t3.codes/install.sh sh
}

install_claude() {
  if have claude; then
    log "claude already installed: $(claude --version 2>/dev/null || echo unknown)"
    return
  fi
  log "installing claude (Claude Code, native installer)"
  fetch_and_run https://claude.ai/install.sh bash
}

install_codex() {
  if have codex; then
    log "codex already installed: $(codex --version 2>/dev/null || echo unknown)"
    return
  fi
  if have npm; then
    log "installing codex with npm"
    run npm install -g @openai/codex
  elif [ "$OS" = macos ] && have brew; then
    log "installing codex with Homebrew"
    run brew install codex
  else
    die "codex needs npm (Node.js 22+) or, on macOS, Homebrew; install one and re-run"
  fi
}

read_api_key() {
  if [ -n "${CLIPROXY_API_KEY:-}" ]; then
    API_KEY="$CLIPROXY_API_KEY"
  elif [ "$DRY_RUN" = 1 ]; then
    API_KEY="<CLIPROXY_API_KEY>"
  elif [ -t 0 ]; then
    printf 'CLIProxyAPI client API key for %s: ' "$HUB_URL" >&2
    IFS= read -rs API_KEY
    printf '\n' >&2
  else
    die "set CLIPROXY_API_KEY (no terminal to prompt on)"
  fi
  [ -n "$API_KEY" ] || die "empty API key"
  case "$API_KEY" in
    *\"*|*\\*) die "API key must not contain quotes or backslashes" ;;
  esac
}

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    log "backing up ${f} -> ${f}.bak.${STAMP}"
    run cp -p "$f" "${f}.bak.${STAMP}"
  fi
}

# install_file SRC DEST: move a generated temp file into place with mode 600 (it holds the key).
install_file() {
  local src="$1" dest="$2"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] would write %s:\n' "$dest" >&2
    sed 's/^/    /' "$src" >&2
    rm -f "$src"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  chmod 600 "$src"
  mv "$src" "$dest"
  log "wrote ${dest}"
}

# Claude Code reads env from settings.json; T3 Code also picks ANTHROPIC_BASE_URL up from there.
write_claude_settings() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")"
  backup "$CLAUDE_SETTINGS"
  if [ -s "$CLAUDE_SETTINGS" ] && have jq; then
    jq --arg url "$HUB_URL" --arg key "$API_KEY" \
      '.env = ((.env // {}) + {ANTHROPIC_BASE_URL: $url, ANTHROPIC_AUTH_TOKEN: $key})' \
      "$CLAUDE_SETTINGS" > "$tmp"
  elif [ -s "$CLAUDE_SETTINGS" ] && have python3; then
    HUB_URL="$HUB_URL" API_KEY="$API_KEY" python3 - "$CLAUDE_SETTINGS" > "$tmp" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
env = data.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = os.environ["HUB_URL"]
env["ANTHROPIC_AUTH_TOKEN"] = os.environ["API_KEY"]
json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
  else
    [ -s "$CLAUDE_SETTINGS" ] && warn "neither jq nor python3 found: replacing ${CLAUDE_SETTINGS} (backup kept)"
    cat > "$tmp" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${HUB_URL}",
    "ANTHROPIC_AUTH_TOKEN": "${API_KEY}"
  }
}
EOF
  fi
  install_file "$tmp" "$CLAUDE_SETTINGS"
}

# Codex: a `cliproxy` model provider (Responses API) selected as the default provider. The
# top-level model_provider key has to come before any [table], so it goes first; any old
# top-level model_provider line and any earlier managed block are dropped, the rest is kept.
write_codex_config() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/codex-config.XXXXXX")"
  backup "$CODEX_CONFIG"
  {
    printf '%s\n' "$MARK_BEGIN"
    printf 'model_provider = "cliproxy"\n'
    printf '%s\n' "$MARK_END"
    if [ -s "$CODEX_CONFIG" ]; then
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        /^\[/ { intable = 1 }
        !intable && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
        # hold blank lines so trailing ones are dropped (re-runs stay byte-identical)
        /^[[:space:]]*$/ { blanks++; next }
        { while (blanks > 0) { print ""; blanks-- } print }
      ' "$CODEX_CONFIG"
    fi
    printf '\n%s\n' "$MARK_BEGIN"
    cat <<EOF
[model_providers.cliproxy]
name = "CLIProxyAPI hub"
base_url = "${HUB_URL}/v1"
wire_api = "responses"
experimental_bearer_token = "${API_KEY}"
requires_openai_auth = false
EOF
    printf '%s\n' "$MARK_END"
  } > "$tmp"
  install_file "$tmp" "$CODEX_CONFIG"
}

check_hub() {
  have curl || return 0
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] curl -s %s/v1/models -H "Authorization: Bearer ***"\n' "$HUB_URL" >&2
    return
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${API_KEY}" "${HUB_URL}/v1/models" || true)"
  case "$code" in
    200) log "hub reachable: ${HUB_URL}/v1/models -> 200" ;;
    401) warn "hub answered 401: the API key is not in the hub's access.api-keys" ;;
    403) warn "hub answered 403 for /v1/models" ;;
    000) warn "hub not reachable at ${HUB_URL}: on the LAN, cliproxy.teknoir.cloud must resolve to 192.168.2.166 (router DNS override or /etc/hosts); configs are written anyway" ;;
    *) warn "hub answered HTTP ${code} for /v1/models" ;;
  esac
}

install_service() {
  log "installing the T3 Code background service with LAN access"
  run t3 up --lan --no-connect --yes
}

main() {
  parse_args "$@"
  detect_os
  ensure_path
  if [ "$SKIP_INSTALL" = 0 ]; then
    install_t3
    install_claude
    install_codex
  fi
  read_api_key
  write_claude_settings
  write_codex_config
  check_hub
  if [ "$SERVICE" = 1 ]; then
    install_service
  fi
  log "done. Start T3 Code with: t3 serve --lan   (or re-run with --service)"
}

main "$@"
