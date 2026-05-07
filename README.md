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
    │ subprocess: chaos exec --provider <provider> -m <model> "<prompt>"
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
   - Generate `credentials.yml.enc` (encrypted with the master key)
   - Generate an identity bundle (`<agent_id>-identity.tar.gz`)
2. Clone this repo:
   ```bash
   git clone https://github.com/swombat/helix-kit-agents.git my-agent
   cd my-agent
   git remote remove origin
   ```
3. Drop in the identity bundle:
   ```bash
   tar -xzf path/to/wing-identity.tar.gz -C identity/ --strip-components=1
   ```
4. Drop in the encrypted credentials:
   ```bash
   # Save the encrypted blob from the wizard as credentials.yml.enc
   cp path/to/credentials.yml.enc .
   ```
5. Configure your deploy:
   ```bash
   cp deploy.yml.example deploy.yml
   vim deploy.yml   # set agent_id, endpoint_url, image_tag
   ```
6. On your deploy host, set up the master key + LLM provider key:
   ```bash
   ssh your-server.example.com 'install -d -m 700 /etc/helix-kit-agents/wing'
   ssh your-server.example.com 'cat > /etc/helix-kit-agents/wing/master.key' < master.key.txt
   ssh your-server.example.com 'echo "ANTHROPIC_API_KEY=sk-ant-..." > /etc/helix-kit-agents/wing/.host-env'
   ```
7. Deploy:
   ```bash
   ./bin/deploy --host your-server.example.com
   ```

The `bin/deploy` script handles the rest: rsync, decrypt credentials, build image, compose up, health-check, and announce to HelixKit's Rails app. Once running, the agent reaches HelixKit with `curl` using `HELIXKIT_APP_URL` and `HELIXKIT_BEARER_TOKEN`; the API reference lives in `identity/helixkit-api.md`.

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

- **`master.key`** (your responsibility): the 32-byte key that decrypts `credentials.yml.enc`. Lives only on your deploy host (or in your password manager). Gitignored.
- **`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / etc.** (your responsibility): your LLM provider key. Lives only on your deploy host (e.g. `/etc/helix-kit-agents/<agent>/.host-env`). Never enters the repo.

Everything else (the bearer tokens for the HelixKit ↔ agent communication) is managed inside the encrypted `credentials.yml.enc` and decrypted at deploy time.

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
| `bin/deploy --host HOSTNAME` | full deploy: rsync, generate-env on host, build, compose up, health, announce |
| `bin/deploy --local` | same but against the local Docker daemon |
| `bin/generate-env` | decrypt credentials, compose `.env` from credentials + host LLM keys |
| `bin/announce --host HOSTNAME` | re-post announce only (idempotent) |
| `bin/undeploy --host HOSTNAME [--archive-identity]` | stop the container; optionally tar.gz `identity/` first |
| `bin/update --host HOSTNAME [--reannounce]` | rebuild and roll the container |

## Troubleshooting

**"libdbus-1.so.3: cannot open shared object file"** — the runtime image is missing libdbus. Already baked into the Dockerfile; if you've customised it, ensure `libdbus-1-3` is installed in the runtime stage.

**"chaos accounts --with-api-key" reports success but exec can't find the key** — set the API key as an env var directly (e.g. `ANTHROPIC_API_KEY=...` in `.host-env`) rather than relying on chaos's stored connection. The Docker volume permissions can be flaky.

**Announce returns 401** — the trigger bearer token in your decrypted credentials doesn't match what HelixKit has on file. Rotate via the HelixKit UI (agent settings → rotate trigger token) and re-deploy.

**Health check times out** — ssh into the host, `docker logs agent-<agent_id>`, look for chaos errors. Common: missing LLM provider key.

## Architecture references

- HelixKit harness pilot architecture (private; ask Daniel)
- chaos: <https://github.com/seuros/chaos>
## License

Apache 2.0. See LICENSE.

## Status

v1, in active development. The local-Docker path has been smoke-tested. The remote `--host` path has been written but not yet exercised against a production VPS — see `docs/deploy.md` for caveats.
