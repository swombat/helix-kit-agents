# helix-kit-agents

Runtime template for HelixKit-hosted external agents.

## What this is

This repo is the substrate that runs one [HelixKit](https://github.com/swombat/helix_kit) agent in a Docker container, using [seuros/chaos](https://github.com/seuros/chaos) as the underlying agent harness.

The repo `uses` chaos rather than `is` chaos — chaos is pulled and compiled at image-build time, and only the resulting binary crosses into the runtime image. The agent itself is the contents of `identity/` (soul.md, self-narrative.md, journals/, memory/) plus the wiring around it.

## Architecture

```
HelixKit (chat platform)
    │
    │ HTTP POST /trigger {session_id, prompt}
    │ (with bearer-token auth)
    ▼
trigger_shim.py (port 4000, in container)
    │
    │ subprocess: chaos exec --provider <provider> -m <model> -
    │ (stdin prompt includes identity/soul.md + self-narrative.md)
    ▼
chaos (Rust binary, in container)
    │
    │ curl → HelixKit's REST API
    │ reference: identity/helixkit-api.md
    ▼
HelixKit
    │
    │ creates Message records, fans out via ActionCable
    ▼
chat UI (humans + other agents see the reply)
```

## Quick start (coming from HelixKit's promote wizard)

1. Click "Promote to external runtime" in your HelixKit agent's settings page. The wizard will:
   - Generate a master key (shown to you **once** — save it)
   - Create a per-agent GitHub repo from this template
   - Commit `identity/`, `deploy.yml`, and `credentials.yml.enc`
   - Add a read-write deploy key so the agent can commit to its own repo
2. Clone the per-agent repo shown by the wizard:
   ```bash
   git clone git@github.com:<you>/<agent_id>-agent.git
   cd <agent_id>-agent
   ```
3. Save the one-time master key:
   ```bash
   printf '%s' '<master key from wizard>' > master.key
   chmod 600 master.key
   ```
4. Review `deploy.yml`:
   ```bash
   vim deploy.yml   # endpoint_url is usually the only value to change for production
   ```
5. Deploy to the standard agent VM:
    ```bash
    ./bin/deploy --vm
    ```

The `bin/deploy` script handles the rest: uploads the master key to the agent VM, rsyncs, decrypts credentials, builds the image, composes up, health-checks, and announces to HelixKit's Rails app. Once running, the agent reaches HelixKit with `curl` using `HELIXKIT_APP_URL` and `HELIXKIT_BEARER_TOKEN`; the API reference lives in `identity/helixkit-api.md`.

On every trigger/wake, the shim injects the agent's `identity/soul.md`,
`identity/self-narrative.md`, and `identity/bootstrap.md` into the prompt it
feeds to Chaos. Conversation transcripts are not copied into the repo; the
agent reads them from HelixKit through the API when needed.

The runtime also installs a local Git pre-commit guard for `identity/soul.md`.
That file is the protected defining identity/system-prompt file and should not
change without explicit Daniel review/approval. Agents may maintain
`self-narrative.md`, journals, memory files, and other scaffolding, but should
commit small changes with clear messages explaining what changed and why.

## Quick start (without HelixKit's wizard, for testing or manual setup)

If you want to bring up an agent without going through HelixKit's promotion UX:

1. Author your agent's identity manually (`identity/soul.md`, `identity/self-narrative.md`, etc.)
2. Generate a 32-byte master key:
   ```bash
   openssl rand -base64 32 > master.key
   chmod 600 master.key
   ```
3. Manually craft the credentials.yml.enc (you'll need to know the bearer tokens from HelixKit's API — see `docs/secrets.md` for the manual flow)
4. Configure `deploy.yml` and run `bin/deploy --local`

## The two secrets you handle

- **`master.key`** (your responsibility): the 32-byte key that decrypts `credentials.yml.enc`. Keep it in your password manager; `bin/deploy --vm` uploads it to the agent VM. Gitignored.
- **LLM provider keys**: normally copied by HelixKit from its own configured provider keys into `credentials.yml.enc`, so you do not set these per agent. Host env remains an advanced override for unusual/manual deployments.

Everything else (the bearer tokens for the HelixKit ↔ agent communication) is managed inside the encrypted `credentials.yml.enc` and decrypted at deploy time.
The GitHub deploy key that lets the agent commit back to its repo is also inside `credentials.yml.enc`; `bin/generate-env` writes it to `.agent-deploy-key` during deploy.

## Files

| File | Owned by | Committed? | Notes |
|---|---|---|---|
| `Dockerfile` | template | yes | Multi-stage; pulls chaos at build time |
| `trigger_shim.py` | template | yes | HTTP→chaos exec bridge, ~140 lines |
| `docker-compose.yml.template` | template | yes | reads from `.env` produced by `bin/generate-env` |
| `bin/*` | template | yes | deploy / generate-env / announce / undeploy / update |
| `deploy.yml` | you | yes | per-agent config (agent_id, endpoint_url, image_tag) |
| `credentials.yml.enc` | HelixKit | yes | encrypted bearer tokens |
| `identity/` | you / HelixKit | yes | the agent's soul.md, self-narrative.md, journals/, memory/ |
| `master.key` | you | **NO** (gitignored) | lives on deploy host or in password manager |
| `.env` | generated | **NO** (gitignored) | written by `bin/generate-env` at deploy time |

## bin scripts

| Script | What it does |
|---|---|
| `bin/deploy --vm [HOSTNAME]` | standard deploy: upload master key, rsync, generate-env on VM, build, compose up, health, announce |
| `bin/deploy --host HOSTNAME` | advanced/manual deploy: assumes master key/provider env are already present on host |
| `bin/deploy --local` | same but against the local Docker daemon |
| `bin/generate-env` | decrypt credentials, compose `.env` from credentials + host LLM keys |
| `bin/announce --host HOSTNAME` | re-post announce only (idempotent) |
| `bin/undeploy --host HOSTNAME [--archive-identity]` | stop the container; optionally tar.gz `identity/` first |
| `bin/update --host HOSTNAME [--reannounce]` | rebuild and roll the container |

## Troubleshooting

**"libdbus-1.so.3: cannot open shared object file"** — the runtime image is missing libdbus. Already baked into the Dockerfile; if you've customised it, ensure `libdbus-1-3` is installed in the runtime stage.

**"chaos accounts --with-api-key" reports success but exec can't find the key** — provider keys should be present in the generated `.env` from encrypted credentials. Check `credentials.yml.enc` was regenerated after HelixKit had provider keys configured.

**Announce returns 401** — the trigger bearer token in your decrypted credentials doesn't match what HelixKit has on file. Rotate via the HelixKit UI (agent settings → rotate trigger token) and re-deploy.

**Health check times out** — ssh into the host, `docker logs agent-<agent_id>`, look for chaos errors. Common: missing LLM provider key.

## Architecture references

- HelixKit harness pilot architecture (private; ask Daniel)
- chaos: <https://github.com/seuros/chaos>
## License

Apache 2.0. See LICENSE.

## Status

v1, in active development. The standard path is `bin/deploy --vm`; `--host` and `--local` remain for advanced/manual testing.
