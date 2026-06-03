#!/bin/bash

# params
USE_HOST_NETWORK=""
CUSTOM_PORT=""

# options
HOST_NETWORK="--network=host"
NET_ADMIN_CAPABILITY="--cap-add=NET_ADMIN"

ALIASES_VOLUME="-v ./misc/aliases.sh:/etc/profile.d/personal_aliases.sh:ro"
INIT_VOLUME="-v ./misc/init.sh:/etc/profile.d/ai-init.sh:ro"
BOOTSTRAP_VOLUME="-v ./misc/ai-bootstrap.sh:/root/ai-bootstrap.sh:ro"

WORKSPACE_VOLUME="-v $HOME/workspace:/root/workspace"
DOCKER_SOCK_VOLUME="-v /var/run/docker.sock:/var/run/docker.sock"

AWS_VOLUME="-v $HOME/.aws:/root/.aws"
GCLOUD_VOLUME="-v $HOME/.config/gcloud:/root/.config/gcloud/"
GO_LIB_VOLUME="--mount source=local-dev-go-pkg-path,target=/opt/go/pkg"
CLAUDE_STATE_VOLUME="-v claude-state:/root/.claude"
CLAUDE_JSON_VOLUME="-v ./misc/.claude.json:/root/.claude.json"
# Credentials are bind-mounted from the host so the container shares auth with the host
# Claude instance.  claude-state volume provides everything else under /root/.claude/.
CLAUDE_CREDS_VOLUME="-v $HOME/.claude/.credentials.json:/root/.claude/.credentials.json"
# gh: no config dir mount — GH_TOKEN env var alone is sufficient.
# Mounting ~/.config/gh causes spurious "failed to log in (default)" errors because
# hosts.yml references the host keyring which doesn't exist in the container.
GH_CONFIG_VOLUME=""
DTCTL_CONFIG_VOLUME="-v $HOME/.config/dtctl:/root/.config/dtctl"
DTCTL_OAUTH_VOLUME="-v $HOME/.local/share/dtctl:/root/.local/share/dtctl"
DTCTL_TOKEN_STORAGE_ENV="-e DTCTL_TOKEN_STORAGE=file"
# junoctl: bind-mount host config (installed skills list); token arrives via JUNOCTL_TOKEN env var
JUNOCTL_CONFIG_VOLUME="-v $HOME/.config/junoctl:/root/.config/junoctl"
# acli-pii: config + credentials file.  No keyring needed — tool falls back to
# credentials.yaml when the OS keyring is unavailable.  Bind-mounting the dir
# persists the credentials file across container restarts.
ACLI_CONFIG_VOLUME="-v $HOME/.acli-pii:/root/.acli-pii"
ICM_DATA_VOLUME="-v icm-data:/root/.icm"

# ── Auth token injection from host GNOME Keyring ────────────────────────────────
# gh, junoctl, bbctl, and acli-pii all store tokens in the OS keyring which does
# not exist inside a Docker container.  Each tool supports a CI env-var bypass:
#   gh       → GH_TOKEN
#   junoctl  → JUNOCTL_TOKEN   (access_token JWT; expires in ~5 h; restart ./run.sh to refresh)
#   bbctl    → BB_TOKEN        (PAT; does not expire)
#   acli-pii → ACLI_JIRA_TOKEN / ACLI_JIRA_EMAIL / ACLI_JIRA_SITE
#
# Tokens are extracted from the host keyring at each ./run.sh invocation so they
# stay current.  If a token cannot be extracted the variable is left empty and
# silently omitted from the docker run command.
GH_TOKEN_ENV=""
JUNOCTL_TOKEN_ENV=""
BB_TOKEN_ENV=""
ACLI_TOKEN_ENV=""
ACLI_EMAIL_ENV=""
ACLI_SITE_ENV=""

