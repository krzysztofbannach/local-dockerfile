#!/usr/bin/env bash
#
# AI dev environment bootstrap.
#
# Idempotent — safe to run on every container start. Only acts on what is
# missing or out-of-date. Designed to be run inside a Docker container whose
# stateful directories are mounted as volumes (see docker-compose.snippet.yml).
#
# Phases:
#   1. PATH setup
#   2. Public binaries  (dtctl, gh, rtk, icm)
#   3. Auth status check
#   4. Private binaries (bbctl, junoctl, acli-pii)  — requires gh auth
#   5. Juno skills                                  — requires junoctl auth
#   6. Juno MCP server registration
#   7. ICM hooks initialization
#   8. claude update
#   9. Summary + pending auth hints
#
# Multi-pass model: missing auths print instructions and the script exits 0.
# Run gh/dtctl/bbctl/junoctl/acli-pii auth, then re-run this script to fill
# in everything that depended on those auths.

set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# Configuration
# ───────────────────────────────────────────────────────────────────────────

BIN_DIR="$HOME/.claude/skills/bin"
PROFILE="${BOOTSTRAP_PROFILE:-$HOME/.bashrc}"
SKILLS=(dt-github dt-atlassian-pii dt-bbctl dt-juno-mcp dt-skill-creator dynatrace-control dt-slides)
MCP_URL="https://juno-mcp.production.juno-ape.internal.dynatracelabs.com/mcp"

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|amd64)
    ARCH_GO=amd64
    ARCH_RUST=x86_64-unknown-linux-gnu
    ARCH_ICM=x86_64-unknown-linux-gnu
    ;;
  aarch64|arm64)
    ARCH_GO=arm64
    ARCH_RUST=aarch64-unknown-linux-gnu
    ARCH_ICM=aarch64-unknown-linux-gnu
    ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW" >&2
    exit 1
    ;;
esac

# ───────────────────────────────────────────────────────────────────────────
# Output helpers
# ───────────────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi

ok()    { echo "${C_G}OK${C_0}     $*"; }
skip()  { echo "${C_G}OK${C_0}     $* (already present)"; }
todo()  { echo "${C_Y}TODO${C_0}   $*"; }
fail()  { echo "${C_R}FAIL${C_0}   $*"; }
hdr()   { echo; echo "${C_B}── $* ──${C_0}"; }

PENDING=()
add_pending() { PENDING+=("$1"); }

# ───────────────────────────────────────────────────────────────────────────
# Phase 1 — PATH
# ───────────────────────────────────────────────────────────────────────────

hdr "PATH"

mkdir -p "$BIN_DIR"
if ! grep -qF '.claude/skills/bin' "$PROFILE" 2>/dev/null; then
  echo 'export PATH="$HOME/.claude/skills/bin:$HOME/.local/bin:$PATH"' >> "$PROFILE"
  ok "Added $BIN_DIR (and ~/.local/bin) to PATH in $PROFILE"
else
  skip "$BIN_DIR in $PROFILE"
fi
export PATH="$BIN_DIR:$HOME/.local/bin:$PATH"

# ───────────────────────────────────────────────────────────────────────────
# Phase 2 — Public binaries
# ───────────────────────────────────────────────────────────────────────────

hdr "Public binaries"

# Download asset from a public GitHub release.
#   $1 = owner/repo
#   $2 = asset filename (literal)
#   $3 = destination file
fetch_public_asset() {
  local repo="$1" asset="$2" dest="$3"
  curl -fsSL "https://github.com/$repo/releases/latest/download/$asset" -o "$dest"
}

