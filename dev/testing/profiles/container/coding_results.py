"""Record live container workflow evidence from task and tool-trace APIs."""

import difflib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request


COMMAND_TOOLS = ('shell', 'Bash')


def api(path):
    with urllib.request.urlopen("http://localhost:3343" + path, timeout=30) as response:
        return json.load(response)


def dartclaw_rollouts():
    root = pathlib.Path.home() / ".codex/sessions"
    found = set()
    for path in root.rglob("rollout-*.jsonl") if root.is_dir() else []:
        with path.open() as source:
            record = json.loads(source.readline())
        if record.get("payload", {}).get("originator") == "dartclaw":
            found.add(str(path))
    return found


def command_result(calls, command):
    for call in reversed(calls):
        if call.get('name') not in COMMAND_TOOLS:
            continue
        arguments = (call.get("context") or "") + "\n" + (call.get("arguments") or "")
        if command not in arguments:
            continue
        result = call.get("result") or ""
        exits = re.findall(r"(?m)^DARTCLAW_ACCEPTANCE_EXIT=(\d+)\s*$", result)
        if len(exits) == 1 and not call.get("isTruncated", False):
            return {"command": command, "exit": int(exits[0]), "output": result[-4000:], "taskId": call.get('taskId')}
        break
    return {"command": command, "exit": None, "output": "No complete tool result recorded for the latest attempt."}


def git_commands(calls):
    return [{key: call.get(key) for key in ('name', 'success', 'taskId', 'context', 'arguments', 'result')}
            for call in calls if call.get('name') in COMMAND_TOOLS
            and 'git ' in ((call.get('context') or '') + (call.get('arguments') or ''))]


def baseline_error(row):
    if row['status'] == 'completed':
        return None
    failed = {task['taskId'] for task in row['tasks'] if task['status'] == 'failed' or task.get('stepOutcome') == 'failed'}
    acceptance_failures = {result.get('taskId') for result in (row['install'], row['test']) if result['exit'] not in (None, 0)}
    if row['status'] == 'failed' and row.get('failureTaskId') in failed and failed <= acceptance_failures:
        return None
    return 'Workflow failure is not linked to an acceptance command failure.'


def record_row(result_dir, row):
    records = result_dir / "results.json"
    rows = json.loads(records.read_text()) if records.exists() else []
    rows.append(row)
    records.write_text(json.dumps(rows, indent=2) + "\n")
    lines = ["# Container coding results", "", "| Provider | Fixture | Run | Install exit | Test exit | Placement |", "|---|---|---|---|---|---|"]
    for item in rows:
        lines.append(f"| {item['provider']} | {item['fixture']} | {item.get('runId', 'not started')} | {item['install']['exit']} | {item['test']['exit']} | {item['placement']} |")
    for item in rows:
        lines.extend(["", f"## {item['provider']} / {item['fixture']}", "", f"Workflow status: {item.get('status', 'unavailable')}; CLI exit: {item['cliExit']}", "", "Task placements:", "", "```json", json.dumps(item['tasks'], indent=2), "```"])
        for command in (item['install'], item['test']):
            lines.extend(["", f"### `{command['command']}`: exit {command['exit']}", "", "```text", command['output'], "```"])
        lines.extend(["", "Git command results:", "", "```json", json.dumps(item['gitCommands'], indent=2), "```"])
        if item['fixture'] == "dart":
            lines.extend(["", "Dart lockfile diff:", "", "```diff", item['lockDiff'], "```"])
        lines.extend(["", f"Completed Codex steps: {item['completedCodexSteps']}; new system-home DartClaw rollouts: {len(item['newRollouts'])}"])
        if item.get('error'):
            lines.extend(["", "Failure: " + item['error']])
    (result_dir / "results.md").write_text("\n".join(lines) + "\n")


def lockfile_after_run(run, tasks, remote):
    for task in tasks:
        worktree = task.get('worktreeJson') or {}
        if not worktree.get('path'):
            continue
        lockfile = pathlib.Path(worktree['path']) / 'pubspec.lock'
        if lockfile.is_symlink():
            raise RuntimeError('Refusing a symlinked fixture lockfile.')
        if lockfile.is_file():
            return lockfile.read_text()
    # Successful publish removes its local branch and worktree; the bare remote retains the delivered tree.
    branch = run['contextJson']['data'].get('publish.branch')
    if not branch:
        raise RuntimeError('No task worktree or published lockfile is available for comparison.')
    return subprocess.run(['git', '--git-dir', str(remote), 'show', branch + ':pubspec.lock'], capture_output=True, text=True, check=True).stdout


