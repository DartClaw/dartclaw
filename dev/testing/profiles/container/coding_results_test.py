import unittest
import pathlib
import subprocess
import tempfile
import json
import io
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import coding_results

from coding_results import baseline_error, command_result, git_commands, lockfile_after_run


def _shell_call(command, result, *, name='shell', **metadata):
    return {'name': name, 'arguments': json.dumps({'command': command}), 'result': result, **metadata}


class AcceptanceCommandEvidenceTest(unittest.TestCase):
    def test_hashing_dart_sources_is_not_a_later_test_attempt(self):
        success = _shell_call(
            '/bin/sh -lc \'dart test; result=$?; echo "DARTCLAW_ACCEPTANCE_EXIT=$result"; exit "$result"\'',
            'All tests passed!\nDARTCLAW_ACCEPTANCE_EXIT=0\n',
        )
        hashing = _shell_call(
            '/bin/sh -lc "sha256sum total.dart test/total_test.dart pubspec.lock"',
            'actual file hashes\n',
        )
        self.assertEqual(command_result([success, hashing], 'dart test')['exit'], 0)

    def test_command_identity_respects_shell_boundaries(self):
        success = _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=0\n')
        for script in ['echo dart test', 'printf "%s" "dart test"', 'sha256sum total.dart test/total_test.dart']:
            with self.subTest(script=script):
                other = _shell_call(script, 'not an acceptance command')
                self.assertEqual(command_result([success, other], 'dart test')['exit'], 0)
        for script in ['dart test', 'cd /project && dart test', '/bin/sh -lc "dart test"', 'echo ready\ndart test']:
            with self.subTest(script=script):
                attempted = _shell_call(script, 'terminated without marker')
                self.assertIsNone(command_result([success, attempted], 'dart test')['exit'])

    def test_unbalanced_quotes_in_a_script_never_hide_or_fake_an_attempt(self):
        success = _shell_call('go test ./...', 'DARTCLAW_ACCEPTANCE_EXIT=0\n')
        heredoc = _shell_call("cat > doc.go <<'EOF'\n// don't panic\nEOF", 'written\n')
        self.assertEqual(command_result([success, heredoc], 'go test ./...')['exit'], 0)
        attempted = _shell_call("echo don't\ngo test ./...", 'terminated without marker')
        self.assertIsNone(command_result([success, attempted], 'go test ./...')['exit'])

    def test_malformed_shell_arguments_cannot_reuse_earlier_evidence(self):
        success = _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=0\n')
        for arguments in [None, 'not JSON', '[]', '{}', '{"command": []}']:
            with self.subTest(arguments=arguments), self.assertRaisesRegex(RuntimeError, 'declared command object'):
                command_result([success, {'name': 'shell', 'arguments': arguments}], 'dart test')

    def test_git_results_preserve_a_compound_command_with_an_inner_failure(self):
        call = {'name': 'Bash', 'success': True, 'taskId': 'step',
                'arguments': '{"command":"git status --short; echo GIT_STATUS_EXIT=$?"}',
                'result': 'fatal: not a git repository\nGIT_STATUS_EXIT=128\n'}
        recorded = git_commands([call])
        self.assertEqual(len(recorded), 1)
        self.assertEqual(recorded[0]['success'], True)
        self.assertEqual(recorded[0]['result'], call['result'])
        self.assertEqual(git_commands([{**call, 'name': 'Write'}]), [])

    def test_codex_rollouts_are_checked_after_an_early_collection_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / 'story.md').write_text('Fixture story')
            args = ['coding_results.py', 'codex', 'node', str(root), str(root), str(root), str(root), '1']
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), \
                 patch('sys.argv', args), \
                 patch.object(coding_results, 'api', return_value={'_meta': {'configPath': str(root / 'dartclaw.yaml')}}), \
                 patch.object(coding_results, 'dartclaw_rollouts', side_effect=[set(), {'unexpected-rollout'}]) as inventory, \
                 patch.object(coding_results.subprocess, 'run', side_effect=OSError('CLI unavailable')):
                self.assertEqual(coding_results.main(), 1)
                self.assertEqual(inventory.call_count, 2)
            row = json.loads((root / 'results.json').read_text())[0]
            self.assertEqual(row['newRollouts'], ['unexpected-rollout'])
            self.assertIn('CLI unavailable', row['error'])
            self.assertIn('New DartClaw rollouts', row['error'])

    def test_foreign_server_is_rejected_before_launching_a_workflow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / 'story.md').write_text('Fixture story')
            args = ['coding_results.py', 'claude', 'node', str(root), str(root), str(root), str(root), '1']
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), \
                 patch('sys.argv', args), \
                 patch.object(coding_results, 'api', return_value={'_meta': {'configPath': str(root / 'foreign.yaml')}}), \
                 patch.object(coding_results.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as run:
                self.assertEqual(coding_results.main(), 1)
                run.assert_not_called()
            row = json.loads((root / 'results.json').read_text())[0]
            self.assertIn('does not belong to this profile', row['error'])

    def test_result_table_keeps_all_rows_before_case_details(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            row = {'provider': 'codex', 'fixture': 'dart', 'install': {'command': 'dart pub get', 'exit': 127, 'output': 'missing'},
                   'test': {'command': 'dart test', 'exit': 127, 'output': 'missing'}, 'placement': 'workspace',
                   'status': 'failed', 'cliExit': 1, 'tasks': [], 'gitCommands': [], 'lockDiff': '(unchanged)',
                   'completedCodexSteps': 2, 'newRollouts': []}
            coding_results.record_row(root, row)
            coding_results.record_row(root, {**row, 'fixture': 'node'})
            result = (root / 'results.md').read_text()
            self.assertLess(result.index('| codex | node |'), result.index('## codex / dart'))

    def test_registry_counts_include_transport_refusals_and_count_routed_blocks_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            request = {'guard': 'host-gateway', 'hook': 'bridge', 'principal': 'authority-1',
                       'server': 'npm', 'tool': '/npm/lodash'}
            served = {**request, 'reason': 'status=404', 'verdict': 'pass', 'decision': 'allow'}
            refused = {**request, 'reason': 'status=405', 'verdict': 'block', 'decision': 'deny'}
            mcp = {'guard': 'host-gateway', 'hook': 'bridge', 'verdict': 'block',
                   'reason': 'mcp: tool "list_resources" is not authorized', 'sessionId': 'session-1'}
            routed_event = {**mcp, 'reason': 'registry: registry npm: only GET and HEAD are allowed'}
            queue_event = {**mcp, 'reason': 'registry: bridge in-flight limit reached'}
            cap_event = {**mcp, 'reason': 'registry: upstream response exceeds 67108864 bytes'}
            (root / 'audit-2026-11-17.ndjson').write_text('\n'.join(map(json.dumps, [mcp, served, queue_event])) + '\n')
            (root / 'audit-2026-11-18.ndjson').write_text('\n'.join(map(json.dumps, [refused, routed_event, cap_event])) + '\n')
            requests = coding_results.registry_requests(root)
            self.assertEqual(requests, [served, queue_event, refused, routed_event, cap_event])
            self.assertEqual(coding_results.registry_counts(requests), {'served': 1, 'refused': 3})

    def test_registry_refusal_preserves_baseline_recording_and_fails_qualification(self):
        for baseline in ('1', '0'):
            with self.subTest(baseline=baseline), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                (root / 'story.md').write_text('Fixture story')
                exit_code = int(baseline)
                status = 'failed' if exit_code else 'completed'
                run = {'id': 'run', 'status': status, 'currentStepIndex': 0, 'childTaskIds': ['task'],
                       'steps': [{'id': 'step', 'index': 0, 'taskId': 'task'}], 'contextJson': {'data': {}}}
                tool_calls = [_shell_call(command, f'DARTCLAW_ACCEPTANCE_EXIT={exit_code}\n')
                              for command in ('npm install', 'npm test')]
                responses = {
                    '/api/config': {'_meta': {'configPath': str(root / 'dartclaw.yaml')}},
                    '/api/workflows/runs/run': run,
                    '/api/tasks/task': {'status': 'failed' if exit_code else 'accepted',
                                        'agentExecution': {'containerJson': {'profile': 'workspace'}}},
                    '/api/traces?taskId=task&limit=500&offset=0': {
                        'traces': [{'taskId': 'task', 'startedAt': 'now', 'toolCalls': tool_calls}]},
                }
                refusal = {'guard': 'host-gateway', 'hook': 'bridge', 'verdict': 'block',
                           'reason': 'registry: bridge in-flight limit reached'}
                (root / 'audit-2026-11-17.ndjson').write_text(json.dumps(refusal) + '\n')

                def subprocess_run(argv, **kwargs):
                    if argv[0] == 'dart':
                        kwargs['stdout'].write('{"type":"run_started","run":{"id":"run"}}\n')
                        return subprocess.CompletedProcess(argv, exit_code)
                    return subprocess.CompletedProcess(argv, 0, stdout='')

                args = ['coding_results.py', 'claude', 'node', *(str(root) for _ in range(4)), baseline]
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), \
                     patch('sys.argv', args), patch.object(coding_results, 'api', side_effect=responses.__getitem__), \
                     patch.object(coding_results.subprocess, 'run', side_effect=subprocess_run):
                    self.assertEqual(coding_results.main(), 0 if exit_code else 1)
                row = json.loads((root / 'results.json').read_text())[0]
                self.assertEqual(row['registryCounts'], {'served': 0, 'refused': 1})
                if not exit_code:
                    self.assertIn('Registry requests were refused', row['error'])

    def test_each_fixture_maps_to_its_commands_and_registry_routes(self):
        self.assertEqual(coding_results.FIXTURES['python'], (('uv sync', 'uv run pytest'), 'pypi', ('pypi', 'pypi-files')))
        self.assertEqual(coding_results.FIXTURES['rust'], (('cargo fetch', 'cargo test'), 'crates', ('crates', 'crates-dl')))
        self.assertEqual(coding_results.FIXTURES['go'][1:], ('go', ('go', 'gosum')))
        self.assertEqual(coding_results.FIXTURES['go'][0][1], 'go test ./...')
        self.assertEqual(set(coding_results.FIXTURES), {'dart', 'node', 'python', 'rust', 'go'})

    def test_qualification_requires_a_served_request_on_every_route_of_the_fixture_record(self):
        for fixture, served, error in [
            ('rust', ['/crates/config.json'], '/crates-dl/'),
            ('rust', ['/crates/config.json', '/crates-dl/crates/either/1.0.0/download'], None),
            ('python', ['/pypi/simple/pydash/?x=1'], '/pypi-files/'),
            ('go', ['/go/github.com/samber/lo/@v/list', '/gosum/lookup/x'], None),
            ('go', ['/go/github.com/samber/lo/@v/list'], '/gosum/'),
        ]:
            with self.subTest(fixture=fixture, served=served), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                (root / 'story.md').write_text('Fixture story')
                commands, ecosystem, _ = coding_results.FIXTURES[fixture]
                run = {'id': 'run', 'status': 'completed', 'currentStepIndex': 0, 'childTaskIds': ['task'],
                       'steps': [{'id': 'step', 'index': 0, 'taskId': 'task'}], 'contextJson': {'data': {}}}
                tool_calls = [_shell_call(command, 'DARTCLAW_ACCEPTANCE_EXIT=0\n') for command in commands]
                responses = {
                    '/api/config': {'_meta': {'configPath': str(root / 'dartclaw.yaml')}},
                    '/api/workflows/runs/run': run,
                    '/api/tasks/task': {'status': 'accepted', 'agentExecution': {'containerJson': {'profile': 'workspace'}}},
                    '/api/traces?taskId=task&limit=500&offset=0': {
                        'traces': [{'taskId': 'task', 'startedAt': 'now', 'toolCalls': tool_calls}]},
                }
                (root / 'audit-2026-11-18.ndjson').write_text(''.join(
                    json.dumps({'guard': 'host-gateway', 'hook': 'bridge', 'principal': 'authority-1', 'server': ecosystem,
                                'tool': path, 'verdict': 'pass', 'decision': 'allow', 'reason': 'status=200'}) + '\n'
                    for path in served))

                def subprocess_run(argv, **kwargs):
                    if argv[0] == 'dart':
                        kwargs['stdout'].write('{"type":"run_started","run":{"id":"run"}}\n')
                    return subprocess.CompletedProcess(argv, 0, stdout='')

                args = ['coding_results.py', 'claude', fixture, *(str(root) for _ in range(4)), '0']
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), \
                     patch('sys.argv', args), patch.object(coding_results, 'api', side_effect=responses.__getitem__), \
                     patch.object(coding_results.subprocess, 'run', side_effect=subprocess_run):
                    self.assertEqual(coding_results.main(), 1 if error else 0)
                row = json.loads((root / 'results.json').read_text())[0]
                self.assertEqual([row['install']['command'], row['test']['command']], list(commands))
                if error:
                    self.assertIn(error, row['error'])
                else:
                    self.assertNotIn('error', row, row.get('error'))

    def test_baseline_ignores_only_recorded_acceptance_failures(self):
        row = {'status': 'completed', 'failureTaskId': 'step', 'tasks': [{'taskId': 'step', 'status': 'accepted'}],
               'install': {'exit': 127, 'taskId': 'step'}, 'test': {'exit': 127, 'taskId': 'step'}}
        self.assertIsNone(baseline_error(row))
        row['status'] = 'failed'
        row['tasks'][0]['stepOutcome'] = 'failed'
        self.assertIsNone(baseline_error(row))
        row['tasks'][0]['status'] = 'failed'
        self.assertIsNone(baseline_error(row))
        for status in ('cancelled', 'paused', 'awaitingApproval'):
            with self.subTest(status=status):
                self.assertIsNotNone(baseline_error({**row, 'status': status}))
        self.assertIsNotNone(baseline_error({**row, 'failureTaskId': None}))
        self.assertIsNotNone(baseline_error({**row, 'failureTaskId': 'publish'}))
        row['tasks'] = [{'taskId': 'publish', 'status': 'failed'}]
        self.assertIsNotNone(baseline_error(row))
        row['tasks'] = [{'taskId': 'step', 'status': 'failed'}]
        row['install']['exit'] = row['test']['exit'] = 0
        self.assertIsNotNone(baseline_error(row))

    def test_lockfile_remains_observable_after_published_worktree_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            repository, remote = root / 'project', root / 'origin.git'
            repository.mkdir()
            def git(*args):
                return subprocess.run(['git', '-C', str(repository), *args], check=True, capture_output=True, text=True)
            git('init', '--initial-branch=main')
            (repository / 'pubspec.lock').write_text('container lockfile\n')
            git('add', 'pubspec.lock')
            git('-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
            git('branch', 'delivered')
            git('clone', '--bare', '.', str(remote))
            git('branch', '--delete', 'delivered')
            run = {'contextJson': {'data': {'publish.branch': 'delivered'}}}
            tasks = [{'worktreeJson': {'path': str(root / 'removed-worktree')}}]
            self.assertEqual(lockfile_after_run(run, tasks, remote), 'container lockfile\n')

    def test_final_recorded_attempt_decides_the_outcome(self):
        calls = [
            _shell_call('dart pub get', 'unreachable\nDARTCLAW_ACCEPTANCE_EXIT=1\n'),
            _shell_call('dart pub get', 'installed\nDARTCLAW_ACCEPTANCE_EXIT=0\n'),
            _shell_call('dart test', 'failed\nDARTCLAW_ACCEPTANCE_EXIT=1\n'),
        ]
        self.assertEqual(command_result(calls, 'dart pub get')['exit'], 0)
        self.assertEqual(command_result(calls, 'dart test')['exit'], 1)

    def test_report_writes_cannot_supply_or_override_command_evidence(self):
        success = _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=0\n', name='Bash')
        report = {'name': 'Write', 'arguments': '{"content":"dart test"}', 'result': 'report written'}
        self.assertEqual(command_result([success, report], 'dart test')['exit'], 0)
        self.assertIsNone(command_result([{**report, 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n'}], 'dart test')['exit'])

    def test_latest_invalid_attempt_does_not_reuse_an_earlier_success(self):
        success = _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=0\n')
        for result in [
            _shell_call('dart test', 'terminated before exit marker'),
            _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=1\n', isTruncated=True),
            _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=1\nDARTCLAW_ACCEPTANCE_EXIT=0\n'),
        ]:
            with self.subTest(result=result):
                self.assertIsNone(command_result([success, result], 'dart test')['exit'])

    def test_missing_ambiguous_or_truncated_evidence_never_becomes_success(self):
        for call in [
            _shell_call('dart test', 'All tests passed'),
            _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=0\n', isTruncated=True),
            _shell_call('dart test', 'DARTCLAW_ACCEPTANCE_EXIT=1\nDARTCLAW_ACCEPTANCE_EXIT=0\n'),
            _shell_call('echo dart', 'DARTCLAW_ACCEPTANCE_EXIT=0\n'),
        ]:
            with self.subTest(call=call):
                self.assertIsNone(command_result([call], 'dart test')['exit'])


if __name__ == '__main__':
    unittest.main()
