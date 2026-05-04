#!/bin/sh
# entrypoint.sh — runs as root inside the container; fixes permissions
# on docker-managed volumes (which are root-owned by default) then drops
# to the `agent` user (uid 1000) before exec'ing the shim.
#
# This pattern is necessary because:
#   - /home/agent/.chaos is mounted from a docker volume that's root-owned
#     when first created — the agent user can't write to it
#   - chaos creates SQLite DBs under ~/.chaos and needs write access
#   - We can't predict whether the host has done chown before bringing the
#     container up, so the container fixes its own permissions on boot

set -e

AGENT_HOME=/home/agent

# Ensure the chaos-home volume is writable by uid 1000 (the agent user).
# `chown -R` is idempotent — no-op if already correct.
if [ -d "$AGENT_HOME/.chaos" ]; then
    chown -R 1000:1000 "$AGENT_HOME/.chaos" || true
fi

# Identity volume (bind-mounted, typically read-only). Don't chown it; the host
# owns the bind-mount and we shouldn't surprise the user by changing ownership.

# Drop to the `agent` user and exec the shim.
exec gosu agent "$@"