def main():
    provider, fixture, data, project, remote, output, baseline = sys.argv[1:]
    data, project, output = pathlib.Path(data), pathlib.Path(project), pathlib.Path(output)
    commands = ("dart pub get", "dart test") if fixture == "dart" else ("npm install", "npm test")
    row = {"provider": provider, "fixture": fixture, "install": {"command": commands[0], "exit": None, "output": "not run"}, "test": {"command": commands[1], "exit": None, "output": "not run"}, "tasks": [], "placement": "failed", "gitCommands": [], "lockDiff": "not observed", "completedCodexSteps": 0, "newRollouts": [], "cliExit": None}
    before_rollouts = dartclaw_rollouts() if provider == "codex" else set()
    started = time.time()
    cli_log = output / f"{provider}-{fixture}-workflow.jsonl"
    try:
        config_path = api('/api/config').get('_meta', {}).get('configPath')
        if not isinstance(config_path, str) or pathlib.Path(config_path).resolve() != (data / 'dartclaw.yaml').resolve():
            raise RuntimeError('Server on port 3343 does not belong to this profile; refusing to launch a workflow.')
        with cli_log.open("w") as log:
            outcome = subprocess.run(["dart", "run", "apps/dartclaw_cli/bin/dartclaw.dart", "--config", str(data / "dartclaw.yaml"), "workflow", "run", "implement-story", "-p", "coding-fixture", "-v", "FEATURE=" + (project / "story.md").read_text(), "--json"], stdout=log, stderr=subprocess.STDOUT, timeout=7200)
        row['cliExit'] = outcome.returncode
        events = [json.loads(line) for line in cli_log.read_text().splitlines() if line.strip()]
        starts = [event['run']['id'] for event in events if event.get('type') == 'run_started']
        if len(starts) != 1:
            raise RuntimeError(f"Expected one workflow run_started event, received {len(starts)}. See {cli_log.name}.")
        run = api('/api/workflows/runs/' + starts[0])
        row.update(runId=run['id'], status=run['status'])
        (output / f"{provider}-{fixture}-run.json").write_text(json.dumps(run, indent=2) + '\n')
        steps_by_task = {step['taskId']: step for step in run['steps'] if step.get('taskId')}
        row['failureTaskId'] = next((step.get('taskId') for step in run['steps'] if step['index'] == run['currentStepIndex']), None)
        task_ids = run['childTaskIds']
        if not task_ids:
            raise RuntimeError("Workflow created no tasks; container proof would be vacuous.")
        trace_records = []
        lock = project / 'pubspec.lock'
        for task_id in task_ids:
            task = api('/api/tasks/' + task_id)
            execution = task.get('agentExecution') or {}
            placement = execution.get('containerJson')
            step_id = steps_by_task.get(task_id, {}).get('id')
            step_outcome = run['contextJson']['data'].get(f'step.{step_id}.outcome')
            row['tasks'].append({'taskId': task_id, 'status': task['status'], 'stepOutcome': step_outcome, 'containerJson': placement, 'worktreeJson': task.get('worktreeJson')})
            if not isinstance(placement, dict) or placement.get('profile') != 'workspace':
                raise RuntimeError(f"Task {task_id} has no persisted workspace container placement.")
            if provider == 'codex' and task['status'] in ('review', 'accepted'):
                row['completedCodexSteps'] += 1
            offset = 0
            while True:
                traces = api(f'/api/traces?taskId={task_id}&limit=500&offset={offset}')['traces']
                trace_records.extend(traces)
                if len(traces) < 500:
                    break
                offset += 500
        row['placement'] = 'workspace'
        calls = [{**call, 'taskId': trace['taskId']} for trace in sorted(trace_records, key=lambda trace: trace['startedAt']) for call in trace['toolCalls']]
        row['install'], row['test'] = [command_result(calls, command) for command in commands]
        row['gitCommands'] = git_commands(calls)
        (output / f"{provider}-{fixture}-tools.json").write_text(json.dumps(calls, indent=2) + '\n')
        if fixture == 'dart':
            observed_lock = lockfile_after_run(run, row['tasks'], remote)
            row['lockDiff'] = ''.join(difflib.unified_diff(lock.read_text().splitlines(True), observed_lock.splitlines(True), fromfile='committed/pubspec.lock', tofile='container/pubspec.lock')) or '(unchanged)'
        if provider == 'codex':
            if not row['completedCodexSteps']:
                raise RuntimeError('No completed Codex step; rollout observation is vacuous.')
        status = subprocess.run(['git', '-C', str(project), 'status', '--porcelain'], capture_output=True, text=True, check=True).stdout
        if status:
            raise RuntimeError('Original fixture changed: ' + status)
        if any(item['exit'] is None for item in (row['install'], row['test'])):
            raise RuntimeError('Acceptance command evidence missing from persisted tool traces.')
        if baseline != '1' and (row['install']['exit'] != 0 or row['test']['exit'] != 0 or row['status'] != 'completed'):
            raise RuntimeError('Install, test or workflow failed; see recorded command output.')
        if baseline == '1' and baseline_error(row):
            raise RuntimeError(baseline_error(row))
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        row['error'] = str(error)
    finally:
        if provider == 'codex':
            row['newRollouts'] = sorted(dartclaw_rollouts() - before_rollouts)
            if row['newRollouts']:
                rollout_error = 'New DartClaw rollouts appeared in ~/.codex/sessions.'
                row['error'] = (row.get('error', '') + ' ' + rollout_error).strip()
        row['elapsedSeconds'] = round(time.time() - started)
        record_row(output, row)
    print(f"{provider}/{fixture}: {row.get('status', 'unavailable')}; install={row['install']['exit']}; test={row['test']['exit']}; Codex steps={row['completedCodexSteps']}")
    if row.get('error'):
        print('FAIL: ' + row['error'], file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
