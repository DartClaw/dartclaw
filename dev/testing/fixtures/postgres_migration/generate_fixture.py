#!/usr/bin/env python3
"""Regenerate the independently seeded v0.26.1 migration fixture."""

import hashlib
import json
import pathlib
import sqlite3


SOURCE_COMMIT = "ef24b3302e936c4ff6183158da8462b866dbd7d2"
ROOT = pathlib.Path(__file__).resolve().parents[4]
FIXTURE_DIR = pathlib.Path(__file__).resolve().parent
DATABASE = FIXTURE_DIR / "dartclaw-v0.26.1.db"
WRONG_DATABASE = FIXTURE_DIR / "dartclaw-wrong-shape.db"
MANIFEST = ROOT / "dev" / "tools" / "migrate_sqlite_v0_26_1_manifest.json"
PROOF = FIXTURE_DIR / "fixture-proof.json"
CANONICAL_SENTINEL = FIXTURE_DIR / "canonical-files-sentinel.txt"

SCHEMA = (
    """CREATE TABLE agent_executions (id TEXT PRIMARY KEY NOT NULL, session_id TEXT, provider TEXT, model TEXT,
      workspace_dir TEXT, container_json TEXT, budget_tokens INTEGER, harness_meta_json TEXT, started_at TEXT,
      completed_at TEXT)""",
    """CREATE TABLE workflow_step_executions (task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
      agent_execution_id TEXT NOT NULL REFERENCES agent_executions(id), workflow_run_id TEXT NOT NULL,
      step_index INTEGER NOT NULL, step_id TEXT NOT NULL, step_type TEXT, git_json TEXT, provider_session_id TEXT,
      structured_schema_json TEXT, structured_output_json TEXT, follow_up_prompts_json TEXT, map_iteration_index INTEGER,
      map_iteration_total INTEGER, step_token_breakdown_json TEXT)""",
    """CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL, type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft', version INTEGER NOT NULL DEFAULT 1, goal_id TEXT, acceptance_criteria TEXT,
      config_json TEXT NOT NULL DEFAULT '{}', worktree_json TEXT, created_at TEXT NOT NULL, started_at TEXT,
      completed_at TEXT, created_by TEXT, agent_execution_id TEXT REFERENCES agent_executions(id) ON DELETE RESTRICT,
      project_id TEXT, workflow_run_id TEXT, step_index INTEGER, max_retries INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0)""",
    "CREATE INDEX idx_tasks_status ON tasks(status)",
    "CREATE INDEX idx_tasks_type ON tasks(type)",
    "CREATE INDEX idx_tasks_status_type ON tasks(status, type)",
    "CREATE INDEX idx_tasks_workflow_run_id ON tasks(workflow_run_id)",
    """CREATE TABLE task_artifacts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
      path TEXT NOT NULL, created_at TEXT NOT NULL, FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE)""",
    "CREATE INDEX idx_task_artifacts_task_id ON task_artifacts(task_id)",
    "CREATE INDEX idx_agent_executions_session_id ON agent_executions(session_id)",
    "CREATE INDEX idx_agent_executions_provider ON agent_executions(provider)",
    "CREATE INDEX idx_wse_run_step ON workflow_step_executions(workflow_run_id, step_index)",
    "CREATE INDEX idx_wse_agent_execution ON workflow_step_executions(agent_execution_id)",
    """CREATE TABLE goals (id TEXT PRIMARY KEY, title TEXT NOT NULL, parent_goal_id TEXT, mission TEXT NOT NULL,
      created_at TEXT NOT NULL, max_tokens INTEGER)""",
    "CREATE INDEX idx_goals_parent ON goals(parent_goal_id)",
    """CREATE TABLE task_events (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, timestamp TEXT NOT NULL, kind TEXT NOT NULL,
      details TEXT NOT NULL DEFAULT '{}')""",
    "CREATE INDEX idx_task_events_task ON task_events(task_id)",
    "CREATE INDEX idx_task_events_task_kind ON task_events(task_id, kind)",
    "CREATE INDEX idx_task_events_timestamp ON task_events(timestamp)",
    """CREATE TABLE turns (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, task_id TEXT, runner_id INTEGER, model TEXT,
      provider TEXT, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0, is_error INTEGER NOT NULL DEFAULT 0, error_type TEXT, tool_calls TEXT)""",
    "CREATE INDEX idx_turns_session ON turns(session_id)",
    "CREATE INDEX idx_turns_task ON turns(task_id)",
    "CREATE INDEX idx_turns_started ON turns(started_at)",
    "CREATE INDEX idx_turns_model ON turns(model)",
    "CREATE INDEX idx_turns_provider ON turns(provider)",
    """CREATE TABLE workflow_runs (id TEXT PRIMARY KEY, definition_name TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending', context_json TEXT NOT NULL DEFAULT '{}',
      variables_json TEXT NOT NULL DEFAULT '{}', started_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT,
      error_message TEXT, total_tokens INTEGER NOT NULL DEFAULT 0, current_step_index INTEGER NOT NULL DEFAULT 0,
      definition_json TEXT NOT NULL DEFAULT '{}', execution_cursor_json TEXT, workflow_worktree_json TEXT)""",
    "CREATE INDEX idx_workflow_runs_status ON workflow_runs(status)",
    "CREATE INDEX idx_workflow_runs_definition ON workflow_runs(definition_name)",
    "CREATE TABLE workflow_run_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)",
    """CREATE TABLE kg_facts (id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, predicate TEXT NOT NULL,
      value TEXT NOT NULL, valid_from TEXT NOT NULL, valid_to TEXT, source TEXT NOT NULL, owner TEXT,
      invalidated_at TEXT, invalidation_reason TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')))""",
    "CREATE INDEX kg_facts_lookup ON kg_facts(entity, predicate, valid_from, valid_to)",
    """CREATE TABLE dartclaw_schema (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      epoch INTEGER NOT NULL CHECK (typeof(epoch) = 'integer')
    )""",
    "INSERT INTO dartclaw_schema (id, epoch) VALUES (1, 1)",
)

