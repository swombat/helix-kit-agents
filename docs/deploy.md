# Deploying

The normal path is intentionally short:

```bash
# in the per-agent repo cloned from GitHub
printf '%s' '<master-key-from-HelixKit>' > master.key
chmod 600 master.key
bin/deploy --vm
```

`bin/deploy --vm` targets the standard HelixKit agent VM. By default it uses
`vm_host: helix-agents` from `deploy.yml` (or the same fallback if the key is
omitted). You can override it only when needed:

```bash
bin/deploy --vm other-agent-vm
```

What the command does:

1. Uploads `master.key` to `/etc/helix-kit-agents/<agent_id>/master.key` on the VM.
2. Rsyncs the repo to `/var/lib/agents/<agent_id>/`.
3. Decrypts `credentials.yml.enc` on the VM and writes `.env`.
4. Writes the encrypted GitHub deploy key to `.agent-deploy-key`.
5. Runs Docker Compose to build/start the runtime.
6. Polls `<endpoint_url>/health`.
7. Announces the endpoint back to HelixKit.

Provider API keys are normally encrypted into `credentials.yml.enc` by HelixKit
from its own configured RubyLLM provider keys. You should not need to paste an
Anthropic/OpenAI/etc. key per agent. Host env remains an override for unusual
manual deployments.

## Prerequisites for the standard VM

One-time VM setup, not per agent:

- SSH alias or hostname from `deploy.yml` (`helix-agents` by default).
- Docker 24+ with Compose v2.
- Python 3 with `cryptography` and `yaml` available (`python3-cryptography` and
  `python3-yaml` on Debian/Ubuntu).
- `rsync`.
- Network/DNS/proxy routing such that each agent's `endpoint_url` reaches that
  agent's exposed shim port.

## Generated deploy.yml

HelixKit commits a prefilled `deploy.yml` into the per-agent repo. Review only if
needed:

```yaml
agent_id: claude
endpoint_url: https://claude.helix-agents.granttree.co.uk
provider: anthropic
model: claude-haiku-4-5
shim_port: 4000
vm_host: helix-agents
```

For multiple agents on one VM, each agent needs a distinct externally reachable
endpoint. The default template uses a per-agent subdomain. If your VM/proxy uses
ports instead, set both `endpoint_url` and `shim_port` accordingly.

## Advanced modes

### Local Docker test

```bash
printf '%s' '<master-key>' > master.key
chmod 600 master.key
bin/deploy --local
```

### Manual host mode

`--host` is kept for unusual/manual deployments. Unlike `--vm`, it assumes the
master key is already on the host at `/etc/helix-kit-agents/<agent_id>/master.key`:

```bash
bin/deploy --host some-host
```

## Updating

When you change the Dockerfile, `trigger_shim.py`, or identity files:

```bash
bin/update --vm
```

Pass `--reannounce` if you want to re-post the endpoint to HelixKit.

## Stopping

```bash
bin/undeploy --host helix-agents
```

This stops the container but leaves the VM's repo copy and Chaos home volume in
place. Re-running `bin/deploy --vm` brings it back.
