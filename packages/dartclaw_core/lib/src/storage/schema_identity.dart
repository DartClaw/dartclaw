/// A required database column, compared independently of ordinal position.
final class SchemaColumn {
  /// Creates a required column descriptor.
  const new(this.name, this.type, {this.notNull = false, this.defaultValue, this.primaryKey = false});

  /// Column name.
  final String name;

  /// Declared SQL type.
  final String type;

  /// Whether the declaration includes `NOT NULL`.
  final bool notNull;

  /// Declared default expression, or `null` when none is declared.
  final String? defaultValue;

  /// Whether the column participates in the primary key.
  final bool primaryKey;
}

/// A required database table and its required columns.
final class SchemaTable {
  /// Creates a required table descriptor.
  const new(this.name, this.columns);

  /// Table name.
  final String name;

  /// Columns required by the running release.
  final List<SchemaColumn> columns;
}

/// A required conventional database index.
final class SchemaIndex {
  /// Creates a required index descriptor.
  const new(this.name, this.table, this.columns, {this.unique = false});

  /// Index name.
  final String name;

  /// Indexed table.
  final String table;

  /// Indexed columns in key order.
  final List<String> columns;

  /// Whether the index is unique.
  final bool unique;
}

/// A SQLite object whose stored declaration is part of compatibility.
final class SqliteSchemaObject {
  /// Creates a required SQLite object descriptor.
  const new(this.type, this.name, this.table, this.sql);

  /// SQLite object type.
  final String type;

  /// Object name.
  final String name;

  /// Object's `sqlite_master.tbl_name` value.
  final String table;

  /// Expected declaration after whitespace normalization.
  final String sql;
}

/// Required-only structural identity for one store.
///
/// Extra objects and columns do not affect compatibility. This lets a store
/// retain unused columns while still requiring every object the runtime reads.
final class SchemaIdentity {
  /// Creates one backend-owned required-object manifest.
  const new({
    required this.tables,
    required this.indexes,
    required this.sqliteObjects,
    required this.bootstrapStatements,
    this.dropStatements = const [],
  });

  /// The one schema epoch understood by this release.
  static const currentEpoch = 1;

  /// Required identity for the authoritative task store.
  static const tasks = SchemaIdentity(
    tables: _taskTables,
    indexes: _taskIndexes,
    sqliteObjects: [],
    bootstrapStatements: _taskBootstrap,
  );

  /// Required identity for the derived search store.
  static const search = SchemaIdentity(
    tables: _searchTables,
    indexes: [],
    sqliteObjects: _searchObjects,
    bootstrapStatements: _searchBootstrap,
    dropStatements: _searchDrops,
  );

  /// Required tables.
  final List<SchemaTable> tables;

  /// Required conventional indexes.
  final List<SchemaIndex> indexes;

  /// Required SQLite-specific objects.
  final List<SqliteSchemaObject> sqliteObjects;

  /// SQLite statements that create the complete current structure.
  final List<String> bootstrapStatements;

  /// SQLite statements that remove every owned derived object.
  final List<String> dropStatements;
}

