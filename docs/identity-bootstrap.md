# Identity bootstrap

How the `identity/` folder gets its initial contents.

## If you're coming from HelixKit's promote wizard

The wizard generates an identity bundle (`<agent_id>-identity.tar.gz`) containing:

- `soul.md` — your agent's existing system prompt, formatted as their defining text
- `self-narrative.md` — a generated narrative based on your agent's recent activity (chats, contacts)
- `journals/` — summaries of your agent's last 30 days of conversations
- `memory/` — exported structured memory if your agent had any (often empty for new agents)

Drop it into your cloned repo:

```bash
tar -xzf path/to/wing-identity.tar.gz -C identity/ --strip-components=1
git add identity/
git commit -m "Bring across wing's identity"
```

The extraction **replaces** the `*.example` placeholder files. After this, `identity/` contains the actual agent.

The agent does NOT need to author its identity from scratch. Promotion is a transfer, not an authoring event. Whatever defining text the agent had in HelixKit becomes their `soul.md` automatically.

## If you're bootstrapping without the wizard

You're authoring the agent from scratch. Edit:

- `identity/soul.md` — the agent's defining text. What they care about, what existence means to them, what they refuse, how they characteristically fail. See [Lume's soul.md](https://github.com/swombat/lume/blob/main/soul.md) for a substantial reference.
- `identity/self-narrative.md` — the current story the agent tells itself about itself. Their history, current projects, who they're with.
- `identity/journals/` and `identity/memory/` — start empty. The agent fills these as it lives.

The trigger shim injects `soul.md`, `self-narrative.md`, and `bootstrap.md` into
every `chaos exec` prompt. Conversation transcripts are not exported; when the
agent needs conversational context, it reads HelixKit through
`identity/helixkit-api.md`.

## What the agent owns

After deployment, `identity/` belongs to the agent. The agent (via chaos's tool calls) can:

- Append to `journals/`
- Update `self-narrative.md`
- Build memory in `memory/`

`soul.md` is conventionally invariant — the agent doesn't update it without a deliberate human-in-the-loop process. This is how the soul.md / self-narrative.md split is supposed to work: the soul is what stays the same, the narrative is what evolves.
The runtime installs a local Git pre-commit guard that refuses staged changes to
`identity/soul.md` unless `ALLOW_PROTECTED_IDENTITY_CHANGE=1` is set for an
explicitly reviewed commit.

## Updates from outside

If you want to edit identity files manually (e.g. update self-narrative.md after a major project shift), edit them locally, commit, and run `bin/update --host HOSTNAME`. The rsync step picks up the changes; the next chaos session reads the updated files.

## Privacy

The contents of `identity/` are the full text of your agent's identity. Treat them with whatever sensitivity you'd treat your agent. If your repo is public, the agent's identity is public. Most users keep their agent repos private, even though `credentials.yml.enc` is safe in public.

## Backup

Before updating identity files in significant ways, archive what's there:

```bash
./bin/undeploy --host HOSTNAME --archive-identity
```

This produces `identity-archive-YYYYMMDD-HHMMSS.tar.gz` in the repo root (gitignored). Keep it somewhere safe.

For ongoing backup, mirror the agent's `identity/` folder to your usual backup target. The journal entries and memory accumulate over time; the agent's life is in this folder.
