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

# Repo volume. This is the agent's git working tree, so the agent user needs
# write access for commits and pushes. The /home/agent/identity path remains as
# the stable identity location expected by prompts and existing scripts.
if [ -d "$AGENT_HOME/repo" ]; then
    chown -R 1000:1000 "$AGENT_HOME/repo" || true
    if [ -d "$AGENT_HOME/repo/identity" ]; then
        rm -rf "$AGENT_HOME/identity"
        ln -s "$AGENT_HOME/repo/identity" "$AGENT_HOME/identity"
    fi
fi

# Some chaos providers read API keys directly from the environment (Anthropic),
# while others require a provider account entry under the agent user's
# ~/.chaos (OpenAI at the pinned chaos revision). Seed those account entries
# opportunistically from host-supplied env vars on every boot. This writes into
# the persisted chaos-home volume and is idempotent; never echo the key.
register_provider_key() {
    provider="$1"
    key="$2"
    if [ -n "$key" ]; then
        printf '%s' "$key" | gosu agent chaos accounts --provider "$provider" --with-api-key >/dev/null 2>&1 || true
    fi
}

register_provider_key anthropic "$ANTHROPIC_API_KEY"
register_provider_key openai "$OPENAI_API_KEY"

# Drop to the `agent` user and exec the shim.
exec gosu agent "$@"