install_dtctl() {
  if command -v dtctl >/dev/null 2>&1; then skip "dtctl"; return; fi
  echo "Installing dtctl …"
  local tag asset tmp
  tag=$(curl -fsSL https://api.github.com/repos/dynatrace-oss/dtctl/releases/latest | jq -r .tag_name | sed 's/^v//')
  asset="dtctl_${tag}_linux_${ARCH_GO}.tar.gz"
  tmp=$(mktemp -d)
  fetch_public_asset "dynatrace-oss/dtctl" "$asset" "$tmp/dtctl.tar.gz"
  tar -xzf "$tmp/dtctl.tar.gz" -C "$tmp" dtctl
  mv "$tmp/dtctl" "$BIN_DIR/dtctl"
  chmod +x "$BIN_DIR/dtctl"
  rm -rf "$tmp"
  ok "dtctl $tag"
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then skip "gh"; return; fi
  echo "Installing gh …"
  local tag asset tmp
  tag=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')
  asset="gh_${tag}_linux_${ARCH_GO}.tar.gz"
  tmp=$(mktemp -d)
  fetch_public_asset "cli/cli" "$asset" "$tmp/gh.tar.gz"
  tar -xzf "$tmp/gh.tar.gz" -C "$tmp"
  mv "$tmp/gh_${tag}_linux_${ARCH_GO}/bin/gh" "$BIN_DIR/gh"
  chmod +x "$BIN_DIR/gh"
  rm -rf "$tmp"
  ok "gh $tag"
}

install_rtk() {
  if command -v rtk >/dev/null 2>&1; then skip "rtk"; return; fi
  echo "Installing rtk …"
  # rtk publishes musl for x86_64, gnu for aarch64
  local asset tmp
  case "$ARCH_RAW" in
    x86_64|amd64)  asset="rtk-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64) asset="rtk-aarch64-unknown-linux-gnu.tar.gz" ;;
  esac
  tmp=$(mktemp -d)
  fetch_public_asset "rtk-ai/rtk" "$asset" "$tmp/rtk.tar.gz"
  tar -xzf "$tmp/rtk.tar.gz" -C "$tmp" rtk
  mv "$tmp/rtk" "$BIN_DIR/rtk"
  chmod +x "$BIN_DIR/rtk"
  rm -rf "$tmp"
  ok "rtk"
}

ICM_USABLE=0
check_icm_glibc() {
  # icm releases are dynamically linked against GLIBC 2.39 (Ubuntu 24.04+/Debian Trixie+).
  # Older base images can't run it; no musl build is published upstream.
  local v
  v=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' | head -1)
  if [ -z "$v" ]; then ICM_USABLE=1; return; fi
  # Compare as floats: 2.39 required
  awk -v have="$v" -v need=2.39 'BEGIN { exit (have+0 >= need+0) ? 0 : 1 }' \
    && ICM_USABLE=1 \
    || ICM_USABLE=0
  if [ "$ICM_USABLE" -eq 0 ]; then
    todo "icm: container GLIBC $v is too old (icm needs >= 2.39 — Ubuntu 24.04 / Debian Trixie). Skipping. Upgrade base image, or build icm from source via 'cargo install icm-cli'."
    add_pending "Upgrade base image to a GLIBC 2.39+ distro (Ubuntu 24.04 / Debian Trixie) so icm can run"
  fi
}

install_icm() {
  check_icm_glibc
  [ "$ICM_USABLE" -eq 1 ] || return 0
  if command -v icm >/dev/null 2>&1; then skip "icm"; return; fi
  echo "Installing icm …"
  local asset tmp
  asset="icm-${ARCH_ICM}.tar.gz"
  tmp=$(mktemp -d)
  fetch_public_asset "rtk-ai/icm" "$asset" "$tmp/icm.tar.gz"
  tar -xzf "$tmp/icm.tar.gz" -C "$tmp" icm
  mv "$tmp/icm" "$BIN_DIR/icm"
  chmod +x "$BIN_DIR/icm"
  rm -rf "$tmp"
  ok "icm"
}

install_dtctl
install_gh
install_rtk
install_icm

# ───────────────────────────────────────────────────────────────────────────
# Phase 3 — Auth status
# ───────────────────────────────────────────────────────────────────────────

hdr "Auth status"

GH_AUTHED=0
DTCTL_AUTHED=0
BBCTL_AUTHED=0
JUNOCTL_AUTHED=0
ACLI_AUTHED=0

