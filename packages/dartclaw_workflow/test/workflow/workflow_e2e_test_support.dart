import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowRunStatus;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

typedef WorkflowE2eProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

const fixtureSeedRegressionMessage =
    'Fixture upstream regressed; re-seed BUG-001..003 in DartClaw/workflow-test-todo-app docs/PRODUCT-BACKLOG.md';

const _todoAppFixtureReadOnlyUrl = 'https://github.com/DartClaw/workflow-test-todo-app.git';

const bugFileAllowlist = <String, List<String>>{
  'BUG-001': ['src/app/routes/todos.py', 'src/app/templates/partials/todo_deleted_oob.html'],
  'BUG-002': ['src/app/routes/todos.py', 'src/app/templates/app.html'],
  'BUG-003': ['src/app/routes/todos.py', 'src/app/templates/partials/todo_list_content.html'],
};

String e2eLogLevelFromEnv(Map<String, String> environment) {
  final levelName = (environment['DARTCLAW_E2E_LOG_LEVEL'] ?? 'INFO').trim();
  return levelName.isEmpty ? 'INFO' : levelName;
}

bool e2eRequireCompletedFromEnv(Map<String, String> environment) {
  final value = environment['DARTCLAW_E2E_REQUIRE_COMPLETED']?.trim().toLowerCase();
  return value == 'true' || value == '1' || value == 'yes';
}

Future<WorkflowE2ePrerequisiteResult> evaluateWorkflowE2ePrerequisites({
  required Map<String, String> environment,
  required WorkflowE2eProcessRunner runProcess,
}) async {
  final codex = await _runOk(runProcess, 'codex', ['--version']);
  if (!codex) {
    return const WorkflowE2ePrerequisiteResult.skip(
      'Codex is not available; install Codex, ensure it is on PATH, and authenticate or set CODEX_API_KEY.',
    );
  }

  final canCreateGitHubPr = await canCreateGitHubPrForEnv(environment: environment, runProcess: runProcess);
  if (canCreateGitHubPr) {
    return WorkflowE2ePrerequisiteResult.run(canCreateGitHubPr: true);
  }

  final canCloneFixture = await _canReadFixtureRepo(runProcess);
  if (!canCloneFixture) {
    return const WorkflowE2ePrerequisiteResult.skip(
      'Public HTTPS access to the workflow-test-todo-app fixture repo is required for branch-only workflow e2e; '
      'check network access or set GITHUB_TOKEN for authenticated HTTPS clone.',
    );
  }

  return WorkflowE2ePrerequisiteResult.run(canCreateGitHubPr: false);
}

Future<bool> canCreateGitHubPrForEnv({
  required Map<String, String> environment,
  required WorkflowE2eProcessRunner runProcess,
}) async {
  if (_hasGitHubTokenEnv(environment)) {
    return true;
  }
  final canCreatePr = await _runOk(runProcess, 'gh', ['auth', 'status']);
  return canCreatePr && await _runGitHubSshAuthenticated(runProcess);
}

void expectWorkflowFinalStatus({
  required WorkflowRunStatus finalStatus,
  required bool requireCompleted,
  required String runId,
  Logger? logger,
}) {
  if (requireCompleted) {
    expect(
      finalStatus,
      WorkflowRunStatus.completed,
      reason: 'completed was required; paused is not acceptable in strict mode for workflow $runId',
    );
    return;
  }

  expect(
    finalStatus,
    anyOf(WorkflowRunStatus.completed, WorkflowRunStatus.paused),
    reason: 'workflow should complete or pause (loop exhausted)',
  );
  if (finalStatus == WorkflowRunStatus.paused) {
    (logger ?? Logger('E2E')).warning(
      'Workflow $runId ended in $finalStatus - soft-paused (loop exhausted) accepted; '
      'export DARTCLAW_E2E_REQUIRE_COMPLETED=true to require completed.',
    );
  }
}

void expectStepOrderSubsequence(Iterable<String> actualSteps, List<String> expectedSteps) {
  final actual = actualSteps.toList(growable: false);
  var expectedIdx = 0;
  for (var i = 0; i < actual.length && expectedIdx < expectedSteps.length; i++) {
    if (actual[i] == expectedSteps[expectedIdx]) {
      expectedIdx++;
    }
  }
  if (expectedIdx < expectedSteps.length) {
    fail(
      'Step ordering mismatch: expected steps ${expectedSteps.sublist(expectedIdx)} '
      'were not found in order.\nActual step order: $actual',
    );
  }
}

