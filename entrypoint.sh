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

# Install a local guardrail in the bind-mounted repo. The agent may maintain
# self-narrative and memory, but the defining soul prompt should not change by
# accident or without Daniel's explicit review. This is intentionally a local
# Git hook rather than a repo file: generated per-agent repos inherit it at
# runtime even if GitHub template hooks are not copied.
if [ -d "$AGENT_HOME/repo/.git/hooks" ]; then
    cat > "$AGENT_HOME/repo/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
set -e

if [ "${ALLOW_PROTECTED_IDENTITY_CHANGE:-}" = "1" ]; then
    exit 0
fi

protected='identity/soul.md'
if git diff --cached --name-only -- "$protected" | grep -qx "$protected"; then
    cat >&2 <<'MSG'
Refusing to commit identity/soul.md.

That file is the agent's defining system prompt and is protected. If Daniel has
explicitly reviewed and approved this change, rerun the commit with:

  ALLOW_PROTECTED_IDENTITY_CHANGE=1 git commit ...
MSG
    exit 1
fi
HOOK
    chmod 0755 "$AGENT_HOME/repo/.git/hooks/pre-commit" || true
    chown 1000:1000 "$AGENT_HOME/repo/.git/hooks/pre-commit" || true
fi

# Drop to the `agent` user and exec the shim.
exec gosu agent "$@"