# gh: GH_TOKEN env var is injected by run.sh from the host GNOME Keyring.
# gh CLI automatically uses GH_TOKEN without needing 'gh auth login'.
if [ -n "${GH_TOKEN:-}" ] || { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }; then
  ok "gh authenticated"; GH_AUTHED=1
else
  todo "gh: GH_TOKEN env var not set — run.sh injects it automatically from the host GNOME Keyring (requires secret-tool on host)"
  add_pending "gh: ensure run.sh is run on a host that has libsecret-tools installed"
fi

if command -v dtctl >/dev/null 2>&1 && dtctl auth whoami >/dev/null 2>&1; then
  ok "dtctl authenticated"; DTCTL_AUTHED=1
else
  todo "dtctl: run 'dtctl auth login' — use --network=host if OAuth callback is needed"
  add_pending "dtctl: run 'dtctl auth login'"
fi

# bbctl/junoctl/acli-pii auth checks happen *after* their binaries exist;
# we only print them later once the binary is installed.

# ───────────────────────────────────────────────────────────────────────────
# Phase 4 — Private binaries (needs gh auth)
# ───────────────────────────────────────────────────────────────────────────

hdr "Private binaries"

if [ "$GH_AUTHED" -ne 1 ]; then
  todo "Skipping bbctl / junoctl / acli-pii install — needs gh auth first"
else
  install_private_release() {
    local cmd="$1" repo="$2" pattern="$3"
    if command -v "$cmd" >/dev/null 2>&1; then skip "$cmd"; return; fi
    echo "Installing $cmd from $repo …"
    local tmp
    tmp=$(mktemp -d)
    local tag
    tag=$(gh release list --repo "$repo" --limit 1 --json tagName -q '.[0].tagName')
    gh release download "$tag" --repo "$repo" --pattern "$pattern" --output "$tmp/asset" --clobber
    # Heuristic: tar.gz vs raw binary vs zip
    case "$pattern" in
      *.tar.gz|*.tgz)
        tar -xzf "$tmp/asset" -C "$tmp"
        # Find the actual binary by name
        local found
        found=$(find "$tmp" -type f -name "$cmd" | head -1)
        [ -z "$found" ] && { fail "$cmd: binary not found in archive"; return 1; }
        mv "$found" "$BIN_DIR/$cmd"
        ;;
      *.zip)
        unzip -o "$tmp/asset" -d "$tmp" >/dev/null
        local found
        found=$(find "$tmp" -type f -name "$cmd" | head -1)
        [ -z "$found" ] && { fail "$cmd: binary not found in archive"; return 1; }
        mv "$found" "$BIN_DIR/$cmd"
        ;;
      *)
        mv "$tmp/asset" "$BIN_DIR/$cmd"
        ;;
    esac
    chmod +x "$BIN_DIR/$cmd"
    rm -rf "$tmp"
    ok "$cmd $tag"
  }

  install_bbctl() {
    # bbctl asset names vary; pick the linux/<arch> archive
    install_private_release bbctl "Dynatrace-Internal/bbctl" "*linux*${ARCH_GO}*.tar.gz" \
      || install_private_release bbctl "Dynatrace-Internal/bbctl" "*linux*${ARCH_GO}*"
  }
  install_junoctl() {
    install_private_release junoctl "Dynatrace-Internal/junoctl" "*linux*${ARCH_GO}*.tar.gz" \
      || install_private_release junoctl "Dynatrace-Internal/junoctl" "*linux*${ARCH_GO}*"
  }

  install_acli_pii() {
    if command -v acli-pii >/dev/null 2>&1; then skip "acli-pii"; return; fi
    echo "Installing acli-pii (committed binary, not a release asset) …"
    local token
    token=$(gh auth token)
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://raw.githubusercontent.com/Dynatrace-Internal/rnd-ai-knowledgebase/main/utils/dt-acli-pii-sanitize/acli-pii-linux" \
      -o "$BIN_DIR/acli-pii"
    chmod +x "$BIN_DIR/acli-pii"
    ok "acli-pii"
  }

  install_bbctl
  install_junoctl
  install_acli_pii
