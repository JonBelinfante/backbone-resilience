"""Run next to a writer and stop it as soon as its lease has run out."""

import logging
import os
import sys
import time
from pathlib import Path

import psycopg

from fence_guard.decision import should_fence

LOG = logging.getLogger("fence_guard")
SQL_STATE = "select pg_is_in_recovery()"
SQL_LEASE = "select expires_at < clock_timestamp() from fence_lease where id = 1"
SQL_STOP = "copy (select 1) to program '{pg_ctl} stop -m immediate -D {data}'"


def read_state(connection: psycopg.Connection[tuple[object, ...]]) -> tuple[bool, bool | None]:
    """Ask the node whether it is a replica and whether its lease has run out.

    Args:
        connection: an open connection to the guarded node.

    Returns:
        (in recovery, lease expired), the second being None if there is no lease.
    """
    row = connection.execute(SQL_STATE).fetchone()
    in_recovery = bool(row[0]) if row else True
    if in_recovery:
        return True, None
    try:
        lease = connection.execute(SQL_LEASE).fetchone()
    except psycopg.errors.UndefinedTable:
        return False, None
    return False, (bool(lease[0]) if lease else None)


def stop_node(connection: psycopg.Connection[tuple[object, ...]], command: dict[str, str]) -> None:
    """Stop the guarded node at once, as a crash would (no shutdown checkpoint).

    Args:
        connection: an open connection to the guarded node, as a superuser.
        command: the pg_ctl path and the data directory.
    """
    LOG.info("DECISION fencing: the lease has run out, stopping the node")
    try:
        connection.execute(SQL_STOP.format(pg_ctl=command["pg_ctl"], data=command["data"]))
    except psycopg.Error:
        LOG.info("the node went down while it was being stopped")


def run(settings: dict[str, str], poll_seconds: float) -> None:
    """Poll the node forever; fence it once if its lease has run out.

    Args:
        settings: password, host, pg_ctl path and data directory.
        poll_seconds: pause between two looks at the lease.
    """
    while True:
        started = time.monotonic()
        try:
            with psycopg.connect(
                host=settings["host"],
                user="postgres",
                password=settings["password"],
                dbname="appdb",
                connect_timeout=2,
                autocommit=True,
                options="-c statement_timeout=2000",
            ) as connection:
                in_recovery, expired = read_state(connection)
                if should_fence(in_recovery=in_recovery, lease_expired=expired):
                    stop_node(connection, settings)
                    return
        except psycopg.Error as error:
            LOG.info("could not look at the lease: %s", type(error).__name__)
        time.sleep(max(0.0, poll_seconds - (time.monotonic() - started)))


def main() -> None:
    """Read the settings from the environment and run."""
    logging.basicConfig(
        stream=sys.stdout,
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03dZ %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    logging.Formatter.converter = time.gmtime
    settings = {
        "password": Path(os.environ["PASSWORD_FILE"]).read_text(encoding="utf-8").strip(),
        "host": os.environ.get("NODE_HOST", "127.0.0.1"),
        "pg_ctl": os.environ.get("PG_CTL", "/usr/lib/postgresql/16/bin/pg_ctl"),
        "data": os.environ.get("PGDATA", "/var/lib/postgresql/data"),
    }
    poll_seconds = float(os.environ.get("POLL_SECONDS", "0.5"))
    LOG.info("DECISION guard started: poll every %s s", poll_seconds)
    run(settings, poll_seconds)


if __name__ == "__main__":
    main()
