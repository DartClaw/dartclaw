import 'package:sqlite3/sqlite3.dart';

enum TasksSchemaFixture { released025, upgraded024, ownerlessKg, goalsWithoutMaxTokens, legacyTasks }

void createTasksSchemaFixture(Database database, TasksSchemaFixture fixture) {
  for (var index = 0; index < _released025TasksDdl.length; index++) {
    var sql = _released025TasksDdl[index];
    if (index == 1 && fixture == TasksSchemaFixture.upgraded024) sql = _upgraded024WorkflowStepExecutions;
    if (index == 2 && fixture == TasksSchemaFixture.legacyTasks) sql = _legacyTasks;
    if (fixture == TasksSchemaFixture.goalsWithoutMaxTokens &&
        sql == 'ALTER TABLE goals ADD COLUMN max_tokens INTEGER') {
      continue;
    }
    if (index == 30 && fixture == TasksSchemaFixture.ownerlessKg) sql = _ownerlessKgFacts;
    database.execute(sql);
  }
}

void createReleased025SearchSchema(Database database) {
  for (final sql in released025SearchDdl) {
    database.execute(sql);
  }
}

void create023SearchSchema(Database database) {
  database.execute(_search023Table);
  for (var index = 1; index < released025SearchDdl.length; index++) {
    database.execute(released025SearchDdl[index]);
  }
}

