#!/usr/bin/env python3
"""Container entrypoint for mi-fitness-data-bridge.

Does three things the upstream CLI cannot do unattended:

1. Seeds user_id/passToken into the on-volume keyring from the environment,
   but never overwrites a token the bridge itself rotated (Xiaomi issues a new
   passToken on every login, so the volume copy outranks the Secret copy).
2. Switches SQLite to WAL so the sync job and the MCP server can share one
   database file without blocking each other on a plain rollback journal.
3. Turns `sync-window` into a concrete date range, because CronJobs have no
   notion of "last N days".
"""

import os
import sqlite3
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

BRIDGE = "mi-fitness-bridge"


def _log(message: str) -> None:
    print(f"[entrypoint] {message}", flush=True)


def _db_path() -> Path:
    raw = os.environ.get("MI_FITNESS_DB_PATH")
    if not raw:
        sys.exit("[entrypoint] MI_FITNESS_DB_PATH is required")
    return Path(raw)


def seed_credentials() -> None:
    from mi_fitness_mcp.auth import load_mi_fitness_token, save_mi_fitness_token
    from mi_fitness_mcp.config import Config, get_config_path, load_config, save_config

    region = os.environ.get("MI_FITNESS_REGION", "cn")
    reseed = os.environ.get("MI_FITNESS_RESEED", "").lower() in ("1", "true", "yes")

    stored_user_id, stored_token = load_mi_fitness_token()
    if stored_token and not reseed:
        _log("keyring already holds a passToken, keeping the rotated value")
    else:
        user_id = os.environ.get("MI_FITNESS_USER_ID", "").strip()
        token = os.environ.get("MI_FITNESS_PASS_TOKEN", "").strip()
        if not user_id or not token:
            sys.exit("[entrypoint] no stored credentials and no MI_FITNESS_USER_ID/PASS_TOKEN")
        bad = [hex(ord(c)) for c in token if ord(c) > 127 or c.isspace() or c == ";"]
        if bad:
            sys.exit(f"[entrypoint] passToken contains illegal characters: {bad}")
        save_mi_fitness_token(user_id, token)
        _log(f"seeded credentials from the environment (reseed={reseed})")

    # Pin database_path in the config too, so the stored value and the
    # MI_FITNESS_DB_PATH override can never point at two different files.
    # The per-type timeout matters for backfills: upstream wraps every data type
    # in asyncio.wait_for(sync_type_timeout_seconds), and a multi-month range of
    # heart-rate samples fails the default 180s with an empty error message.
    desired = Config(mode="mi_fitness_cloud", region=region, database_path=_db_path())
    if timeout := os.environ.get("MI_FITNESS_SYNC_TYPE_TIMEOUT"):
        desired.sync_type_timeout_seconds = float(timeout)
    if chunk := os.environ.get("MI_FITNESS_CHUNK_DAYS"):
        desired.sync_chunk_days = int(chunk)
    current = load_config() if get_config_path().exists() else None
    if current is None or current.model_dump() != desired.model_dump():
        save_config(desired)
        _log(
            f"wrote config: region={region}, db={desired.database_path}, "
            f"type_timeout={desired.sync_type_timeout_seconds}s, chunk={desired.sync_chunk_days}d"
        )


def enable_wal() -> None:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as conn:
        mode = conn.execute("pragma journal_mode=wal").fetchone()[0]
        conn.execute("pragma busy_timeout=15000")
    _log(f"journal_mode={mode}")


def sync_window() -> list[str]:
    lookback = int(os.environ.get("MI_FITNESS_LOOKBACK_DAYS", "3"))
    end = date.today()
    start = end - timedelta(days=lookback)
    _log(f"sync window {start} … {end} (UTC dates, lookback={lookback})")
    return [BRIDGE, "sync", "--start-date", start.isoformat(), "--end-date", end.isoformat()]


def proxy_command() -> list[str]:
    port = os.environ.get("MCP_HTTP_PORT", "8080")
    host = os.environ.get("MCP_HTTP_HOST", "0.0.0.0")
    extra = os.environ.get("MCP_PROXY_ARGS", "").split()
    # --pass-environment is mandatory, not a nicety: mcp-proxy spawns the stdio
    # child with an empty environment by default, and the bridge would then miss
    # XDG_CONFIG_HOME, MI_FITNESS_DB_PATH and the keyring backend, reporting
    # "not_configured" while sitting on a perfectly good volume.
    return [
        "mcp-proxy", "--host", host, "--port", port, "--pass-environment",
        *extra, "--", BRIDGE, "serve",
    ]


def main() -> None:
    args = sys.argv[1:]
    seed_credentials()
    enable_wal()

    if not args or args[0] == "sync-window":
        command = sync_window()
    elif args[0] == "proxy":
        command = proxy_command()
    elif args[0] == "selftest":
        # Offline check: no Xiaomi call, just prove the wiring and the volume.
        subprocess.run([BRIDGE, "--help"], check=True, capture_output=True)
        _log(f"selftest ok, db={_db_path()}, exists={_db_path().exists()}")
        return
    else:
        command = [BRIDGE, *args]

    _log("exec " + " ".join(command))
    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