const _taskTables = [
  SchemaTable('agent_executions', [
    SchemaColumn('id', 'TEXT', notNull: true, primaryKey: true),
    SchemaColumn('session_id', 'TEXT'),
    SchemaColumn('provider', 'TEXT'),
    SchemaColumn('model', 'TEXT'),
    SchemaColumn('workspace_dir', 'TEXT'),
    SchemaColumn('container_json', 'TEXT'),
    SchemaColumn('budget_tokens', 'INTEGER'),
    SchemaColumn('harness_meta_json', 'TEXT'),
    SchemaColumn('started_at', 'TEXT'),
    SchemaColumn('completed_at', 'TEXT'),
  ]),
  SchemaTable('workflow_step_executions', [
    SchemaColumn('task_id', 'TEXT', primaryKey: true),
    SchemaColumn('agent_execution_id', 'TEXT', notNull: true),
    SchemaColumn('workflow_run_id', 'TEXT', notNull: true),
    SchemaColumn('step_index', 'INTEGER', notNull: true),
    SchemaColumn('step_id', 'TEXT', notNull: true),
    SchemaColumn('step_type', 'TEXT'),
    SchemaColumn('git_json', 'TEXT'),
    SchemaColumn('provider_session_id', 'TEXT'),
    SchemaColumn('structured_schema_json', 'TEXT'),
    SchemaColumn('structured_output_json', 'TEXT'),
    SchemaColumn('follow_up_prompts_json', 'TEXT'),
    SchemaColumn('map_iteration_index', 'INTEGER'),
    SchemaColumn('map_iteration_total', 'INTEGER'),
    SchemaColumn('step_token_breakdown_json', 'TEXT'),
  ]),
  SchemaTable('tasks', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('title', 'TEXT', notNull: true),
    SchemaColumn('description', 'TEXT', notNull: true),
    SchemaColumn('type', 'TEXT', notNull: true),
    SchemaColumn('status', 'TEXT', notNull: true, defaultValue: "'draft'"),
    SchemaColumn('version', 'INTEGER', notNull: true, defaultValue: '1'),
    SchemaColumn('goal_id', 'TEXT'),
    SchemaColumn('acceptance_criteria', 'TEXT'),
    SchemaColumn('config_json', 'TEXT', notNull: true, defaultValue: "'{}'"),
    SchemaColumn('worktree_json', 'TEXT'),
    SchemaColumn('created_at', 'TEXT', notNull: true),
    SchemaColumn('started_at', 'TEXT'),
    SchemaColumn('completed_at', 'TEXT'),
    SchemaColumn('created_by', 'TEXT'),
    SchemaColumn('agent_execution_id', 'TEXT'),
    SchemaColumn('project_id', 'TEXT'),
    SchemaColumn('workflow_run_id', 'TEXT'),
    SchemaColumn('step_index', 'INTEGER'),
    SchemaColumn('max_retries', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('retry_count', 'INTEGER', notNull: true, defaultValue: '0'),
  ]),
  SchemaTable('task_artifacts', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('task_id', 'TEXT', notNull: true),
    SchemaColumn('name', 'TEXT', notNull: true),
    SchemaColumn('kind', 'TEXT', notNull: true),
    SchemaColumn('path', 'TEXT', notNull: true),
    SchemaColumn('created_at', 'TEXT', notNull: true),
  ]),
  SchemaTable('goals', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('title', 'TEXT', notNull: true),
    SchemaColumn('parent_goal_id', 'TEXT'),
    SchemaColumn('mission', 'TEXT', notNull: true),
    SchemaColumn('created_at', 'TEXT', notNull: true),
    SchemaColumn('max_tokens', 'INTEGER'),
  ]),
  SchemaTable('task_events', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('task_id', 'TEXT', notNull: true),
    SchemaColumn('timestamp', 'TEXT', notNull: true),
    SchemaColumn('kind', 'TEXT', notNull: true),
    SchemaColumn('details', 'TEXT', notNull: true, defaultValue: "'{}'"),
  ]),
  SchemaTable('turns', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('session_id', 'TEXT', notNull: true),
    SchemaColumn('task_id', 'TEXT'),
    SchemaColumn('runner_id', 'INTEGER'),
    SchemaColumn('model', 'TEXT'),
    SchemaColumn('provider', 'TEXT'),
    SchemaColumn('started_at', 'TEXT', notNull: true),
    SchemaColumn('ended_at', 'TEXT', notNull: true),
    SchemaColumn('input_tokens', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('output_tokens', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('cache_read_tokens', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('cache_write_tokens', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('is_error', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('error_type', 'TEXT'),
    SchemaColumn('tool_calls', 'TEXT'),
  ]),
  SchemaTable('workflow_runs', [
    SchemaColumn('id', 'TEXT', primaryKey: true),
    SchemaColumn('definition_name', 'TEXT', notNull: true),
    SchemaColumn('status', 'TEXT', notNull: true, defaultValue: "'pending'"),
    SchemaColumn('context_json', 'TEXT', notNull: true, defaultValue: "'{}'"),
    SchemaColumn('variables_json', 'TEXT', notNull: true, defaultValue: "'{}'"),
    SchemaColumn('started_at', 'TEXT', notNull: true),
    SchemaColumn('updated_at', 'TEXT', notNull: true),
    SchemaColumn('completed_at', 'TEXT'),
    SchemaColumn('error_message', 'TEXT'),
    SchemaColumn('total_tokens', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('current_step_index', 'INTEGER', notNull: true, defaultValue: '0'),
    SchemaColumn('definition_json', 'TEXT', notNull: true, defaultValue: "'{}'"),
    SchemaColumn('execution_cursor_json', 'TEXT'),
    SchemaColumn('workflow_worktree_json', 'TEXT'),
  ]),
  SchemaTable('workflow_run_migrations', [
    SchemaColumn('name', 'TEXT', primaryKey: true),
    SchemaColumn('applied_at', 'TEXT', notNull: true),
  ]),
  SchemaTable('kg_facts', [
    SchemaColumn('id', 'INTEGER', primaryKey: true),
    SchemaColumn('entity', 'TEXT', notNull: true),
    SchemaColumn('predicate', 'TEXT', notNull: true),
    SchemaColumn('value', 'TEXT', notNull: true),
    SchemaColumn('valid_from', 'TEXT', notNull: true),
    SchemaColumn('valid_to', 'TEXT'),
    SchemaColumn('source', 'TEXT', notNull: true),
    SchemaColumn('owner', 'TEXT'),
    SchemaColumn('invalidated_at', 'TEXT'),
    SchemaColumn('invalidation_reason', 'TEXT'),
    SchemaColumn('created_at', 'TEXT', notNull: true, defaultValue: 'datetime(\'now\')'),
  ]),
];

const _taskIndexes = [
  SchemaIndex('idx_tasks_status', 'tasks', ['status']),
  SchemaIndex('idx_tasks_type', 'tasks', ['type']),
  SchemaIndex('idx_tasks_status_type', 'tasks', ['status', 'type']),
  SchemaIndex('idx_tasks_workflow_run_id', 'tasks', ['workflow_run_id']),
  SchemaIndex('idx_task_artifacts_task_id', 'task_artifacts', ['task_id']),
  SchemaIndex('idx_agent_executions_session_id', 'agent_executions', ['session_id']),
  SchemaIndex('idx_agent_executions_provider', 'agent_executions', ['provider']),
  SchemaIndex('idx_wse_run_step', 'workflow_step_executions', ['workflow_run_id', 'step_index']),
  SchemaIndex('idx_wse_agent_execution', 'workflow_step_executions', ['agent_execution_id']),
  SchemaIndex('idx_goals_parent', 'goals', ['parent_goal_id']),
  SchemaIndex('idx_task_events_task', 'task_events', ['task_id']),
  SchemaIndex('idx_task_events_task_kind', 'task_events', ['task_id', 'kind']),
  SchemaIndex('idx_task_events_timestamp', 'task_events', ['timestamp']),
  SchemaIndex('idx_turns_session', 'turns', ['session_id']),
  SchemaIndex('idx_turns_task', 'turns', ['task_id']),
  SchemaIndex('idx_turns_started', 'turns', ['started_at']),
  SchemaIndex('idx_turns_model', 'turns', ['model']),
  SchemaIndex('idx_turns_provider', 'turns', ['provider']),
  SchemaIndex('idx_workflow_runs_status', 'workflow_runs', ['status']),
  SchemaIndex('idx_workflow_runs_definition', 'workflow_runs', ['definition_name']),
  SchemaIndex('kg_facts_lookup', 'kg_facts', ['entity', 'predicate', 'valid_from', 'valid_to']),
];

const _taskBootstrap = [
  '''CREATE TABLE agent_executions (id TEXT PRIMARY KEY NOT NULL, session_id TEXT, provider TEXT, model TEXT,
    workspace_dir TEXT, container_json TEXT, budget_tokens INTEGER, harness_meta_json TEXT, started_at TEXT,
    completed_at TEXT)''',
  '''CREATE TABLE workflow_step_executions (task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
    agent_execution_id TEXT NOT NULL REFERENCES agent_executions(id), workflow_run_id TEXT NOT NULL,
    step_index INTEGER NOT NULL, step_id TEXT NOT NULL, step_type TEXT, git_json TEXT, provider_session_id TEXT,
    structured_schema_json TEXT, structured_output_json TEXT, follow_up_prompts_json TEXT, map_iteration_index INTEGER,
    map_iteration_total INTEGER, step_token_breakdown_json TEXT)''',
  '''CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL, type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft', version INTEGER NOT NULL DEFAULT 1, goal_id TEXT, acceptance_criteria TEXT,
    config_json TEXT NOT NULL DEFAULT '{}', worktree_json TEXT, created_at TEXT NOT NULL, started_at TEXT,
    completed_at TEXT, created_by TEXT, agent_execution_id TEXT REFERENCES agent_executions(id) ON DELETE RESTRICT,
    project_id TEXT, workflow_run_id TEXT, step_index INTEGER, max_retries INTEGER NOT NULL DEFAULT 0,
    retry_count INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX idx_tasks_status ON tasks(status)',
  'CREATE INDEX idx_tasks_type ON tasks(type)',
  'CREATE INDEX idx_tasks_status_type ON tasks(status, type)',
  'CREATE INDEX idx_tasks_workflow_run_id ON tasks(workflow_run_id)',
  '''CREATE TABLE task_artifacts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
    path TEXT NOT NULL, created_at TEXT NOT NULL, FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE)''',
  'CREATE INDEX idx_task_artifacts_task_id ON task_artifacts(task_id)',
  'CREATE INDEX idx_agent_executions_session_id ON agent_executions(session_id)',
  'CREATE INDEX idx_agent_executions_provider ON agent_executions(provider)',
  'CREATE INDEX idx_wse_run_step ON workflow_step_executions(workflow_run_id, step_index)',
  'CREATE INDEX idx_wse_agent_execution ON workflow_step_executions(agent_execution_id)',
  '''CREATE TABLE goals (id TEXT PRIMARY KEY, title TEXT NOT NULL, parent_goal_id TEXT, mission TEXT NOT NULL,
    created_at TEXT NOT NULL, max_tokens INTEGER)''',
  'CREATE INDEX idx_goals_parent ON goals(parent_goal_id)',
  '''CREATE TABLE task_events (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, timestamp TEXT NOT NULL, kind TEXT NOT NULL,
    details TEXT NOT NULL DEFAULT '{}')''',
  'CREATE INDEX idx_task_events_task ON task_events(task_id)',
  'CREATE INDEX idx_task_events_task_kind ON task_events(task_id, kind)',
  'CREATE INDEX idx_task_events_timestamp ON task_events(timestamp)',
  '''CREATE TABLE turns (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, task_id TEXT, runner_id INTEGER, model TEXT,
    provider TEXT, started_at TEXT NOT NULL, ended_at TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
    cache_write_tokens INTEGER NOT NULL DEFAULT 0, is_error INTEGER NOT NULL DEFAULT 0, error_type TEXT, tool_calls TEXT)''',
  'CREATE INDEX idx_turns_session ON turns(session_id)',
  'CREATE INDEX idx_turns_task ON turns(task_id)',
  'CREATE INDEX idx_turns_started ON turns(started_at)',
  'CREATE INDEX idx_turns_model ON turns(model)',
  'CREATE INDEX idx_turns_provider ON turns(provider)',
  '''CREATE TABLE workflow_runs (id TEXT PRIMARY KEY, definition_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', context_json TEXT NOT NULL DEFAULT '{}',
    variables_json TEXT NOT NULL DEFAULT '{}', started_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT,
    error_message TEXT, total_tokens INTEGER NOT NULL DEFAULT 0, current_step_index INTEGER NOT NULL DEFAULT 0,
    definition_json TEXT NOT NULL DEFAULT '{}', execution_cursor_json TEXT, workflow_worktree_json TEXT)''',
  'CREATE INDEX idx_workflow_runs_status ON workflow_runs(status)',
  'CREATE INDEX idx_workflow_runs_definition ON workflow_runs(definition_name)',
  'CREATE TABLE workflow_run_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)',
  '''CREATE TABLE kg_facts (id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, predicate TEXT NOT NULL,
    value TEXT NOT NULL, valid_from TEXT NOT NULL, valid_to TEXT, source TEXT NOT NULL, owner TEXT,
    invalidated_at TEXT, invalidation_reason TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')))''',
  'CREATE INDEX kg_facts_lookup ON kg_facts(entity, predicate, valid_from, valid_to)',
];

const _searchTables = [
  SchemaTable('memory_chunks', [
    SchemaColumn('id', 'INTEGER', primaryKey: true),
    SchemaColumn('text', 'TEXT', notNull: true),
    SchemaColumn('chunk_index', 'INTEGER', notNull: true),
    SchemaColumn('source', 'TEXT', notNull: true),
    SchemaColumn('category', 'TEXT'),
    SchemaColumn('created_at', 'TEXT', notNull: true, defaultValue: 'datetime(\'now\')'),
    SchemaColumn('user_id', 'TEXT', notNull: true, defaultValue: "'owner'"),
    SchemaColumn('role', 'TEXT', notNull: true, defaultValue: "'memory'"),
    SchemaColumn('provenance', 'TEXT', notNull: true, defaultValue: "'unknown'"),
    SchemaColumn('locator', 'TEXT'),
    SchemaColumn('entry_id', 'TEXT'),
    SchemaColumn('entry_revision', 'INTEGER'),
  ]),
  SchemaTable('conversation_chunks', [
    SchemaColumn('id', 'INTEGER', primaryKey: true),
    SchemaColumn('message_id', 'TEXT', notNull: true),
    SchemaColumn('user_id', 'TEXT', notNull: true),
    SchemaColumn('text', 'TEXT', notNull: true),
    SchemaColumn('chunk_index', 'INTEGER', notNull: true),
    SchemaColumn('session_id', 'TEXT', notNull: true),
    SchemaColumn('role', 'TEXT', notNull: true),
    SchemaColumn('created_at', 'TEXT', notNull: true),
  ]),
];

const _searchBootstrap = [
  '''CREATE TABLE memory_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL,
    chunk_index INTEGER NOT NULL, source TEXT NOT NULL,
    category TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')), user_id TEXT NOT NULL DEFAULT 'owner',
    role TEXT NOT NULL DEFAULT 'memory', provenance TEXT NOT NULL DEFAULT 'unknown', locator TEXT, entry_id TEXT,
    entry_revision INTEGER)''',
  '''CREATE VIRTUAL TABLE memory_chunks_fts USING fts5(body, content='memory_chunks', content_rowid='id')''',
  '''CREATE TRIGGER memory_chunks_ai AFTER INSERT ON memory_chunks BEGIN
    INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text); END''',
  '''CREATE TRIGGER memory_chunks_ad AFTER DELETE ON memory_chunks BEGIN
    INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text); END''',
  '''CREATE TRIGGER memory_chunks_au AFTER UPDATE ON memory_chunks BEGIN
    INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
    INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text); END''',
  '''CREATE TABLE conversation_chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL,
    user_id TEXT NOT NULL, text TEXT NOT NULL, chunk_index INTEGER NOT NULL, session_id TEXT NOT NULL, role TEXT NOT NULL,
    created_at TEXT NOT NULL)''',
  '''CREATE VIRTUAL TABLE conversation_chunks_fts USING fts5(body, content='conversation_chunks', content_rowid='id')''',
  '''CREATE TRIGGER conversation_chunks_ai AFTER INSERT ON conversation_chunks BEGIN
    INSERT INTO conversation_chunks_fts(rowid, body) VALUES (new.id, new.text); END''',
  '''CREATE TRIGGER conversation_chunks_ad AFTER DELETE ON conversation_chunks BEGIN
    INSERT INTO conversation_chunks_fts(conversation_chunks_fts, rowid, body) VALUES('delete', old.id, old.text); END''',
  '''CREATE TRIGGER conversation_chunks_au AFTER UPDATE ON conversation_chunks BEGIN
    INSERT INTO conversation_chunks_fts(conversation_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
    INSERT INTO conversation_chunks_fts(rowid, body) VALUES (new.id, new.text); END''',
];

const _searchObjects = [
  SqliteSchemaObject(
    'table',
    'memory_chunks_fts',
    'memory_chunks_fts',
    'CREATE VIRTUAL TABLE memory_chunks_fts USING fts5(body, content=\'memory_chunks\', content_rowid=\'id\')',
  ),
  SqliteSchemaObject(
    'trigger',
    'memory_chunks_ai',
    'memory_chunks',
    'CREATE TRIGGER memory_chunks_ai AFTER INSERT ON memory_chunks BEGIN '
        'INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text); END',
  ),
  SqliteSchemaObject(
    'trigger',
    'memory_chunks_ad',
    'memory_chunks',
    'CREATE TRIGGER memory_chunks_ad AFTER DELETE ON memory_chunks BEGIN INSERT INTO memory_chunks_fts('
        'memory_chunks_fts, rowid, body) VALUES(\'delete\', old.id, old.text); END',
  ),
  SqliteSchemaObject(
    'trigger',
    'memory_chunks_au',
    'memory_chunks',
    'CREATE TRIGGER memory_chunks_au AFTER UPDATE ON memory_chunks BEGIN INSERT INTO memory_chunks_fts('
        'memory_chunks_fts, rowid, body) VALUES(\'delete\', old.id, old.text); '
        'INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text); END',
  ),
  SqliteSchemaObject(
    'table',
    'conversation_chunks_fts',
    'conversation_chunks_fts',
    'CREATE VIRTUAL TABLE conversation_chunks_fts USING fts5(body, content=\'conversation_chunks\', '
        'content_rowid=\'id\')',
  ),
  SqliteSchemaObject(
    'trigger',
    'conversation_chunks_ai',
    'conversation_chunks',
    'CREATE TRIGGER conversation_chunks_ai AFTER INSERT ON conversation_chunks BEGIN '
        'INSERT INTO conversation_chunks_fts(rowid, body) VALUES (new.id, new.text); END',
  ),
  SqliteSchemaObject(
    'trigger',
    'conversation_chunks_ad',
    'conversation_chunks',
    'CREATE TRIGGER conversation_chunks_ad AFTER DELETE ON conversation_chunks BEGIN '
        'INSERT INTO conversation_chunks_fts(conversation_chunks_fts, rowid, body) '
        'VALUES(\'delete\', old.id, old.text); END',
  ),
  SqliteSchemaObject(
    'trigger',
    'conversation_chunks_au',
    'conversation_chunks',
    'CREATE TRIGGER conversation_chunks_au AFTER UPDATE ON conversation_chunks BEGIN '
        'INSERT INTO conversation_chunks_fts(conversation_chunks_fts, rowid, body) '
        'VALUES(\'delete\', old.id, old.text); '
        'INSERT INTO conversation_chunks_fts(rowid, body) VALUES (new.id, new.text); END',
  ),
];

const _searchDrops = [
  'DROP TRIGGER IF EXISTS conversation_chunks_ai',
  'DROP TRIGGER IF EXISTS conversation_chunks_ad',
  'DROP TRIGGER IF EXISTS conversation_chunks_au',
  'DROP TABLE IF EXISTS conversation_chunks_fts',
  'DROP TABLE IF EXISTS conversation_chunks',
  'DROP TRIGGER IF EXISTS memory_chunks_ai',
  'DROP TRIGGER IF EXISTS memory_chunks_ad',
  'DROP TRIGGER IF EXISTS memory_chunks_au',
  'DROP TABLE IF EXISTS memory_chunks_fts',
  'DROP TABLE IF EXISTS memory_chunks',
  'DROP TABLE IF EXISTS dartclaw_schema',
];