void expectStepOrderStrict(Iterable<String> actualSteps, List<String> expectedSteps) {
  final actual = actualSteps.toList(growable: false);
  expectStepOrderSubsequence(actual, expectedSteps);

  var searchStart = 0;
  for (var expectedIndex = 0; expectedIndex < expectedSteps.length - 1; expectedIndex++) {
    final current = expectedSteps[expectedIndex];
    final next = expectedSteps[expectedIndex + 1];
    final currentIndex = actual.indexOf(current, searchStart);
    final nextIndex = actual.indexOf(next, currentIndex + 1);
    final gap = actual.sublist(currentIndex + 1, nextIndex);
    final unexpected = gap.where((step) => !expectedSteps.contains(step)).toList(growable: false);
    if (unexpected.isNotEmpty) {
      fail(
        'Unexpected step(s) $unexpected appeared between "$current" and "$next".\n'
        'Expected strict sequence: $expectedSteps\nActual step order: $actual',
      );
    }
    searchStart = nextIndex;
  }
}

void expectStepInputsContainProjectIndex(List<Map<String, dynamic>> inputsByOccurrence, String stepKey) {
  if (inputsByOccurrence.isEmpty) {
    fail('No inputs recorded for step "$stepKey".');
  }
  for (final inputs in inputsByOccurrence) {
    final projectIndex = inputs['project_index'];
    if (projectIndex is! Map || projectIndex.isEmpty) {
      fail('Step "$stepKey" inputs["project_index"] should be a non-empty Map.');
    }
    final keys = projectIndex.keys.map((key) => '$key').toSet();
    final missing = const {'framework', 'state_protocol'}.difference(keys);
    if (missing.isNotEmpty) {
      fail('Step "$stepKey" project_index is missing key(s): ${missing.join(', ')}');
    }
  }
}

void expectStepInputContainsAll(List<String> descriptions, String stepKey, List<String> expectedSubstrings) {
  if (descriptions.isEmpty) {
    fail('No descriptions recorded for step "$stepKey".');
  }
  for (final expected in expectedSubstrings) {
    if (!descriptions.any((description) => description.contains(expected))) {
      final previews = descriptions.map((d) => d.length > 300 ? '${d.substring(0, 300)}...' : d).toList();
      fail('Step "$stepKey" description does not contain "$expected".\nPreviews: $previews');
    }
  }
}

void expectPreservedArtifactsHaveNonZeroTokenKeys(Directory artifactDir, {required List<String> agentSteps}) {
  final files = artifactDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
  expect(files, isNotEmpty, reason: 'No preserved artifacts found under ${artifactDir.path}');

  final tokenKeys = const ['_workflowInputTokensNew', '_workflowCacheReadTokens', '_workflowOutputTokens'];
  final agentStepSet = agentSteps.toSet();
  final inspected = <String>[];
  final missing = <String>[];

  for (final file in files) {
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final stepKey = payload['stepKey'] as String? ?? '';
    if (!agentStepSet.contains(stepKey)) continue;
    final configJson = (payload['configJson'] as Map?)?.cast<String, dynamic>() ?? const {};
    final values = {for (final key in tokenKeys) key: configJson[key]};
    inspected.add('${p.basename(file.path)} -> $values');
    final hasNonZero = tokenKeys.any((key) {
      final value = configJson[key];
      return value is num && value > 0;
    });
    if (!hasNonZero) {
      missing.add('$stepKey (${p.basename(file.path)})');
    }
  }

  expect(
    inspected,
    isNotEmpty,
    reason: 'Expected at least one preserved artifact for steps $agentSteps; inspected: $inspected',
  );
  expect(
    missing,
    isEmpty,
    reason:
        'Expected every preserved artifact under ${artifactDir.path} for agent steps $agentSteps '
        'to have at least one non-zero _workflow*Tokens* key.\nMissing: $missing\nInspected: $inspected',
  );
}

void assertKnownDefectsBacklogEntries(String targetDir) {
  final backlog = File(p.join(targetDir, 'docs', 'PRODUCT-BACKLOG.md'));
  if (!backlog.existsSync()) {
    fail(fixtureSeedRegressionMessage);
  }
  final text = backlog.readAsStringSync();
  final missing = const ['BUG-001', 'BUG-002', 'BUG-003'].where((id) => !text.contains(id)).toList();
  if (missing.isNotEmpty) {
    fail(fixtureSeedRegressionMessage);
  }
}

void expectDistinctWorktreePaths(List<String> paths) {
  expect(
    paths.toSet().length,
    paths.length,
    reason: 'per-story worktrees should be distinct paths; got duplicates: $paths',
  );
}

