#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys


data_dir = pathlib.Path(sys.argv[1])
temporary_id = sys.argv[2]
ordinary_id = sys.argv[3]
server_log = pathlib.Path(sys.argv[4])
backend = sys.argv[5]
ordinary_container = sys.argv[7] if len(sys.argv) > 7 else ''
temporary_markers = (
    'TEMPORARY_TURN_ONE',
    'TEMPORARY_TURN_TWO',
    'TEMPORARY_ATTACHMENT_MARKER',
    'TEMPORARY_TOOL_DETAIL_MARKER',
    'TEMPORARY_TOOL_REPLY_MARKER',
    'TEMPORARY_LINEAGE_MARKER',
    'TEMPORARY_PENDING_TOOL_MARKER',
    'TEMPORARY_ACTIVE_REPLY_MARKER',
    'TEMPORARY_QUEUED_INPUT_MARKER',
    'TEMPORARY_QUEUED_REPLY_MARKER',
)
results = {}


def require(condition, surface, detail):
    if not condition:
        raise SystemExit(f'{surface}: {detail}')
    results[surface] = detail


def text(path):
    return path.read_text(errors='replace')


def tree_text(root):
    chunks = []
    if not root.exists():
        return ''
    for path in root.rglob('*'):
        if path.is_file():
            chunks.append(path.read_bytes().decode('utf-8', errors='ignore'))
    return '\n'.join(chunks)


def postgres_rows(query):
    completed = subprocess.run(
        [
            'psql',
            os.environ['DARTCLAW_POSTGRES_URL'],
            '-X',
            '--no-align',
            '--tuples-only',
            '--set',
            'ON_ERROR_STOP=1',
            '--command',
            query,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [json.loads(line) for line in completed.stdout.splitlines() if line]


ordinary_dir = data_dir / 'sessions' / ordinary_id
temporary_dir = data_dir / 'sessions' / temporary_id
meta = text(ordinary_dir / 'meta.json')
messages_path = ordinary_dir / 'messages.ndjson'
messages = text(messages_path)
message_rows = [json.loads(line) for line in messages.splitlines() if line.strip()]
ordinary_message_ids = [row['id'] for row in message_rows if row.get('role') in ('user', 'assistant')]
temporary_rows = json.loads(text(pathlib.Path(sys.argv[4]).parent / 'temporary-messages.json'))
branch_session = json.loads(text(pathlib.Path(sys.argv[4]).parent / 'temporary-branch-session.json'))
branch_rows = json.loads(text(pathlib.Path(sys.argv[4]).parent / 'temporary-branch-messages.json'))
temporary_session_ids = {temporary_id, branch_session['id']}
temporary_message_ids = [
    row['id']
    for row in [*temporary_rows, *branch_rows]
    if row.get('role') in ('user', 'assistant')
]

require(ordinary_dir.is_dir() and ordinary_id in meta and not temporary_dir.exists(), 'session-meta', 'ordinary meta present; temporary directory absent')
require('ORDINARY_TURN_CONTROL' in messages and not any(marker in tree_text(data_dir / 'sessions') for marker in temporary_markers), 'messages', 'ordinary transcript present; temporary transcript absent')
require('conversationState' in meta and 'ordinary-replay-control' in meta, 'conversation-state', 'ordinary submission state persisted')
attachments = tree_text(ordinary_dir / 'attachments')
require('ORDINARY_ATTACHMENT_CONTROL' in attachments and 'ordinary-control.txt' in attachments, 'attachments', 'ordinary attachment bytes and metadata persisted')
kv = text(data_dir / 'kv.json')
require(f'session_cost:{ordinary_id}' in kv and f'session_cost:{temporary_id}' not in kv, 'usage-kv', 'ordinary usage key present; temporary key absent')

if backend == 'postgres':
    lexical = postgres_rows(
        "SELECT json_build_object('session_id', session_id, 'message_id', message_id, 'text', text)::text "
        'FROM conversation_chunks ORDER BY id'
    )
    require(
        any(row['session_id'] == ordinary_id and 'ORDINARY_TURN_CONTROL' in row['text'] for row in lexical)
        and all(row['session_id'] not in temporary_session_ids for row in lexical)
        and not any(marker in row['text'] for row in lexical for marker in temporary_markers),
        'lexical-index',
        'ordinary PostgreSQL lexical row present; temporary rows absent',
    )
    vectors = postgres_rows(
        "SELECT json_build_object('document_id', document_id)::text "
        'FROM conversation_vectors ORDER BY document_id, chunk_index'
    )
    vector_ids = {row['document_id'] for row in vectors}
    require(
        any(message_id in vector_ids for message_id in ordinary_message_ids)
        and not any(message_id in vector_ids for message_id in temporary_message_ids),
        'vector-index',
        'ordinary PostgreSQL conversation vector present; temporary vectors absent',
    )
else:
    raise SystemExit(f'unsupported backend: {backend}')

memory = tree_text(data_dir / 'workspace' / 'memory')
require('ORDINARY_TURN_CONTROL' in memory and not any(marker in memory for marker in temporary_markers), 'daily-log', 'ordinary daily-log record present; temporary records absent')
require('ORDINARY_MEMORY_CONTROL' in memory, 'memory', 'ordinary memory observation present')
audit = '\n'.join(text(path) for path in data_dir.glob('audit-*.ndjson'))
require(ordinary_id in audit and not any(marker in audit for marker in temporary_markers), 'audit-log', 'ordinary opaque operation present; temporary content absent')
log = text(server_log)
require('ORDINARY_PROCESS_CONTROL' in log and not any(marker in log for marker in temporary_markers), 'process-log', 'configured process control present; conversation content absent')
provider_home = tree_text(data_dir / 'containers' / ordinary_container)
require('ORDINARY_TURN_CONTROL' in provider_home and not any(marker in provider_home for marker in temporary_markers), 'provider-home', 'ordinary host-backed provider state present; temporary provider state absent')
replay = json.loads(text(pathlib.Path(sys.argv[4]).parent / 'ordinary-replay.json'))
require(replay.get('replayed') is True, 'replay', 'ordinary idempotent replay control observed')

print(json.dumps({'backend': backend, 'surfaces': results}, indent=2, sort_keys=True))
