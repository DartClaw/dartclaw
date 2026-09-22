#!/usr/bin/env python3
"""Import one stopped v0.26.1 SQLite snapshot into an empty current PostgreSQL schema.

Usage:
    python3 dev/tools/migrate_sqlite_to_postgres.py /path/to/stopped-backup.db

The target is selected only through inherited libpq environment, service, and
passfile settings. Bootstrap it first with ``dartclaw doctor --fix`` while the
runtime is stopped. The command never accepts a PostgreSQL URL or password.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import urllib.parse


MANIFEST_NAME = "migrate_sqlite_v0_26_1_manifest.json"
MANIFEST_SHA256 = "d6a99d2749128c9b052cd5886295c7a33047cce3b4c4b39b132d628c43648bbd"
SOURCE_COMMIT = "ef24b3302e936c4ff6183158da8462b866dbd7d2"
INTERLOCK_KEY = 0x64617274636C6177
OPTIONAL_TARGET_TABLES = ("memory_vectors", "conversation_vectors")
FAULT_ENV = "DARTCLAW_MIGRATION_FAULT"


class MigrationRefusal(Exception):
    def __init__(self, category, message):
        super().__init__(message)
        self.category = category


def _sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise MigrationRefusal("source-unreadable", "the source snapshot is missing or unreadable") from error
    return digest.hexdigest()


def _load_manifest():
    path = pathlib.Path(__file__).with_name(MANIFEST_NAME)
    if _sha256(path) != MANIFEST_SHA256:
        raise MigrationRefusal("tool-integrity", "the pinned source manifest does not match this utility")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MigrationRefusal("tool-integrity", "the pinned source manifest is unreadable") from error
    if manifest.get("source_commit") != SOURCE_COMMIT or manifest.get("schema_epoch") != 1:
        raise MigrationRefusal("tool-integrity", "the pinned source manifest has unsupported provenance")
    return manifest


def _normalize_sql(value):
    return re.sub(r"\s*([(),;=])\s*", r"\1", re.sub(r"\s+", " ", value or "")).strip()


def _source_uri(path):
    return "file:" + urllib.parse.quote(str(path), safe="/") + "?mode=ro&immutable=1"


def _quote_identifier(value):
    if not re.fullmatch(r"[a-z][a-z0-9_]*", value):
        raise MigrationRefusal("tool-integrity", "the pinned manifest contains an invalid identifier")
    return '"' + value.replace('"', '""') + '"'


def _sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def _source_rows(snapshot, manifest):
    for suffix in ("-wal", "-shm", "-journal"):
        if pathlib.Path(str(snapshot) + suffix).exists():
            raise MigrationRefusal(
                "source-ambiguous",
                "the snapshot has a journal sidecar; make one stopped, consistent backup that includes committed WAL data",
            )
    before = _sha256(snapshot)
    try:
        connection = sqlite3.connect(_source_uri(snapshot), uri=True)
        connection.execute("PRAGMA query_only=ON")
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        if integrity != [("ok",)]:
            raise MigrationRefusal("source-integrity", "the source snapshot failed SQLite integrity checks")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise MigrationRefusal("source-integrity", "the source snapshot has broken foreign-key relationships")
        live_objects = [
            {"type": row[0], "name": row[1], "table": row[2], "sql": row[3]}
            for row in connection.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_master "
                "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
            )
        ]
        expected_objects = manifest["source"]["objects"]
        if len(live_objects) != len(expected_objects):
            raise MigrationRefusal("source-shape", "the source snapshot is not the exact supported v0.26.1 shape")
        for live, expected in zip(live_objects, expected_objects):
            if (
                live["type"] != expected["type"]
                or live["name"] != expected["name"]
                or live["table"] != expected["table"]
                or _normalize_sql(live["sql"]) != _normalize_sql(expected["sql"])
            ):
                raise MigrationRefusal("source-shape", "the source snapshot is not the exact supported v0.26.1 shape")

        table_manifests = {table["name"]: table for table in manifest["source"]["tables"]}
        rows = {}
        for table_name in manifest["table_order"]:
            table = table_manifests[table_name]
            live_columns = [
                {
                    "name": row[1],
                    "type": row[2],
                    "not_null": bool(row[3]),
                    "default": row[4],
                    "primary_key": bool(row[5]),
                }
                for row in connection.execute(f"PRAGMA table_info({_quote_identifier(table_name)})")
            ]
            if live_columns != table["columns"]:
                raise MigrationRefusal("source-shape", "the source snapshot is not the exact supported v0.26.1 shape")
            columns = [column["name"] for column in table["columns"]]
            primary = [column["name"] for column in table["columns"] if column["primary_key"]]
            selected = ", ".join(_quote_identifier(column) for column in columns)
            ordered = ", ".join(_quote_identifier(column) for column in primary)
            query = f"SELECT {selected} FROM {_quote_identifier(table_name)} ORDER BY {ordered}"
            table_rows = []
            for values in connection.execute(query):
                payload = {}
                for column, value in zip(table["columns"], values):
                    if value is not None and column["type"] == "TEXT" and not isinstance(value, str):
                        raise MigrationRefusal("source-values", "the source snapshot contains an unsupported value type")
                    if value is not None and column["type"] == "INTEGER" and (
                        not isinstance(value, int) or isinstance(value, bool)
                    ):
                        raise MigrationRefusal("source-values", "the source snapshot contains an unsupported value type")
                    if isinstance(value, str) and "\x00" in value:
                        raise MigrationRefusal("source-values", "the source snapshot contains text PostgreSQL cannot store")
                    payload[column["name"]] = value
                table_rows.append(payload)
            rows[table_name] = table_rows

        marker = connection.execute("SELECT id, epoch, typeof(epoch) FROM dartclaw_schema").fetchall()
        if marker != [(1, 1, "integer")]:
            raise MigrationRefusal("source-shape", "the source snapshot has an unsupported schema marker")
        _validate_source_relationships(connection)
        connection.close()
    except MigrationRefusal:
        raise
    except (OSError, sqlite3.Error, KeyError, TypeError, ValueError) as error:
        raise MigrationRefusal("source-unreadable", "the source snapshot cannot be read safely") from error
    if _sha256(snapshot) != before:
        raise MigrationRefusal("source-changed", "the source snapshot changed while it was being read")
    return rows


def _validate_source_relationships(connection):
    checks = (
        "SELECT 1 FROM goals child LEFT JOIN goals parent ON parent.id=child.parent_goal_id "
        "WHERE child.parent_goal_id IS NOT NULL AND parent.id IS NULL LIMIT 1",
        "SELECT 1 FROM tasks row LEFT JOIN goals parent ON parent.id=row.goal_id "
        "WHERE row.goal_id IS NOT NULL AND parent.id IS NULL LIMIT 1",
        "SELECT 1 FROM tasks row LEFT JOIN workflow_runs parent ON parent.id=row.workflow_run_id "
        "WHERE row.workflow_run_id IS NOT NULL AND parent.id IS NULL LIMIT 1",
        "SELECT 1 FROM workflow_step_executions row LEFT JOIN workflow_runs parent ON parent.id=row.workflow_run_id "
        "WHERE parent.id IS NULL LIMIT 1",
        "SELECT 1 FROM task_events row LEFT JOIN tasks parent ON parent.id=row.task_id WHERE parent.id IS NULL LIMIT 1",
        "SELECT 1 FROM turns row LEFT JOIN tasks parent ON parent.id=row.task_id "
        "WHERE row.task_id IS NOT NULL AND parent.id IS NULL LIMIT 1",
    )
    if any(connection.execute(query).fetchone() is not None for query in checks):
        raise MigrationRefusal("source-integrity", "the source snapshot has broken authoritative relationships")


def _default_condition(default):
    if default is None:
        return "column_default IS NULL"
    normalized = re.sub(r"[()\s]", "", default.lower().replace("datetime('now')", "current_timestamp"))
    return (
        "regexp_replace(lower(coalesce(column_default, '')), '(::text)|[()[:space:]]+', '', 'g') = "
        + _sql_string(normalized)
    )


def _target_schema_checks(manifest):
    statements = []
    for table in manifest["target"]["tables"]:
        column_conditions = []
        for column in table["columns"]:
            nullable = "NO" if column["not_null"] else "YES"
            identity = "YES" if column["identity"] else "NO"
            condition = [
                f"column_name = {_sql_string(column['name'])}",
                f"data_type = {_sql_string(column['type'])}",
                f"is_nullable = {_sql_string(nullable)}",
                f"is_identity = {_sql_string(identity)}",
                _default_condition(column["default"]),
            ]
            column_conditions.append("(" + " AND ".join(condition) + ")")
        primary = [column["name"] for column in table["columns"] if column["primary_key"]]
        primary_array = "ARRAY[" + ", ".join(_sql_string(column) for column in primary) + "]::text[]"
        statements.append(
            "IF (SELECT count(*) FROM information_schema.columns "
            f"WHERE table_schema = current_schema() AND table_name = {_sql_string(table['name'])} "
            f"AND ({' OR '.join(column_conditions)})) <> {len(column_conditions)} THEN "
            "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-schema'; END IF;"
        )
        statements.append(
            "IF ARRAY(SELECT kcu.column_name::text FROM information_schema.table_constraints tc "
            "JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name "
            "AND tc.constraint_schema=kcu.constraint_schema "
            f"WHERE tc.constraint_schema=current_schema() AND tc.table_name={_sql_string(table['name'])} "
            "AND tc.constraint_type='PRIMARY KEY' ORDER BY kcu.ordinal_position) <> "
            f"{primary_array} THEN RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-schema'; END IF;"
        )
    for index in manifest["target"]["indexes"]:
        columns = "ARRAY[" + ", ".join(_sql_string(column) for column in index["columns"]) + "]::text[]"
        statements.append(
            "IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_index ix "
            "JOIN pg_catalog.pg_class idx ON idx.oid=ix.indexrelid "
            "JOIN pg_catalog.pg_class tbl ON tbl.oid=ix.indrelid "
            "JOIN pg_catalog.pg_namespace ns ON ns.oid=tbl.relnamespace "
            "JOIN pg_catalog.pg_am am ON am.oid=idx.relam "
            f"WHERE ns.nspname=current_schema() AND idx.relname={_sql_string(index['name'])} "
            f"AND tbl.relname={_sql_string(index['table'])} AND am.amname={_sql_string(index['method'])} "
            f"AND ix.indisunique={'true' if index['unique'] else 'false'} "
            "AND ARRAY(SELECT attr.attname::text FROM unnest(ix.indkey) WITH ORDINALITY key(attnum, ord) "
            "JOIN pg_catalog.pg_attribute attr ON attr.attrelid=ix.indrelid AND attr.attnum=key.attnum "
            f"ORDER BY key.ord)={columns}) THEN "
            "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-schema'; END IF;"
        )
    return statements


def _payload_lines(rows, table_order):
    lines = []
    for table_name in table_order:
        for ordinal, row in enumerate(rows[table_name]):
            encoded = base64.b64encode(
                json.dumps(row, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
            ).decode("ascii")
            lines.append(f"{table_name},{ordinal},{encoded}")
    return lines


def _record_definition(table):
    return ", ".join(
        f"{_quote_identifier(column['name'])} {column['type']}" for column in table["columns"]
    )


def _json_object(table, alias):
    entries = []
    for column in table["columns"]:
        entries.extend((_sql_string(column["name"]), f"{alias}.{_quote_identifier(column['name'])}"))
    return "jsonb_build_object(" + ", ".join(entries) + ")"


def _migration_script(manifest, rows, fault):
    table_order = manifest["table_order"]
    target_by_name = {table["name"]: table for table in manifest["target"]["tables"]}
    lock_tables = sorted(set(target_by_name) | set(OPTIONAL_TARGET_TABLES))
    lines = [
        r"\set ON_ERROR_STOP on",
        "SET client_min_messages TO warning;",
        "BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;",
        "SET LOCAL statement_timeout = '5min';",
        "DO $migration$ BEGIN",
        "IF current_setting('server_version_num')::integer < 140000 THEN "
        "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-version'; END IF;",
        f"IF NOT pg_catalog.pg_try_advisory_xact_lock({INTERLOCK_KEY}) THEN "
        "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-active'; END IF;",
        "END $migration$;",
        "DO $migration$ DECLARE target text; BEGIN",
        "FOREACH target IN ARRAY ARRAY[" + ", ".join(_sql_string(table) for table in lock_tables) + "] LOOP",
        "IF pg_catalog.to_regclass(pg_catalog.format('%I.%I', current_schema(), target)) IS NOT NULL THEN BEGIN",
        "EXECUTE pg_catalog.format('LOCK TABLE %I.%I IN ACCESS EXCLUSIVE MODE NOWAIT', current_schema(), target);",
        "EXCEPTION WHEN lock_not_available THEN "
        "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-busy'; END; END IF; END LOOP;",
        "END $migration$;",
        "DO $migration$ BEGIN",
        *_target_schema_checks(manifest),
        "IF (SELECT jsonb_agg(jsonb_build_object('id', id, 'epoch', epoch) ORDER BY id) FROM dartclaw_schema) "
        "IS DISTINCT FROM '[{\"id\": 1, \"epoch\": 1}]'::jsonb THEN "
        "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-schema'; END IF;",
    ]
    for table_name in table_order + list(target_by_name.keys() - set(table_order) - {"dartclaw_schema"}):
        lines.append(
            f"IF EXISTS (SELECT 1 FROM {_quote_identifier(table_name)} LIMIT 1) THEN "
            "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-populated'; END IF;"
        )
    lines.extend(
        (
            "END $migration$;",
            "DO $migration$ DECLARE target text; populated boolean; BEGIN",
            "FOREACH target IN ARRAY ARRAY["
            + ", ".join(_sql_string(table) for table in OPTIONAL_TARGET_TABLES)
            + "] LOOP",
            "IF pg_catalog.to_regclass(pg_catalog.format('%I.%I', current_schema(), target)) IS NOT NULL THEN ",
            "EXECUTE pg_catalog.format('SELECT EXISTS (SELECT 1 FROM %I.%I LIMIT 1)', current_schema(), target) "
            "INTO populated; IF populated THEN "
            "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:target-populated'; END IF; END IF; END LOOP;",
            "END $migration$;",
        )
    )
    lines.extend(
        (
            "CREATE TEMP TABLE _dartclaw_migration_rows (table_name text NOT NULL, ordinal bigint NOT NULL, "
            "payload_b64 text NOT NULL) ON COMMIT DROP;",
            "COPY _dartclaw_migration_rows (table_name, ordinal, payload_b64) FROM STDIN WITH (FORMAT csv);",
            *_payload_lines(rows, table_order),
            r"\.",
        )
    )
    for table_name in table_order:
        table = target_by_name[table_name]
        columns = ", ".join(_quote_identifier(column["name"]) for column in table["columns"])
        selected = ", ".join(f"record.{_quote_identifier(column['name'])}" for column in table["columns"])
        lines.append(
            f"INSERT INTO {_quote_identifier(table_name)} ({columns}) "
            f"SELECT {selected} FROM _dartclaw_migration_rows stage "
            "CROSS JOIN LATERAL jsonb_to_record(convert_from(decode(stage.payload_b64, 'base64'), 'UTF8')::jsonb) "
            f"AS record({_record_definition(table)}) WHERE stage.table_name={_sql_string(table_name)} "
            "ORDER BY stage.ordinal;"
        )
    if fault == "after-writes":
        lines.append("DO $migration$ BEGIN RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:fault'; END $migration$;")
    if fault == "verification":
        lines.append(
            "UPDATE tasks SET title=title || 'verification-fault' "
            "WHERE id=(SELECT id FROM tasks ORDER BY id LIMIT 1);"
        )
    lines.append("DO $migration$ BEGIN")
    for table_name in table_order:
        table = target_by_name[table_name]
        target_json = _json_object(table, "target")
        expected_json = "convert_from(decode(stage.payload_b64, 'base64'), 'UTF8')::jsonb"
        expected_count = len(rows[table_name])
        lines.extend(
            (
                f"IF (SELECT count(*) FROM {_quote_identifier(table_name)}) <> {expected_count} THEN "
                "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:verification'; END IF;",
                f"IF EXISTS ((SELECT {target_json} FROM {_quote_identifier(table_name)} target EXCEPT ALL "
                f"SELECT {expected_json} FROM _dartclaw_migration_rows stage "
                f"WHERE stage.table_name={_sql_string(table_name)})) OR EXISTS ("
                f"SELECT {expected_json} FROM _dartclaw_migration_rows stage "
                f"WHERE stage.table_name={_sql_string(table_name)} EXCEPT ALL "
                f"SELECT {target_json} FROM {_quote_identifier(table_name)} target) THEN "
                "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:verification'; END IF;",
            )
        )
    lines.extend(
        (
            "IF EXISTS (SELECT 1 FROM goals child LEFT JOIN goals parent ON parent.id=child.parent_goal_id "
            "WHERE child.parent_goal_id IS NOT NULL AND parent.id IS NULL) "
            "OR EXISTS (SELECT 1 FROM tasks row LEFT JOIN goals parent ON parent.id=row.goal_id "
            "WHERE row.goal_id IS NOT NULL AND parent.id IS NULL) "
            "OR EXISTS (SELECT 1 FROM tasks row LEFT JOIN workflow_runs parent ON parent.id=row.workflow_run_id "
            "WHERE row.workflow_run_id IS NOT NULL AND parent.id IS NULL) "
            "OR EXISTS (SELECT 1 FROM workflow_step_executions row LEFT JOIN workflow_runs parent "
            "ON parent.id=row.workflow_run_id WHERE parent.id IS NULL) "
            "OR EXISTS (SELECT 1 FROM task_events row LEFT JOIN tasks parent ON parent.id=row.task_id "
            "WHERE parent.id IS NULL) "
            "OR EXISTS (SELECT 1 FROM turns row LEFT JOIN tasks parent ON parent.id=row.task_id "
            "WHERE row.task_id IS NOT NULL AND parent.id IS NULL) THEN "
            "RAISE EXCEPTION USING MESSAGE = 'DARTCLAW_MIGRATION:verification'; END IF;",
            "END $migration$;",
            "SET CONSTRAINTS ALL IMMEDIATE;",
        )
    )
    kg_ids = [row["id"] for row in rows["kg_facts"]]
    next_kg_id = max(kg_ids, default=0) + 1
    if next_kg_id > 9223372036854775807:
        raise MigrationRefusal("source-values", "the source knowledge identity cannot be advanced safely")
    lines.extend(
        (
            f"ALTER TABLE kg_facts ALTER COLUMN id RESTART WITH {next_kg_id};",
            "COMMIT;",
            "",
        )
    )
    return "\n".join(lines)


def _run_psql(script):
    try:
        completed = subprocess.run(
            ["psql", "-X", "--quiet", "--no-password", "--set", "ON_ERROR_STOP=1"],
            input=script,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise MigrationRefusal("target-connection", "psql could not start using inherited libpq settings") from error
    if completed.returncode == 0:
        return
    markers = {
        "target-version": "the target PostgreSQL server is older than version 14",
        "target-active": "the target is owned by an active DartClaw server",
        "target-busy": "the target is being mutated concurrently",
        "target-schema": "the target is not a current doctor-bootstrapped schema",
        "target-populated": "the target contains application records or was already imported",
        "verification": "target value or relationship verification failed; the import was rolled back",
        "fault": "an injected post-write failure rolled back the import",
    }
    for marker, message in markers.items():
        if f"DARTCLAW_MIGRATION:{marker}" in completed.stderr:
            raise MigrationRefusal(marker, message)
    raise MigrationRefusal("target-import", "the target import failed and was rolled back")


def _arguments(argv):
    parser = argparse.ArgumentParser(
        description="Import one stopped DartClaw v0.26.1 SQLite backup into an empty current PostgreSQL schema.",
        epilog=(
            "The PostgreSQL target comes from inherited libpq settings (PGHOST/PGPORT/PGDATABASE/PGUSER, "
            "PGSERVICE, PGPASSFILE, and TLS variables). No merge, overwrite, reset, or reverse migration is provided."
        ),
    )
    parser.add_argument("snapshot", type=pathlib.Path, help="consistent stopped v0.26.1 SQLite backup snapshot")
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    fault = os.environ.get(FAULT_ENV, "")
    if fault not in ("", "after-writes", "verification"):
        print("Migration refused [tool-configuration]: unsupported test fault mode.", file=sys.stderr)
        return 2
    try:
        manifest = _load_manifest()
        rows = _source_rows(args.snapshot, manifest)
        _run_psql(_migration_script(manifest, rows, fault))
    except MigrationRefusal as error:
        print(f"Migration refused [{error.category}]: {error}", file=sys.stderr)
        return 2
    print("Migration completed.")
    for table_name in manifest["table_order"]:
        print(f"  {table_name}: {len(rows[table_name])} rows")
    print("Rebuild lexical and optional vector projections from the separately backed-up canonical files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