TABLE_ORDER = (
    "agent_executions",
    "goals",
    "workflow_runs",
    "tasks",
    "workflow_step_executions",
    "task_artifacts",
    "task_events",
    "turns",
    "workflow_run_migrations",
    "kg_facts",
)

TARGET_DERIVED_TABLES = {
    "memory_chunks": (
        ("id", "bigint", True, None, True, True),
        ("text", "text", True, None, False, False),
        ("chunk_index", "bigint", True, None, False, False),
        ("source", "text", True, None, False, False),
        ("category", "text", False, None, False, False),
        ("created_at", "text", True, "current_timestamp", False, False),
        ("user_id", "text", True, "'owner'", False, False),
        ("role", "text", True, "'memory'", False, False),
        ("provenance", "text", True, "'unknown'", False, False),
        ("locator", "text", False, None, False, False),
        ("entry_id", "text", False, None, False, False),
        ("entry_revision", "bigint", False, None, False, False),
        ("content_tsv", "tsvector", True, None, False, False),
    ),
    "conversation_chunks": (
        ("id", "bigint", True, None, True, True),
        ("message_id", "text", True, None, False, False),
        ("user_id", "text", True, None, False, False),
        ("text", "text", True, None, False, False),
        ("chunk_index", "bigint", True, None, False, False),
        ("session_id", "text", True, None, False, False),
        ("role", "text", True, None, False, False),
        ("created_at", "text", True, None, False, False),
        ("content_tsv", "tsvector", True, None, False, False),
    ),
    "dartclaw_schema": (
        ("id", "bigint", True, None, True, False),
        ("epoch", "bigint", True, None, False, False),
    ),
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def seed(database):
    if database.exists():
        database.unlink()
    connection = sqlite3.connect(database)
    connection.execute("PRAGMA foreign_keys=ON")
    for statement in SCHEMA:
        connection.execute(statement)
    connection.execute(
        "INSERT INTO agent_executions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "agent-1",
            "session-å",
            "codex",
            None,
            "/workspace/O'Brien",
            '{"command":"SELECT * FROM tasks;","line":"first\\nsecond"}',
            9007199254740991,
            None,
            "2026-09-01T10:11:12.000Z",
            None,
        ),
    )
    connection.executemany(
        "INSERT INTO goals VALUES (?, ?, ?, ?, ?, ?)",
        (
            ("goal-root", "Mål 🦀", None, "Preserve every relationship", "2026-09-01T00:00:00Z", None),
            ("goal-child", "Quoted ' child", "goal-root", "Line one\nline two", "2026-09-01T00:01:00Z", 42),
        ),
    )
    connection.execute(
        "INSERT INTO workflow_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "run-1",
            "migration-proof",
            "running",
            '{"principal":"agent:research/å","sql":"DROP TABLE tasks;"}',
            '{"quoted":"O\\\'Brien","null":null}',
            "2026-09-01T01:00:00Z",
            "2026-09-01T01:01:00Z",
            None,
            None,
            123,
            4,
            '{"steps":["a","b"]}',
            '{"iteration":2}',
            None,
        ),
    )
    connection.executemany(
        "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            (
                "task-1",
                "Unicode Göteborg 🦀",
                "line one\n\\.\n'); DROP TABLE tasks; --",
                "workflow",
                "running",
                3,
                "goal-child",
                '["quote \\\" and newline\\n"]',
                '{"owner":"agent:research/å","nullable":null}',
                None,
                "2026-09-01T02:00:00Z",
                "2026-09-01T02:01:00Z",
                None,
                "agent:research/å",
                "agent-1",
                "project-1",
                "run-1",
                4,
                2,
                1,
            ),
            (
                "task-2",
                "Second",
                "Null coverage",
                "prompt",
                "draft",
                1,
                None,
                None,
                "{}",
                None,
                "2026-09-01T02:02:00Z",
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                0,
                0,
            ),
        ),
    )
    connection.execute(
        "INSERT INTO workflow_step_executions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "task-1",
            "agent-1",
            "run-1",
            4,
            "step-'quoted'",
            "agent",
            '{"branch":"feature/å"}',
            "provider-session-1",
            '{"type":"object"}',
            '{"text":"line one\\nline two"}',
            '["next"]',
            2,
            5,
            '{"input":10,"output":20}',
        ),
    )
    connection.execute(
        "INSERT INTO task_artifacts VALUES (?, ?, ?, ?, ?, ?)",
        ("artifact-1", "task-1", "résumé.txt", "file", "/tmp/O'Brien\nfile", "2026-09-01T03:00:00Z"),
    )
    connection.execute(
        "INSERT INTO task_events VALUES (?, ?, ?, ?, ?)",
        ("event-1", "task-1", "2026-09-01T03:01:00Z", "note", '{"sql":"SELECT 1; --","text":"å"}'),
    )
    connection.execute(
        "INSERT INTO turns VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            "turn-1",
            "session-å",
            "task-1",
            7,
            None,
            "codex",
            "2026-09-01T04:00:00Z",
            "2026-09-01T04:01:00Z",
            11,
            12,
            13,
            14,
            0,
            None,
            '[{"name":"shell","arguments":{"text":"\\\\."}}]',
        ),
    )
    connection.execute(
        "INSERT INTO workflow_run_migrations VALUES (?, ?)",
        ("migration-'one'", "2026-09-01T05:00:00Z"),
    )
    connection.execute(
        "INSERT INTO kg_facts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            7,
            "DartClaw",
            "says",
            "Göteborg\n\\.\nDROP TABLE kg_facts;",
            "2026-09-01T06:00:00Z",
            None,
            "MEMORY.md#quoted-'section'",
            "agent:research/å",
            None,
            None,
            "2026-09-01T06:01:00Z",
        ),
    )
    connection.commit()
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    connection.close()