Future<void> assertDiffTouchesExpectedFiles({
  required String projectDir,
  required String headRef,
  required String publishedBranch,
  required Map<String, List<String>> bugAllowlist,
  required List<String> activeBugs,
  WorkflowE2eProcessRunner runProcess = Process.run,
}) async {
  final result = await runProcess('git', [
    'diff',
    '--name-only',
    '$headRef..$publishedBranch',
  ], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    fail('git diff failed for $headRef..$publishedBranch: ${result.stderr}');
  }
  final touched = (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  assertTouchedFilesMatchAllowlist(
    touched: touched,
    publishedBranch: publishedBranch,
    bugAllowlist: bugAllowlist,
    activeBugs: activeBugs,
  );
}

Future<void> closePrByBranch({
  required String branch,
  required String repo,
  String? projectDir,
  WorkflowE2eProcessRunner runProcess = Process.run,
  Logger? logger,
}) async {
  if (branch.isEmpty) return;
  final ghResult = await runProcess('gh', ['pr', 'close', branch, '--repo', repo, '--delete-branch']);
  if (ghResult.exitCode == 0 || projectDir == null) return;

  final gitResult = await runProcess(
    'git',
    ['push', 'origin', '--delete', branch],
    workingDirectory: projectDir,
    environment: const {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
    },
  );
  if (gitResult.exitCode == 0) return;

  (logger ?? Logger('E2E.Cleanup')).warning(
    'Cleanup failed for branch $branch: '
    'gh pr close stderr=${ghResult.stderr}; '
    'git push --delete stderr=${gitResult.stderr}',
  );
}

void assertTouchedFilesMatchAllowlist({
  required List<String> touched,
  required String publishedBranch,
  required Map<String, List<String>> bugAllowlist,
  required List<String> activeBugs,
}) {
  if (touched.isEmpty) {
    fail('Published branch "$publishedBranch" has an empty diff against HEAD.');
  }
  for (final bug in activeBugs) {
    final allowed = bugAllowlist[bug] ?? const <String>[];
    final matches = touched.any((file) => allowed.any(file.contains));
    if (!matches) {
      fail(
        'Diff for "$publishedBranch" touched none of the allow-list paths for $bug.\nAllow-list: $allowed\nTouched: $touched',
      );
    }
  }
}

Map<String, dynamic> forcedReviewRemediationOutputs({
  required String stepId,
  required Map<String, dynamic> outputs,
  required Set<String> targetReviews,
  required String remediationPlan,
  required String implementationSummary,
}) {
  final reviewConfig = switch (stepId) {
    'plan-review' when targetReviews.contains('plan-review') => (
      findings: 'review_findings',
      count: 'findings_count',
      scopedCount: 'plan-review.findings_count',
      scopedGatingCount: 'plan-review.gating_findings_count',
    ),
    'architecture-review' when targetReviews.contains('architecture-review') => (
      findings: 'architecture_review_findings',
      count: 'findings_count',
      scopedCount: 'architecture-review.findings_count',
      scopedGatingCount: 'architecture-review.gating_findings_count',
    ),
    _ => null,
  };
  if (reviewConfig == null) return outputs;

  final findingsValue = outputs[reviewConfig.count];
  final findingsCount = switch (findingsValue) {
    final int numeric => numeric,
    _ => int.tryParse('$findingsValue') ?? 0,
  };
  if (findingsCount > 0) return outputs;

  return {
    ...outputs,
    'implementation_summary': (outputs['implementation_summary'] as String?)?.trim().isNotEmpty == true
        ? outputs['implementation_summary']
        : implementationSummary,
    'remediation_plan': remediationPlan,
    reviewConfig.count: 1,
    reviewConfig.scopedCount: 1,
    reviewConfig.scopedGatingCount: 1,
  };
}

Future<bool> _runOk(WorkflowE2eProcessRunner runProcess, String executable, List<String> arguments) async {
  try {
    final result = await runProcess(executable, arguments);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _canReadFixtureRepo(WorkflowE2eProcessRunner runProcess) async {
  try {
    final result = await runProcess(
      'git',
      ['ls-remote', '--exit-code', _todoAppFixtureReadOnlyUrl, 'HEAD'],
      environment: const {'GIT_TERMINAL_PROMPT': '0'},
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _runGitHubSshAuthenticated(WorkflowE2eProcessRunner runProcess) async {
  try {
    final result = await runProcess('ssh', [
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=10',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-T',
      'git@github.com',
    ]);
    final output = '${result.stdout}\n${result.stderr}';
    return output.contains("You've successfully authenticated");
  } catch (_) {
    return false;
  }
}

bool _hasGitHubTokenEnv(Map<String, String> environment) {
  final token = environment['GITHUB_TOKEN']?.trim();
  return token != null && token.isNotEmpty;
}

final class WorkflowE2ePrerequisiteResult {
  final String? skipReason;
  final bool canCreateGitHubPr;

  const WorkflowE2ePrerequisiteResult.run({required this.canCreateGitHubPr}) : skipReason = null;

  const WorkflowE2ePrerequisiteResult.skip(this.skipReason) : canCreateGitHubPr = false;

  bool get shouldSkip => skipReason != null;
}