_inject_tokens() {
  if ! command -v secret-tool >/dev/null 2>&1; then
    echo "warn: secret-tool not found — auth token injection skipped (apt install libsecret-tools)" >&2
    return
  fi

  local _val _acli_json _token _email _site

  # gh — the CLI exposes its own token without needing to know keyring attrs
  if command -v gh >/dev/null 2>&1; then
    _val=$(gh auth token 2>/dev/null)
    [ -n "$_val" ] && GH_TOKEN_ENV="-e GH_TOKEN=${_val}"
  fi

  # junoctl — trigger a refresh on the host first (access_token expires ~5 h;
  # refresh_token is valid ~30 days; any API call causes auto-refresh)
  command -v junoctl >/dev/null 2>&1 && junoctl auth whoami >/dev/null 2>&1 || true

  # extract the (potentially just-refreshed) access_token JWT
  # go-keyring stores items with 'username' attribute (not 'account')
  _val=$(secret-tool lookup service junoctl username oauth-token-v2 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  [ -n "$_val" ] && JUNOCTL_TOKEN_ENV="-e JUNOCTL_TOKEN=${_val}"

  # bbctl — plain Bitbucket PAT
  _val=$(secret-tool lookup service bbctl username access-token 2>/dev/null)
  [ -n "$_val" ] && BB_TOKEN_ENV="-e BB_TOKEN=${_val}"

  # acli-pii — Jira credentials stored as a JSON blob in keyring
  _acli_json=$(secret-tool lookup service atlassian-cli username 'krzysztof.bannach@dynatrace.com' 2>/dev/null)
  if [ -n "$_acli_json" ]; then
    _token=$(echo "$_acli_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
    _email=$(echo "$_acli_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('email',''))" 2>/dev/null)
    _site=$(echo "$_acli_json"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('site',''))"  2>/dev/null)
    [ -n "$_token" ] && ACLI_TOKEN_ENV="-e ACLI_JIRA_TOKEN=${_token}"
    [ -n "$_email" ] && ACLI_EMAIL_ENV="-e ACLI_JIRA_EMAIL=${_email}"
    [ -n "$_site"  ] && ACLI_SITE_ENV="-e ACLI_JIRA_SITE=${_site}"
  fi
}
# ────────────────────────────────────────────────────────────────────────────────

function load_params() {
  while [[ "$#" -gt 0 ]]; do
      case $1 in
          --use-host-network)
              USE_HOST_NETWORK="$HOST_NETWORK"
              ;;
          -p|--expose-port)
              CUSTOM_PORT="-p $2:$2"
              shift
              ;;
          -h|--help)
              echo "Usage: $0 [--use-host-network] [-p|--expose-port <port>]"
              echo ""
              echo "  --use-host-network   Required for OAuth callbacks (Juno MCP first-time"
              echo "                       auth, Claude Code login if not yet authed in the"
              echo "                       claude-state volume)."
              exit 0
              ;;
          *)
              echo "Unknown parameter passed: $1"
              exit 1
              ;;
      esac
      shift
  done
}

function run() {
  # Ensure bind-mount targets exist as files on the host (Docker would create
  # them as directories otherwise, breaking the mounts).
  touch "$(dirname "$0")/misc/.claude.json"
  touch "$HOME/.claude/.credentials.json"
  # Ensure host config dirs exist for tools that have no host-side config yet
  mkdir -p "$HOME/.config/gh" "$HOME/.config/junoctl" "$HOME/.acli-pii"

  _inject_tokens

  docker run \
    $NET_ADMIN_CAPABILITY \
    $AWS_VOLUME \
    $GCLOUD_VOLUME \
    $WORKSPACE_VOLUME \
    $DOCKER_SOCK_VOLUME \
    $ALIASES_VOLUME \
    $INIT_VOLUME \
    $BOOTSTRAP_VOLUME \
    $GO_LIB_VOLUME \
    $CLAUDE_STATE_VOLUME \
    $CLAUDE_JSON_VOLUME \
    $CLAUDE_CREDS_VOLUME \
    $GH_CONFIG_VOLUME \
    $DTCTL_TOKEN_STORAGE_ENV \
    $DTCTL_CONFIG_VOLUME \
    $DTCTL_OAUTH_VOLUME \
    $JUNOCTL_CONFIG_VOLUME \
    $ACLI_CONFIG_VOLUME \
    $ICM_DATA_VOLUME \
    $GH_TOKEN_ENV \
    $JUNOCTL_TOKEN_ENV \
    $BB_TOKEN_ENV \
    $ACLI_TOKEN_ENV \
    $ACLI_EMAIL_ENV \
    $ACLI_SITE_ENV \
    $USE_HOST_NETWORK \
    $CUSTOM_PORT \
    --rm -it local-docker:latest /bin/bash --login
}

function main() {
    load_params "$@"
    run
}

main "$@"
