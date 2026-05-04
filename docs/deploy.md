# Deploying

The deploy flow has two modes: `--host HOSTNAME` (production) and `--local` (testing against the Docker daemon on your laptop).

## Prerequisites (host mode)

On your deploy host:
- Docker 24+ with Compose v2
- SSH access (key-based, the deploy script uses `BatchMode=yes`)
- `python3` and `python3-cryptography` and `python3-yaml` packages — used by `bin/generate-env` running on the host
- `rsync` (most distros have this by default)

On your local machine:
- `rsync`, `ssh`, `python3` (for running `bin/deploy`)

## First-time setup

### 1. Master key

The master key encrypts your credentials. HelixKit's promote wizard generated it for you and showed it once.

Put it on the deploy host:

```bash
ssh your-server.example.com 'sudo install -d -m 700 -o $USER /etc/helix-kit-agents/wing'
ssh your-server.example.com 'cat > /etc/helix-kit-agents/wing/master.key' <<< "<paste base64 master key>"
ssh your-server.example.com 'chmod 600 /etc/helix-kit-agents/wing/master.key'
```

Verify:

```bash
ssh your-server.example.com 'wc -c /etc/helix-kit-agents/wing/master.key'
# Should print 45 (44 base64 chars + newline)
```

### 2. LLM provider key

The agent needs an LLM API key (Anthropic, OpenAI, etc.). This stays on the host and is loaded by `bin/generate-env`:

```bash
ssh your-server.example.com 'install -m 600 /dev/null /etc/helix-kit-agents/wing/.host-env'
ssh your-server.example.com 'cat > /etc/helix-kit-agents/wing/.host-env' <<EOF
ANTHROPIC_API_KEY=sk-ant-api03-...
EOF
```

Multiple keys are supported — set whichever ones you need. The agent uses the one matching `provider:` in `deploy.yml`.

### 3. deploy.yml

In your local clone:

```bash
cp deploy.yml.example deploy.yml
vim deploy.yml
```

Set:
- `agent_id` — must match the `agent_id` HelixKit baked into your `credentials.yml.enc`
- `endpoint_url` — the externally-reachable URL of this agent's port-4000 trigger shim. If you're terminating TLS at a reverse proxy, set the public URL here.
- `image_tag` — usually `latest` (rebuilds on each deploy). If you've pushed a built image to a registry, set `image:` instead.

Commit:

```bash
git add deploy.yml
git commit -m "Configure deploy.yml for wing"
```

### 4. Deploy

```bash
./bin/deploy --host your-server.example.com
```

What happens:

1. Local validation (deploy.yml, credentials.yml.enc, identity/soul.md exist)
2. SSH connectivity test
3. rsync your repo to `/var/lib/agents/<agent_id>/` on the host (excludes `.git`, `master.key`, `.env`)
4. SSH: run `bin/generate-env` on the host. This decrypts `credentials.yml.enc` using `/etc/helix-kit-agents/<agent_id>/master.key`, sources `.host-env`, writes `/var/lib/agents/<agent_id>/.env`.
5. SSH: `docker compose -p agent-<agent_id> up -d --build`
6. Poll `endpoint_url/health` until 200 (timeout 90s)
7. Configure chaos's MCP client (`chaos mcp add helixkit ...`) on first deploy
8. POST to HelixKit's `/api/v1/agents/<agent_uuid>/announce`

## Local mode (`--local`)

For testing the full pipeline without a remote host:

```bash
# Put master.key in the repo root (gitignored)
echo "<your base64 master key>" > master.key
chmod 600 master.key

# Set your LLM key in env
export ANTHROPIC_API_KEY=sk-ant-...

# Set deploy.yml endpoint_url to http://localhost:4000

./bin/deploy --local
```

The local Docker daemon will build the image, bring up the container, the deploy script will probe `http://localhost:4000/health`, and announce to whatever HelixKit instance the credentials point at (often `http://host.docker.internal:3000/`).

**Caveat:** in `--local` mode the script reads `master.key` from the repo root because there's no host. Don't forget to `rm master.key` (or move it out of the repo) before pushing your code.

## Updating

When you change the Dockerfile, `trigger_shim.py`, or `identity/`:

```bash
./bin/update --host your-server.example.com
```

This re-runs `bin/deploy` minus the announce step (the endpoint hasn't changed). Pass `--reannounce` if you want to re-post anyway.

When you change `credentials.yml.enc` (e.g. you rotated tokens):

```bash
./bin/deploy --host your-server.example.com    # full re-run including announce
```

## Stopping

```bash
./bin/undeploy --host your-server.example.com
```

This stops the container but leaves the chaos session volume and `identity/` data on the host. Re-running `bin/deploy` brings it back up exactly where it was.

To completely remove an agent's data:

```bash
ssh your-server.example.com '
  docker volume rm agent-wing-home
  sudo rm -rf /var/lib/agents/wing
  sudo rm -rf /etc/helix-kit-agents/wing
'
```

## Common pitfalls

- **rsync fails with permission denied on /var/lib/agents/** — the deploy script `sudo install -d`s the directory with your username as owner. If your sudoers config doesn't allow passwordless sudo, run that step manually first.
- **Health check times out at 90s** — chaos cold start is ~120ms but the first build can take 8-12 minutes (compiling chaos from source). Subsequent builds are fast (Docker layer cache). On the first deploy, watch the build with `docker logs -f agent-<agent_id>` from another terminal.
- **`announce failed: HTTP 401`** — your decrypted trigger bearer token doesn't match what HelixKit has. Either the `credentials.yml.enc` is stale (HelixKit has rotated it) or you copy-pasted the wrong blob. Re-run the wizard.