fi

# Now that private binaries exist (or didn't), check their auth status
if command -v bbctl >/dev/null 2>&1; then
  # BB_TOKEN env var is injected by run.sh from the host GNOME Keyring.
  if [ -n "${BB_TOKEN:-}" ] || bbctl auth status >/dev/null 2>&1; then
    ok "bbctl authenticated"; BBCTL_AUTHED=1
  else
    todo "bbctl: BB_TOKEN env var not set — run.sh injects it from the host GNOME Keyring"
    add_pending "bbctl: ensure run.sh injects BB_TOKEN (requires secret-tool on host)"
  fi
fi
if command -v junoctl >/dev/null 2>&1; then
  # JUNOCTL_TOKEN env var (access_token JWT) is injected by run.sh from the host GNOME Keyring.
  # The token expires after ~5 hours; restart the container via ./run.sh to refresh.
  if [ -n "${JUNOCTL_TOKEN:-}" ] || junoctl auth status >/dev/null 2>&1; then
    ok "junoctl authenticated"; JUNOCTL_AUTHED=1
  else
    todo "junoctl: JUNOCTL_TOKEN env var not set — run.sh injects it from the host GNOME Keyring"
    add_pending "junoctl: ensure run.sh injects JUNOCTL_TOKEN (requires secret-tool on host)"
  fi
fi
if command -v acli-pii >/dev/null 2>&1; then
  _acli_err=$(acli-pii jira auth status 2>&1)
  if [ $? -eq 0 ]; then
    ok "acli-pii authenticated"; ACLI_AUTHED=1
  elif [ -n "${ACLI_JIRA_TOKEN:-}" ] && [ -n "${ACLI_JIRA_EMAIL:-}" ] && [ -n "${ACLI_JIRA_SITE:-}" ]; then
    # auth status always checks the OS keyring first and always fails in a container.
    # auth login uses the file fallback (~/.acli-pii/credentials.yaml) — no D-Bus needed.
    if printf '%s\n' "$ACLI_JIRA_TOKEN" | acli-pii jira auth login \
        --site "$ACLI_JIRA_SITE" --email "$ACLI_JIRA_EMAIL" --token >/dev/null 2>&1; then
      ok "acli-pii authenticated (via ACLI_JIRA_TOKEN)"; ACLI_AUTHED=1
    else
      fail "acli-pii: auth login failed — check ACLI_JIRA_TOKEN validity"
      add_pending "acli-pii: token may be invalid — verify at https://id.atlassian.com/manage-profile/security/api-tokens"
    fi
  else
    fail "acli-pii: auth status failed — ${_acli_err}"
    add_pending "acli-pii: run inside container: acli-pii jira auth login --site dt-rnd.atlassian.langdock.internal.dynatrace.com --email krzysztof.bannach@dynatrace.com --token"
  fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 5 — Juno skills (needs junoctl auth)
# ───────────────────────────────────────────────────────────────────────────

hdr "Juno skills"

if [ "$JUNOCTL_AUTHED" -ne 1 ]; then
  todo "Skipping skill install — needs junoctl auth first"