const _released025TasksDdl = <String>[
  '''
    CREATE TABLE IF NOT EXISTS agent_executions (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT,
      provider TEXT,
      model TEXT,
      workspace_dir TEXT,
      container_json TEXT,
      budget_tokens INTEGER,
      harness_meta_json TEXT,
      started_at TEXT,
      completed_at TEXT
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS workflow_step_executions (
      task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
      agent_execution_id TEXT NOT NULL REFERENCES agent_executions(id),
      workflow_run_id TEXT NOT NULL,
      step_index INTEGER NOT NULL,
      step_id TEXT NOT NULL,
      step_type TEXT,
      git_json TEXT,
      provider_session_id TEXT,
      structured_schema_json TEXT,
      structured_output_json TEXT,
      follow_up_prompts_json TEXT,
      map_iteration_index INTEGER,
      map_iteration_total INTEGER,
      step_token_breakdown_json TEXT
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft',
      version INTEGER NOT NULL DEFAULT 1,
      goal_id TEXT,
      acceptance_criteria TEXT,
      config_json TEXT NOT NULL DEFAULT '{}',
      worktree_json TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      created_by TEXT,
      agent_execution_id TEXT REFERENCES agent_executions(id) ON DELETE RESTRICT,
      project_id TEXT,
      workflow_run_id TEXT,
      step_index INTEGER,
      max_retries INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_status_type ON tasks(status, type)',
  'CREATE INDEX IF NOT EXISTS idx_tasks_workflow_run_id ON tasks(workflow_run_id)',
  '''
    CREATE TABLE IF NOT EXISTS task_artifacts (
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      path TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_task_artifacts_task_id ON task_artifacts(task_id)',
  'CREATE INDEX IF NOT EXISTS idx_agent_executions_session_id ON agent_executions(session_id)',
  'CREATE INDEX IF NOT EXISTS idx_agent_executions_provider ON agent_executions(provider)',
  'CREATE INDEX IF NOT EXISTS idx_wse_run_step ON workflow_step_executions(workflow_run_id, step_index)',
  'CREATE INDEX IF NOT EXISTS idx_wse_agent_execution ON workflow_step_executions(agent_execution_id)',
  '''
    CREATE TABLE IF NOT EXISTS goals (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      parent_goal_id TEXT,
      mission TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_goals_parent ON goals(parent_goal_id)',
  'ALTER TABLE goals ADD COLUMN max_tokens INTEGER',
  '''
    CREATE TABLE IF NOT EXISTS task_events (
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      kind TEXT NOT NULL,
      details TEXT NOT NULL DEFAULT '{}'
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id)',
  'CREATE INDEX IF NOT EXISTS idx_task_events_task_kind ON task_events(task_id, kind)',
  'CREATE INDEX IF NOT EXISTS idx_task_events_timestamp ON task_events(timestamp)',
  '''
    CREATE TABLE IF NOT EXISTS turns (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      task_id TEXT,
      runner_id INTEGER,
      model TEXT,
      provider TEXT,
      started_at TEXT NOT NULL,
      ended_at TEXT NOT NULL,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      is_error INTEGER NOT NULL DEFAULT 0,
      error_type TEXT,
      tool_calls TEXT
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id)',
  'CREATE INDEX IF NOT EXISTS idx_turns_task ON turns(task_id)',
  'CREATE INDEX IF NOT EXISTS idx_turns_started ON turns(started_at)',
  'CREATE INDEX IF NOT EXISTS idx_turns_model ON turns(model)',
  'CREATE INDEX IF NOT EXISTS idx_turns_provider ON turns(provider)',
  '''
    CREATE TABLE IF NOT EXISTS workflow_runs (
      id TEXT PRIMARY KEY,
      definition_name TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      context_json TEXT NOT NULL DEFAULT '{}',
      variables_json TEXT NOT NULL DEFAULT '{}',
      started_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      error_message TEXT,
      total_tokens INTEGER NOT NULL DEFAULT 0,
      current_step_index INTEGER NOT NULL DEFAULT 0,
      definition_json TEXT NOT NULL DEFAULT '{}',
      execution_cursor_json TEXT,
      workflow_worktree_json TEXT
    )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_workflow_runs_status ON workflow_runs(status)',
  'CREATE INDEX IF NOT EXISTS idx_workflow_runs_definition ON workflow_runs(definition_name)',
  '''
    CREATE TABLE IF NOT EXISTS workflow_run_migrations (
      name TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
  ''',
  '''
    CREATE TABLE IF NOT EXISTS kg_facts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity TEXT NOT NULL,
      predicate TEXT NOT NULL,
      value TEXT NOT NULL,
      valid_from TEXT NOT NULL,
      valid_to TEXT,
      source TEXT NOT NULL,
      owner TEXT,
      invalidated_at TEXT,
      invalidation_reason TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  ''',
  'CREATE INDEX IF NOT EXISTS kg_facts_lookup ON kg_facts(entity, predicate, valid_from, valid_to)',
];

const _upgraded024WorkflowStepExecutions = '''
  CREATE TABLE IF NOT EXISTS workflow_step_executions (
    task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
    agent_execution_id TEXT NOT NULL REFERENCES agent_executions(id),
    workflow_run_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    step_id TEXT NOT NULL,
    step_type TEXT,
    git_json TEXT,
    provider_session_id TEXT,
    structured_schema_json TEXT,
    structured_output_json TEXT,
    follow_up_prompts_json TEXT,
    external_artifact_mount TEXT,
    map_iteration_index INTEGER,
    map_iteration_total INTEGER,
    step_token_breakdown_json TEXT
  )
''';

const _ownerlessKgFacts = '''
  CREATE TABLE IF NOT EXISTS kg_facts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity TEXT NOT NULL,
    predicate TEXT NOT NULL,
    value TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    valid_to TEXT,
    source TEXT NOT NULL,
    invalidated_at TEXT,
    invalidation_reason TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  )
''';

const _legacyTasks = '''
  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL, type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft', version INTEGER NOT NULL DEFAULT 1, goal_id TEXT,
    acceptance_criteria TEXT, config_json TEXT NOT NULL DEFAULT '{}', worktree_json TEXT,
    created_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, created_by TEXT, project_id TEXT,
    workflow_run_id TEXT, step_index INTEGER, max_retries INTEGER NOT NULL DEFAULT 0,
    retry_count INTEGER NOT NULL DEFAULT 0
  )
''';

const released025SearchDdl = <String>[
  '''
    CREATE TABLE IF NOT EXISTS memory_chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT NOT NULL,
      source TEXT NOT NULL,
      category TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      user_id TEXT NOT NULL DEFAULT 'owner',
      role TEXT NOT NULL DEFAULT 'memory',
      provenance TEXT NOT NULL DEFAULT 'unknown',
      locator TEXT,
      entry_id TEXT,
      entry_revision INTEGER
    )
  ''',
  '''
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunks_fts USING fts5(
      body,
      content='memory_chunks',
      content_rowid='id'
    )
  ''',
  '''
    CREATE TRIGGER IF NOT EXISTS memory_chunks_ai AFTER INSERT ON memory_chunks BEGIN
      INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text);
    END
  ''',
  '''
    CREATE TRIGGER IF NOT EXISTS memory_chunks_ad AFTER DELETE ON memory_chunks BEGIN
      INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
    END
  ''',
  '''
    CREATE TRIGGER IF NOT EXISTS memory_chunks_au AFTER UPDATE ON memory_chunks BEGIN
      INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
      INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text);
    END
  ''',
];

const _search023Table = '''
    CREATE TABLE IF NOT EXISTS memory_chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT NOT NULL,
      source TEXT NOT NULL,
      category TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      user_id TEXT NOT NULL DEFAULT 'owner'
    )
  ''';
