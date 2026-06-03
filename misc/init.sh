#!/usr/bin/env bash
#
# Sourced at every bash login via /etc/profile.d/.
# Handles per-session setup that cannot be baked into the image.
#

# acli-pii: the OS keyring does not exist in a container.  The tool's file-based
# fallback is write-only — auth status always reads from keyring and always fails
# in a fresh container.  Re-running auth login at session start is the only way
# to establish auth.  The login command itself uses the file fallback and
# completes in ~200 ms.  Credentials from the previous run are on the
# bind-mounted ~/.acli-pii/ but only serve as a cache hint; we always re-auth.
if command -v acli-pii >/dev/null 2>&1 \
    && [ -n "${ACLI_JIRA_TOKEN:-}" ] \
    && [ -n "${ACLI_JIRA_EMAIL:-}" ] \
    && [ -n "${ACLI_JIRA_SITE:-}" ]; then
  printf '%s\n' "$ACLI_JIRA_TOKEN" | acli-pii jira auth login \
    --site "$ACLI_JIRA_SITE" --email "$ACLI_JIRA_EMAIL" --token \
    >/dev/null 2>&1 || true
fi