def source_manifest(database):
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    objects = []
    for object_type, name, table, sql in connection.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
    ):
        objects.append({"type": object_type, "name": name, "table": table, "sql": sql})
    tables = []
    for name in TABLE_ORDER:
        columns = []
        for _, column, declared_type, not_null, default, primary_key in connection.execute(
            f'PRAGMA table_info("{name}")'
        ):
            columns.append(
                {
                    "name": column,
                    "type": declared_type,
                    "not_null": bool(not_null),
                    "default": default,
                    "primary_key": bool(primary_key),
                }
            )
        tables.append({"name": name, "columns": columns})
    indexes = []
    for table in TABLE_ORDER:
        for _, name, unique, _, _ in connection.execute(f'PRAGMA index_list("{table}")'):
            if name.startswith("sqlite_"):
                continue
            columns = [row[2] for row in connection.execute(f'PRAGMA index_info("{name}")')]
            indexes.append({"name": name, "table": table, "columns": columns, "unique": bool(unique), "method": "btree"})
    connection.close()
    return tables, objects, sorted(indexes, key=lambda row: row["name"])


def target_column(column):
    identity = column["type"] == "INTEGER" and column["primary_key"]
    default = column["default"]
    if default is not None and "datetime('now')" in default.lower():
        default = "current_timestamp"
    return {
        "name": column["name"],
        "type": {"TEXT": "text", "INTEGER": "bigint"}[column["type"]],
        "not_null": column["not_null"] or column["primary_key"],
        "default": None if identity else default,
        "primary_key": column["primary_key"],
        "identity": identity,
    }