else
  for skill in "${SKILLS[@]}"; do
    dir="$HOME/.claude/skills/$skill"
    if [ -d "$dir" ] && ls "$dir"/*.md >/dev/null 2>&1; then
      skip "skill: $skill"
    else
      echo "Installing skill: $skill"
      if junoctl skills install "$skill" --global --for claude >/dev/null 2>&1; then
        ok "skill: $skill"
      else
        fail "skill: $skill (junoctl skills install failed)"
      fi
    fi
  done
  # Bulk update if anything was already present
  echo "Running junoctl skills update --global --for claude …"
  junoctl skills update --global --for claude >/dev/null 2>&1 && ok "skills update" || fail "skills update"
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 6 — Juno MCP server registration
# ───────────────────────────────────────────────────────────────────────────

hdr "Juno MCP"

if grep -q "$MCP_URL" "$HOME/.claude.json" 2>/dev/null; then
  skip "juno MCP registered"
else
  if command -v claude >/dev/null 2>&1; then
    echo "Registering juno MCP …"
    if claude mcp add --transport http juno "$MCP_URL" >/dev/null 2>&1; then
      ok "juno MCP registered (complete OAuth via '/mcp' in Claude Code)"
      add_pending "Run /mcp inside Claude Code to complete Juno MCP OAuth"
    else
      fail "claude mcp add failed"
    fi
  else
    todo "claude not in PATH — skipping MCP registration"
  fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 7 — ICM hooks init
# ───────────────────────────────────────────────────────────────────────────

hdr "ICM hooks"

if grep -iq "icm" "$HOME/.claude/settings.json" 2>/dev/null; then
  skip "ICM hooks initialized"
elif [ "$ICM_USABLE" -ne 1 ]; then
  todo "Skipping icm init — GLIBC too old (see icm note above)"
elif command -v icm >/dev/null 2>&1; then
  echo "Initializing ICM hooks …"
  if icm init --mode standard; then
    ok "ICM hooks initialized (restart Claude Code to load them)"
  else
    fail "icm init failed"
  fi
else
  todo "icm binary missing — cannot init"
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 8 — claude update
# ───────────────────────────────────────────────────────────────────────────

hdr "claude update"

if command -v claude >/dev/null 2>&1; then
  if claude update 2>&1 | tee /tmp/claude-update.out | grep -qiE 'updated|installed'; then
    ok "claude updated"
  else
    skip "claude already current"
  fi
else
  todo "claude not in PATH — install Claude Code first (https://claude.ai/install.sh)"
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 9 — Caveman plugin
# ───────────────────────────────────────────────────────────────────────────

hdr "Caveman plugin"

if command -v claude >/dev/null 2>&1; then
  if claude plugin list 2>/dev/null | grep -q 'caveman@caveman'; then
    skip "caveman plugin"
  else
    echo "Installing caveman plugin …"
    if claude plugin marketplace add JuliusBrussee/caveman >/dev/null 2>&1 \
       && claude plugin install caveman@caveman >/dev/null 2>&1; then
      ok "caveman plugin installed"
      add_pending "Restart Claude Code to activate caveman plugin"
    else
      fail "caveman plugin install failed"
    fi
  fi
else
  todo "claude not in PATH — skipping caveman install"
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 10 — Slack plugin
# ───────────────────────────────────────────────────────────────────────────

hdr "Slack plugin"

if command -v claude >/dev/null 2>&1; then
  if claude plugin list 2>/dev/null | grep -q 'slack@claude-plugins-official'; then
    skip "slack plugin"
  else
    echo "Installing slack plugin …"
    if claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 \
       && claude plugin install slack@claude-plugins-official >/dev/null 2>&1; then
      ok "slack plugin installed"
      add_pending "Restart Claude Code and complete Slack OAuth to activate slack plugin"
    else
      fail "slack plugin install failed"
    fi
  fi
else
  todo "claude not in PATH — skipping slack plugin install"
fi

# ───────────────────────────────────────────────────────────────────────────
# Phase 11 — Summary
# ───────────────────────────────────────────────────────────────────────────

hdr "Summary"

if [ "${#PENDING[@]}" -eq 0 ]; then
  echo "${C_G}All checks passed. Your environment is ready.${C_0}"
else
  echo "${C_Y}Pending manual steps:${C_0}"
  for step in "${PENDING[@]}"; do
    echo "  - $step"
  done
  echo
  echo "After completing the steps above, re-run this script to install"
  echo "anything that depended on those auths (private binaries, Juno"
  echo "skills, MCP OAuth, etc.)."
fi

echo
echo "PATH for new shells is set in $PROFILE — open a new terminal or run:"
echo "  source $PROFILE"
