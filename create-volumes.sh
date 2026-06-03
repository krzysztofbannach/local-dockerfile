#!/usr/bin/env bash

set -euo pipefail

# Only named volumes that cannot be replaced by host bind-mounts.
# gh-config, dtctl-config, bbctl-config, junoctl-config have all been replaced
# by host bind-mounts or env-var token injection in run.sh.
VOLUMES=(
    local-dev-go-pkg-path   # Go library cache
    claude-state            # Claude Code state: settings, skills, projects, todos, ...
    icm-data                # ICM persistent memory database (SQLite)
)

echo "Creating Docker named volumes..."
for vol in "${VOLUMES[@]}"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "  [skip]    $vol  (already exists)"
    else
        docker volume create "$vol"
        echo "  [created] $vol"
    fi
done
echo "Done."
