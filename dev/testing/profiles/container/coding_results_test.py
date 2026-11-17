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


class AcceptanceCommandEvidenceTest(unittest.TestCase):
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
            {'name': 'shell', 'arguments': 'dart pub get', 'result': 'unreachable\nDARTCLAW_ACCEPTANCE_EXIT=1\n'},
            {'name': 'shell', 'arguments': 'dart pub get', 'result': 'installed\nDARTCLAW_ACCEPTANCE_EXIT=0\n'},
            {'name': 'shell', 'arguments': 'dart test', 'result': 'failed\nDARTCLAW_ACCEPTANCE_EXIT=1\n'},
        ]
        self.assertEqual(command_result(calls, 'dart pub get')['exit'], 0)
        self.assertEqual(command_result(calls, 'dart test')['exit'], 1)

    def test_report_writes_cannot_supply_or_override_command_evidence(self):
        success = {'name': 'Bash', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n'}
        report = {'name': 'Write', 'arguments': '{"content":"dart test"}', 'result': 'report written'}
        self.assertEqual(command_result([success, report], 'dart test')['exit'], 0)
        self.assertIsNone(command_result([{**report, 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n'}], 'dart test')['exit'])

    def test_latest_invalid_attempt_does_not_reuse_an_earlier_success(self):
        success = {'name': 'shell', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n'}
        for result in [
            {'name': 'shell', 'arguments': 'dart test', 'result': 'terminated before exit marker'},
            {'name': 'shell', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=1\n', 'isTruncated': True},
            {'name': 'shell', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=1\nDARTCLAW_ACCEPTANCE_EXIT=0\n'},
        ]:
            with self.subTest(result=result):
                self.assertIsNone(command_result([success, result], 'dart test')['exit'])

    def test_missing_ambiguous_or_truncated_evidence_never_becomes_success(self):
        for call in [
            {'name': 'shell', 'arguments': 'dart test', 'result': 'All tests passed'},
            {'name': 'shell', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n', 'isTruncated': True},
            {'name': 'shell', 'arguments': 'dart test', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=1\nDARTCLAW_ACCEPTANCE_EXIT=0\n'},
            {'name': 'shell', 'arguments': 'echo dart', 'result': 'DARTCLAW_ACCEPTANCE_EXIT=0\n'},
        ]:
            with self.subTest(call=call):
                self.assertIsNone(command_result([call], 'dart test')['exit'])


if __name__ == '__main__':
    unittest.main()
