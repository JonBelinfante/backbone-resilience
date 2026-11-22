"""Database probes for the failover controller: each asks one question with a hard time limit."""

from dataclasses import dataclass

import psycopg

SQL_WRITER = "select pg_is_in_recovery()"
SQL_STANDBY = """
select pg_is_in_recovery(),
       exists (select 1 from pg_stat_wal_receiver
               where status = 'streaming'
                 and now() - last_msg_receipt_time < make_interval(secs => %s))
"""
SQL_RENEW = """
update fence_lease
   set expires_at = clock_timestamp() + make_interval(secs => %s)
 where id = 1
"""


@dataclass(frozen=True)
class Target:
    """Where and how to reach one database.

    Attributes:
        host: host name on the network the controller runs on.
        port: TCP port.
        password: the superuser's password, read by the caller from a secret file.
        timeout_seconds: the whole probe, connecting included, must finish within this.
    """

    host: str
    port: int
    password: str
    timeout_seconds: int


def _connect(target: Target) -> psycopg.Connection[tuple[object, ...]]:
    """Open a short-lived connection that gives up after the target's time limit."""
    return psycopg.connect(
        host=target.host,
        port=target.port,
        user="postgres",
        password=target.password,
        dbname="appdb",
        connect_timeout=target.timeout_seconds,
        options=f"-c statement_timeout={target.timeout_seconds * 1000}",
    )


def probe_writer(target: Target) -> bool | None:
    """Ask a node whether it is in recovery.

    Args:
        target: the node to ask.

    Returns:
        True if it is in recovery, False if it accepts writes, None if it did not answer.
    """
    try:
        with _connect(target) as connection:
            row = connection.execute(SQL_WRITER).fetchone()
    except psycopg.Error:
        return None
    return bool(row[0]) if row else None


def probe_standby(target: Target, max_age_seconds: int) -> tuple[bool, bool] | None:
    """Ask a standby whether it is in recovery and whether the writer is feeding it.

    Args:
        target: the standby to ask.
        max_age_seconds: how recent the last message from the writer must be to count.

    Returns:
        (in recovery, receiving from the writer), or None if it did not answer.
    """
    try:
        with _connect(target) as connection:
            row = connection.execute(SQL_STANDBY, (max_age_seconds,)).fetchone()
    except psycopg.Error:
        return None
    return (bool(row[0]), bool(row[1])) if row else None


def renew_lease(target: Target, ttl_seconds: int) -> bool:
    """Push the writer's lease forward: it now runs out ``ttl_seconds`` from the writer's own clock.

    Args:
        target: the writer.
        ttl_seconds: how long the lease lasts from now.

    Returns:
        True if the lease row was renewed, False if the writer did not take the update.
    """
    try:
        with _connect(target) as connection:
            cursor = connection.execute(SQL_RENEW, (ttl_seconds,))
            return cursor.rowcount == 1
    except psycopg.Error:
        return False
