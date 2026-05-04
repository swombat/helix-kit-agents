#!/usr/bin/env python3
"""
trigger_shim.py — the HTTP-to-chaos-exec bridge.

Runs inside each chaos-agent container. Listens on port 4000.
HelixKit POSTs a trigger payload here; we shell out to `chaos exec`.

This is intentionally dumb: no business logic, no state, no decision-making.
If it grows past ~200 lines, you've built the wrong thing.

Endpoints:
    GET  /health          — liveness check (no auth)
    POST /trigger         — invoke chaos with a prompt (bearer-token auth)

Trigger payload:
    {
      "session_id": "claude-WYNWQe",   # arbitrary, used for chaos session resume
      "prompt": "Reply to the last message in chat WYNWQe.",
      "model": "claude-sonnet-4-5"     # optional; falls back to AGENT_DEFAULT_MODEL env
    }

Env vars (read at startup):
    AGENT_ID                  identifier for this agent (used in logs)
    TRIGGER_BEARER_TOKEN      required; the bearer token HelixKit must send on /trigger
    AGENT_DEFAULT_MODEL       default model name (e.g. "claude-haiku-4-5")
    AGENT_PROVIDER            chaos provider override (e.g. "anthropic")
    SHIM_PORT                 port to listen on (default 4000)
    CHAOS_BIN                 path to chaos binary (default /usr/local/bin/chaos)
    CHAOS_TIMEOUT_SECS        max seconds for a single chaos exec call (default 600)
"""

import os
import subprocess
import logging
from flask import Flask, request, jsonify, abort

# ----- config -----
AGENT_ID = os.environ.get("AGENT_ID", "unknown")
TRIGGER_BEARER_TOKEN = os.environ.get("TRIGGER_BEARER_TOKEN", "")
AGENT_DEFAULT_MODEL = os.environ.get("AGENT_DEFAULT_MODEL", "claude-haiku-4-5")
AGENT_PROVIDER = os.environ.get("AGENT_PROVIDER", "anthropic")
SHIM_PORT = int(os.environ.get("SHIM_PORT", "4000"))
CHAOS_BIN = os.environ.get("CHAOS_BIN", "/usr/local/bin/chaos")
CHAOS_TIMEOUT_SECS = int(os.environ.get("CHAOS_TIMEOUT_SECS", "600"))

logging.basicConfig(
    level=logging.INFO,
    format=f"%(asctime)s [{AGENT_ID}] %(levelname)s %(message)s",
)
log = logging.getLogger(AGENT_ID)

if not TRIGGER_BEARER_TOKEN:
    log.error("TRIGGER_BEARER_TOKEN not set; shim will reject all /trigger calls. Refusing to start.")
    raise SystemExit(2)

app = Flask(__name__)


# ----- routes -----
@app.get("/health")
def health():
    return jsonify({"status": "ok", "agent_id": AGENT_ID, "version": _chaos_version()})


@app.post("/trigger")
def trigger():
    auth = request.headers.get("Authorization", "")
    if auth != f"Bearer {TRIGGER_BEARER_TOKEN}":
        log.warning("rejected /trigger: bad auth")
        abort(401)

    payload = request.get_json(silent=True) or {}
    session_id = payload.get("session_id")
    prompt = payload.get("prompt")
    model = payload.get("model", AGENT_DEFAULT_MODEL)

    if not session_id or not prompt:
        return jsonify({"error": "session_id and prompt are required"}), 400

    log.info(f"trigger session_id={session_id} model={model} prompt_len={len(prompt)}")

    try:
        result = subprocess.run(
            [
                CHAOS_BIN, "exec",
                "--provider", AGENT_PROVIDER,
                "--skip-git-repo-check",
                "-m", model,
                # NOTE: --resume <session_id> only works for an existing session.
                # For the first turn we omit it; subsequent turns pass it. The shim
                # does not currently track first-vs-subsequent — chaos will create
                # a new session on the first call. Caller can persist the
                # returned session_id from chaos's stdout if needed.
                # TODO: implement session-id persistence properly once we know the
                # chaos session-id format from real runs.
                prompt,
            ],
            capture_output=True,
            text=True,
            timeout=CHAOS_TIMEOUT_SECS,
        )
    except subprocess.TimeoutExpired:
        log.error(f"chaos exec timed out after {CHAOS_TIMEOUT_SECS}s")
        return jsonify({"status": "timeout", "session_id": session_id}), 504

    response = {
        "status": "ok" if result.returncode == 0 else "error",
        "session_id": session_id,
        "returncode": result.returncode,
        "stdout": _tail(result.stdout, 4000),
        "stderr": _tail(result.stderr, 4000),
    }
    log.info(f"trigger done session_id={session_id} rc={result.returncode}")
    return jsonify(response), (200 if result.returncode == 0 else 500)


# ----- helpers -----
def _tail(s: str, n: int) -> str:
    """Trim long stdout/stderr so HelixKit doesn't choke on huge payloads."""
    if not s:
        return ""
    if len(s) <= n:
        return s
    return f"...[truncated {len(s) - n} chars]...\n{s[-n:]}"


def _chaos_version() -> str:
    try:
        out = subprocess.run([CHAOS_BIN, "--version"], capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or "unknown"
    except Exception as e:
        return f"error: {e}"


if __name__ == "__main__":
    log.info(f"chaos-agent shim starting: port={SHIM_PORT}, chaos={_chaos_version()}")
    # 0.0.0.0 because we're inside a container; the daemon binds to all interfaces
    # and Docker handles which are externally exposed.
    app.run(host="0.0.0.0", port=SHIM_PORT, debug=False)