def write_assets():
    seed(DATABASE)
    seed(WRONG_DATABASE)
    wrong = sqlite3.connect(WRONG_DATABASE)
    wrong.execute("ALTER TABLE tasks ADD COLUMN unsupported TEXT")
    wrong.commit()
    wrong.close()
    tables, objects, indexes = source_manifest(DATABASE)
    target_tables = [
        {"name": table["name"], "columns": [target_column(column) for column in table["columns"]]}
        for table in tables
    ]
    target_tables.extend(
        {
            "name": name,
            "columns": [
                {
                    "name": column,
                    "type": data_type,
                    "not_null": not_null,
                    "default": default,
                    "primary_key": primary_key,
                    "identity": identity,
                }
                for column, data_type, not_null, default, primary_key, identity in columns
            ],
        }
        for name, columns in TARGET_DERIVED_TABLES.items()
    )
    indexes.extend(
        (
            {
                "name": "memory_chunks_content_tsv_idx",
                "table": "memory_chunks",
                "columns": ["content_tsv"],
                "unique": False,
                "method": "gin",
            },
            {
                "name": "conversation_chunks_content_tsv_idx",
                "table": "conversation_chunks",
                "columns": ["content_tsv"],
                "unique": False,
                "method": "gin",
            },
        )
    )
    manifest = {
        "source_commit": SOURCE_COMMIT,
        "schema_epoch": 1,
        "table_order": list(TABLE_ORDER),
        "source": {"tables": tables, "objects": objects},
        "target": {"tables": target_tables, "indexes": sorted(indexes, key=lambda row: row["name"])},
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    CANONICAL_SENTINEL.write_text("canonical memory/wiki files stay outside database migration\n")
    connection = sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True)
    counts = {table: connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0] for table in TABLE_ORDER}
    connection.close()
    proof = {
        "source_commit": SOURCE_COMMIT,
        "fixture_sha256": sha256(DATABASE),
        "wrong_shape_sha256": sha256(WRONG_DATABASE),
        "manifest_sha256": sha256(MANIFEST),
        "canonical_sentinel_sha256": sha256(CANONICAL_SENTINEL),
        "table_counts": counts,
        "next_kg_fact_id": 8,
    }
    PROOF.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    write_assets()
