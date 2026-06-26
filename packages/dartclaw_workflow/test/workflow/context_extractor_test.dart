@Tags(['component'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ExtractionConfig,
        ExtractionType,
        MessageService,
        MissingArtifactFailure,
        OutputConfig,
        OutputFormat,
        OutputMode,
        SessionService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show ContextExtractor;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'context_extractor_test_support.dart';

void main() {
  late ContextExtractorTestHarness harness;
  late Directory tempDir;
  late TaskService taskService;
  late MessageService messageService;
  late SessionService sessionService;
  late ContextExtractor extractor;

  setUp(() {
    harness = ContextExtractorTestHarness()..setUp();
    tempDir = harness.tempDir;
    taskService = harness.taskService;
    messageService = harness.messageService;
    sessionService = harness.sessionService;
    extractor = harness.extractor;
  });

  tearDown(() => harness.tearDown());

  test('returns empty map when step has no outputs', () async {
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {});
    final outputs = await extractor.extract(step, task);
    expect(outputs, isEmpty);
  });

  test('falls back to empty string with no artifacts or session', () async {
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['research_notes'], equals(''));
  });

  test('extracts first .md artifact content', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'output.md',
      content: '# Research Notes\nThis is the research output.',
    );

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['research_notes'], contains('Research Notes'));
  });

  test('extracts from workflow-context XML tag', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-session-1', {
      'research_notes': 'Found important findings about X.',
      'summary': 'Brief summary here.',
    }, prefix: 'Here is my response.');

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('Found important findings about X.'));
  });

  test('extracts structured JSON values from workflow-context XML tag', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-json-1', {
      'research_notes': 'JSON extracted value',
      'summary': 'JSON summary',
    });

    final step = harness.makeStep(outputs: {'research_notes': OutputConfig()});
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('JSON extracted value'));
  });

  test('defaults missing source outputs to synthesized', () async {
    final task = await harness.createTask();
    final step = harness.makeStep(outputs: {'plan_source': OutputConfig()});

    final outputs = await extractor.extract(step, task);

    expect(outputs['plan_source'], 'synthesized');
  });

  test('throws MissingArtifactFailure for missing path outputs', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-path-1', {'prd': 'docs/specs/demo/prd.md'});

    final step = harness.makeStep(outputs: const {'prd': OutputConfig(format: OutputFormat.path)});

    await expectLater(
      extractor.extract(step, taskWithSession),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/specs/demo/prd.md'])
            .having((failure) => failure.missingPaths, 'missingPaths', ['docs/specs/demo/prd.md'])
            .having((failure) => failure.reason, 'reason', 'path claimed but not present in worktree diff'),
      ),
    );
  });

  test('rejects flag-shaped relative path outputs that would inject into command args', () async {
    // ADR-041 format:path trust boundary: a resolved single-value relative path
    // output (e.g. spec_path) is interpolated straight into skill command args
    // (`--auto {{context.spec_path}}`), so a flag-shaped segment must be
    // rejected even though it resolves to a real, contained file. This restores
    // the argument-safety axis the removed AndThen spec validator enforced.
    final worktree = harness.createWorktree('worktree-flag-shaped-spec-path');
    const flagShaped = 'docs/specs/demo/-rf.md';
    harness.writeWorktreeFile(worktree, flagShaped, '# Spec\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [flagShaped]));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-flag-shaped-spec-path',
      {'spec_path': flagShaped},
      prefix: 'Spec discovered.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('spec_path');

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('flag-shaped path segments'))),
    );
  });

  test('keeps argument-safe relative path outputs that resolve in the worktree', () async {
    final worktree = harness.createWorktree('worktree-safe-spec-path');
    const safePath = 'docs/specs/demo/s01-foo.md';
    harness.writeWorktreeFile(worktree, safePath, '# Spec\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [safePath]));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-safe-spec-path',
      {'spec_path': safePath},
      prefix: 'Spec discovered.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('spec_path');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['spec_path'], safePath);
  });

  test('allows missing review report path when scoped review count is explicitly clean', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-clean-review-missing-path', {
      'review_findings': '/tmp/dartclaw/runtime-artifacts/reviews/re-review-clean.md',
      're-review.findings_count': 0,
      're-review.gating_findings_count': 0,
    }, prefix: 'Re-review completed with no findings.');
    final step = harness.makeStep(id: 're-review', outputs: harness.reviewOutputs('re-review'));

    final outputs = await extractor.extract(step, taskWithSession);

    expect(outputs['review_findings'], isEmpty);
    expect(outputs['re-review.findings_count'], 0);
    expect(outputs['re-review.gating_findings_count'], 0);
  });

  test('rejects missing review report path when scoped review count is nonzero', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-nonzero-review-missing-path', {
      'review_findings': '/tmp/dartclaw/runtime-artifacts/reviews/re-review-finding.md',
      're-review.findings_count': 1,
      're-review.gating_findings_count': 1,
    }, prefix: 'Re-review found an issue.');
    final step = harness.makeStep(id: 're-review', outputs: harness.reviewOutputs('re-review'));

    await expectLater(
      extractor.extract(step, taskWithSession),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.fieldName, 'fieldName', 'review_findings')
            .having((failure) => failure.reason, 'reason', 'path claimed but not present in worktree diff'),
      ),
    );
  });

  test('allows missing clean review report for workflow-defined findings output names', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-custom-clean-review-missing-path', {
      'audit_report': '/tmp/dartclaw/runtime-artifacts/reviews/custom-clean.md',
      'custom-review.findings_count': 0,
      'custom-review.gating_findings_count': 0,
    }, prefix: 'Custom review completed with no findings.');
    final step = harness.makeStep(
      id: 'custom-review',
      outputs: harness.reviewOutputs('custom-review', pathKey: 'audit_report'),
    );

    final outputs = await extractor.extract(step, taskWithSession);

    expect(outputs['audit_report'], isEmpty);
    expect(outputs['custom-review.findings_count'], 0);
    expect(outputs['custom-review.gating_findings_count'], 0);
  });

  test('uses changed architecture review report file when assistant claims a stale report path', () async {
    final worktree = harness.createWorktree('worktree-review-report');
    final actualPath = 'docs/specs/demo/plan-architecture-codex-2026-04-28.md';
    harness.writeWorktreeFile(worktree, actualPath, '# Architecture Review\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, [actualPath, 'docs/specs/demo/unrelated.md']),
    );
    final claimedPath = 'docs/specs/demo/plan-architecture-codex-codex-2026-04-28.md';
    final outputs = await harness.extractPathOutputFromContext(
      localExtractor,
      'architecture_review_findings',
      'task-review-report-path',
      {'architecture_review_findings': claimedPath, 'architecture-review.findings_count': 0},
      prefix: 'Architecture review completed.\n\nNo architecture findings of concern.',
      worktreePath: worktree.path,
    );

    expect(outputs['architecture_review_findings'], actualPath);
  });

  test('uses changed review findings file when assistant claims a stale report path', () async {
    final worktree = harness.createWorktree('worktree-plan-review-report');
    final actualPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    harness.writeWorktreeFile(worktree, actualPath, '# Plan Review\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, [actualPath, 'docs/specs/demo/architecture-notes.md']),
    );
    final claimedPath = 'docs/specs/demo/plan-review-codex-codex-2026-04-28.md';
    final outputs = await harness.extractPathOutputFromContext(
      localExtractor,
      'review_findings',
      'task-plan-review-report-path',
      {'review_findings': claimedPath, 'plan-review.findings_count': 0},
      prefix: 'Plan review completed.\n\nNo findings of concern.',
      worktreePath: worktree.path,
    );

    expect(outputs['review_findings'], actualPath);
  });

  test('normalizes absolute in-worktree review findings claims to relative paths', () async {
    final worktree = harness.createWorktree('worktree-absolute-review-report');
    const actualPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    harness.writeWorktreeFile(worktree, actualPath, '# Plan Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [actualPath]));
    final outputs = await harness.extractPathOutputFromContext(
      localExtractor,
      'review_findings',
      'task-absolute-plan-review-report-path',
      {'review_findings': p.join(worktree.path, actualPath)},
      prefix: 'Plan review completed.',
      worktreePath: worktree.path,
    );

    expect(outputs['review_findings'], actualPath);
  });

  test('normalizes project-basename-prefixed review findings claims to relative paths', () async {
    final projectRoot = Directory(p.join(tempDir.path, 'projects', 'workflow-test-todo-app'))
      ..createSync(recursive: true);
    const actualPath = 'docs/specs/demo/mixed-review-codex-2026-04-30.md';
    File(p.join(projectRoot.path, actualPath))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Mixed Review\n');

    final outputs = await harness.extractPathOutputFromContext(
      extractor,
      'review_findings',
      'task-project-basename-plan-review-report-path',
      {'review_findings': 'workflow-test-todo-app/$actualPath', 'plan-review.findings_count': 2},
      prefix: 'Review completed.',
      projectId: 'workflow-test-todo-app',
    );

    expect(outputs['review_findings'], actualPath);
  });

  test('normalizes project-prefixed claims inside workflow-owned worktrees', () async {
    final worktree = harness.createWorktree(p.join('worktrees', 'wf-run-map-0'));
    const actualPath = 'docs/reviews/mixed-review-codex-2026-04-30.md';
    harness.writeWorktreeFile(worktree, actualPath, '# Mixed Review\n');

    final outputs = await harness.extractPathOutputFromContext(
      extractor,
      'review_findings',
      'task-worktree-project-prefixed-plan-review-report-path',
      {'review_findings': 'workflow-test-todo-app/$actualPath'},
      prefix: 'Review completed.',
      projectId: 'workflow-test-todo-app',
      worktreePath: worktree.path,
    );

    expect(outputs['review_findings'], actualPath);
  });

  test('keeps absolute review findings under the workflow runtime artifacts dir readable', () async {
    final reportPath = harness.writeRuntimeReview('run-runtime', 'integrated-review-codex-2026-04-30.md');

    final outputs = await harness.extractPathOutputFromContext(
      extractor,
      'review_findings',
      'task-runtime-artifacts-review-report-path',
      {'review_findings': reportPath},
      prefix: 'Review completed.',
      projectId: 'workflow-test-todo-app',
      workflowRunId: 'run-runtime',
    );

    expect(outputs['review_findings'], reportPath);
  });

  test('materializes diagnostic clean review artifact when runtime report claim is missing', () async {
    final reportPath = harness.runtimeReviewPath('run-runtime-missing-clean', 'integrated-review-codex-2026-04-30.md');
    final claimedReportPath = reportPath.startsWith('/var/') ? '/private$reportPath' : reportPath;

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: 'integrated-review', outputs: harness.reviewOutputs('integrated-review')),
      'task-runtime-artifacts-missing-clean-review-report',
      {
        'review_findings': claimedReportPath,
        'integrated-review.findings_count': 0,
        'integrated-review.gating_findings_count': 0,
      },
      prefix: 'Review completed with no findings.',
      projectId: 'workflow-test-todo-app',
      workflowRunId: 'run-runtime-missing-clean',
    );

    expect(outputs['review_findings'], claimedReportPath);
    expect(File(claimedReportPath).existsSync(), isTrue);
    expect(File(claimedReportPath).readAsStringSync(), contains('did not leave a markdown report on disk'));
  });

  test('materializes diagnostic clean review artifact when report claim is omitted', () async {
    const runId = 'run-runtime-unclaimed-clean';
    final runtimeReviewsDir = harness.runtimeReviewsDir(runId);

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: 'integrated-review', outputs: harness.reviewOutputs('integrated-review')),
      'task-runtime-artifacts-unclaimed-clean-review-report',
      {'integrated-review.findings_count': 0, 'integrated-review.gating_findings_count': 0},
      prefix: 'Review completed with no findings.',
      projectId: 'workflow-test-todo-app',
      workflowRunId: runId,
    );
    final reportPath = outputs['review_findings'] as String;

    expect(reportPath, startsWith(runtimeReviewsDir.path));
    expect(reportPath, endsWith('.md'));
    expect(File(reportPath).existsSync(), isTrue);
    expect(File(reportPath).readAsStringSync(), contains('did not leave a markdown report on disk'));
  });

  test('honors an absolute review-report claim when the data dir is nested inside the worktree', () async {
    const runId = 'run-nested-data';
    final worktree = harness.createWorktree('worktree-nested-data');
    final nestedDataDir = p.join(worktree.path, '.data');
    final reportPath = harness.writeRuntimeReview(
      runId,
      '0.18-plan-mixed-review.md',
      content: '# Council Review\n\nVerdict: PASS.\n',
      dataDir: nestedDataDir,
    );

    harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
    harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['lib/a.dart', 'CHANGELOG.md']),
      dataDir: nestedDataDir,
    );

    final outputs = await harness.extractStepFromContext(
      localExtractor,
      harness.makeStep(
        id: 'plan-review-council',
        outputs: harness.reviewOutputs('plan-review-council', pathKey: 'plan-review-council.review_findings'),
      ),
      'task-nested-data-council',
      {
        'plan-review-council.review_findings': reportPath,
        'plan-review-council.findings_count': 38,
        'plan-review-council.gating_findings_count': 19,
      },
      prefix: 'Council review complete.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['plan-review-council.review_findings'], reportPath);
    expect(outputs['plan-review-council.gating_findings_count'], 19);
  });

  test('captures namespaced review path output from the bare claim key the skill emits', () async {
    const runId = 'run-namespaced-council-path';
    final reportPath = harness.writeRuntimeReview(
      runId,
      's09-mixed-review-council-20260607-195648.md',
      content: '# Council Review\n\nVerdict: PASS.\n',
    );

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(
        id: 'plan-review-council',
        outputs: harness.reviewOutputs('plan-review-council', pathKey: 'plan-review-council.review_findings'),
      ),
      'task-namespaced-council-path',
      {
        'review_findings': reportPath,
        'plan-review-council.findings_count': 6,
        'plan-review-council.gating_findings_count': 0,
      },
      prefix: 'Council review complete.',
      workflowRunId: runId,
    );

    expect(outputs['plan-review-council.review_findings'], reportPath);
    expect(outputs['plan-review-council.findings_count'], 6);
    expect(outputs['plan-review-council.gating_findings_count'], 0);
  });

  test('locates unclaimed review report in runtime-artifacts output dir instead of worktree diff', () async {
    const runId = 'run-unclaimed-council-review';
    final reportPath = harness.writeRuntimeReview(
      runId,
      's09-mixed-review-council-20260607.md',
      content: '# Council Review\n\nVerdict: PASS.\n',
    );

    final worktree = harness.createWorktree('worktree-unclaimed-council');
    harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
    harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, ['lib/a.dart', 'CHANGELOG.md']));

    final outputs = await harness.extractStepFromContext(
      localExtractor,
      harness.makeStep(id: 'plan-review-council', outputs: harness.reviewOutputs('plan-review-council')),
      'task-unclaimed-council-review',
      {'plan-review-council.findings_count': 5, 'plan-review-council.gating_findings_count': 4},
      prefix: 'Council review complete. Verdict: READY — PASS.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['review_findings'], reportPath);
    expect(outputs['review_findings'], isNot(contains('worktree-unclaimed-council')));
    expect(outputs['plan-review-council.findings_count'], 5);
    expect(outputs['plan-review-council.gating_findings_count'], 4);
  });

  test('does not materialize clean review artifact through runtime artifact symlink', () async {
    const runId = 'run-runtime-symlink';
    final runtimeArtifactsDir = Directory(p.join(tempDir.path, 'workflows', 'runs', runId, 'runtime-artifacts'))
      ..createSync(recursive: true);
    final outsideDir = Directory(p.join(tempDir.path, 'outside-reviews'))..createSync(recursive: true);
    final reviewsLink = Link(p.join(runtimeArtifactsDir.path, 'reviews'));
    try {
      reviewsLink.createSync(outsideDir.path);
    } on FileSystemException {
      markTestSkipped('Symlinks are not available on this filesystem');
    }

    final claimedReportPath = p.join(reviewsLink.path, 'integrated-review-codex-2026-04-30.md');

    final task = await harness.buildTaskWithContext(
      'task-runtime-artifacts-symlink-clean-review-report',
      {
        'review_findings': claimedReportPath,
        'integrated-review.findings_count': 0,
        'integrated-review.gating_findings_count': 0,
      },
      prefix: 'Review completed with no findings.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      projectId: 'workflow-test-todo-app',
      workflowRunId: runId,
    );
    final step = harness.makeStep(id: 'integrated-review', outputs: harness.reviewOutputs('integrated-review'));

    final outputs = await extractor.extract(step, task);

    expect(outputs['review_findings'], isEmpty);
    expect(File(claimedReportPath).existsSync(), isFalse);
    expect(File(p.join(outsideDir.path, p.basename(claimedReportPath))).existsSync(), isFalse);
  });

  test('keeps absolute review findings readable when data dir is relative', () async {
    final relativeDataDir = '.dartclaw-dev-test-${DateTime.now().microsecondsSinceEpoch}';
    try {
      const runId = 'run-runtime-relative-datadir';
      final reportPath = p.normalize(
        p.absolute(
          harness.writeRuntimeReview(runId, 'integrated-review-codex-2026-04-30.md', dataDir: relativeDataDir),
        ),
      );
      final localExtractor = ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: relativeDataDir,
      );

      final task = await harness.buildTaskWithContext(
        'task-runtime-artifacts-relative-datadir-review-report-path',
        {'review_findings': reportPath},
        prefix: 'Review completed.',
        suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
        projectId: 'workflow-test-todo-app',
        workflowRunId: runId,
      );
      final step = harness.pathOutputStep('review_findings');

      final outputs = await localExtractor.extract(step, task);

      expect(p.isRelative(relativeDataDir), isTrue);
      expect(p.basename(relativeDataDir), startsWith('.dartclaw-dev'));
      expect(outputs['review_findings'], reportPath);
    } finally {
      final dataDir = Directory(relativeDataDir);
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test('keeps runtime-root-relative review findings readable as absolute paths', () async {
    final reportPath = harness.writeRuntimeReview('run-runtime-relative', 'integrated-review-codex-2026-04-30.md');
    final worktree = harness.createWorktree('worktree-runtime-relative-review-report');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, const []));

    final task = await harness.buildTaskWithContext(
      'task-runtime-artifacts-relative-review-report-path',
      {'review_findings': 'reviews/integrated-review-codex-2026-04-30.md'},
      prefix: 'Review completed.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      projectId: 'workflow-test-todo-app',
      workflowRunId: 'run-runtime-relative',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, task);

    expect(outputs['review_findings'], reportPath);
  });

  test('prefers explicit runtime artifacts review findings over changed worktree review files', () async {
    final runtimeReportPath = harness.writeRuntimeReview(
      'run-runtime-precedence',
      'integrated-review-codex-2026-04-30.md',
    );
    final worktree = harness.createWorktree('worktree-runtime-precedence-review-report');
    const staleWorktreeReport = 'docs/specs/demo/plan-review-codex-2026-04-29.md';
    harness.writeWorktreeFile(worktree, staleWorktreeReport, '# Stale Worktree Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [staleWorktreeReport]));

    final task = await harness.buildTaskWithContext(
      'task-runtime-artifacts-review-report-precedence',
      {'review_findings': runtimeReportPath},
      prefix: 'Review completed.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      projectId: 'workflow-test-todo-app',
      workflowRunId: 'run-runtime-precedence',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, task);

    expect(outputs['review_findings'], runtimeReportPath);
  });

  test('ignores absolute outside-worktree review findings claims in favor of changed report files', () async {
    final worktree = harness.createWorktree('worktree-outside-review-report');
    final outsideDir = Directory(p.join(tempDir.path, 'outside-worktree'))..createSync();
    final outsideReport = File(p.join(outsideDir.path, 'plan-review-codex-2026-04-28.md'))
      ..writeAsStringSync('# Outside Review\n');
    const actualPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    harness.writeWorktreeFile(worktree, actualPath, '# Plan Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [actualPath]));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-outside-plan-review-report-path',
      {'review_findings': outsideReport.path},
      prefix: 'Plan review completed.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['review_findings'], actualPath);
  });

  test('prefers changed review findings files over stale existing claims', () async {
    final worktree = harness.createWorktree('worktree-stale-existing-review-report');
    const stalePath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    const actualPath = 'docs/specs/demo/plan-review-codex-2026-04-29.md';
    harness.writeWorktreeFile(worktree, stalePath, '# Stale Plan Review\n');
    harness.writeWorktreeFile(worktree, actualPath, '# Plan Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [actualPath]));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-stale-existing-plan-review-report-path',
      {'review_findings': stalePath},
      prefix: 'Plan review completed.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['review_findings'], actualPath);
  });

  test('ignores symlinked review findings claims that resolve outside the worktree', () async {
    final worktree = harness.createWorktree('worktree-symlink-review-report');
    final outsideDir = Directory(p.join(tempDir.path, 'outside-symlink-target'))..createSync();
    final outsideReport = File(p.join(outsideDir.path, 'plan-review-codex-2026-04-28.md'))
      ..writeAsStringSync('# Outside Review\n');
    const symlinkPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    const actualPath = 'docs/specs/demo/plan-review-codex-2026-04-29.md';
    Link(p.join(worktree.path, symlinkPath))
      ..parent.createSync(recursive: true)
      ..createSync(outsideReport.path);
    harness.writeWorktreeFile(worktree, actualPath, '# Plan Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [actualPath]));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-symlink-plan-review-report-path',
      {'review_findings': symlinkPath},
      prefix: 'Plan review completed.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['review_findings'], actualPath);
  });

  test('filters unsafe diff-derived review findings paths', () async {
    final worktree = harness.createWorktree('worktree-unsafe-diff-review-report');
    final outsideDir = Directory(p.join(tempDir.path, 'outside-diff-target'))..createSync();
    final outsideReport = File(p.join(outsideDir.path, 'plan-review-codex-2026-04-28.md'))
      ..writeAsStringSync('# Outside Review\n');
    const symlinkPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    Link(p.join(worktree.path, symlinkPath))
      ..parent.createSync(recursive: true)
      ..createSync(outsideReport.path);
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, [symlinkPath, outsideReport.path]),
    );

    final taskWithWorktree = await harness.buildTask(
      'task-unsafe-diff-plan-review-report-path',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['review_findings'], '');
  });

  test('does not validate diff-derived review paths against project root fallback', () async {
    final worktree = harness.createWorktree('worktree-project-root-fallback');
    final projectRoot = Directory(p.join(tempDir.path, 'projects', 'demo-project'))..createSync(recursive: true);
    const reportPath = 'docs/specs/demo/plan-review-codex-2026-04-28.md';
    File(p.join(projectRoot.path, reportPath))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Project Root Review\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, [reportPath]));

    final taskWithWorktree = await harness.buildTask(
      'task-diff-project-root-fallback',
      projectId: 'demo-project',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('review_findings');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['review_findings'], '');
  });

  test('resolves list path outputs from workflow git diff', () async {
    final worktree = harness.createWorktree('worktree');
    harness.writeWorktreeFile(worktree, 'fis/s01-foo.md', '# Foo\n');
    harness.writeWorktreeFile(worktree, 'fis/s02-bar.md', '# Bar\n');
    final git = harness.gitWithUntracked(worktree, ['fis/s01-foo.md', 'fis/s02-bar.md', 'docs/unrelated.md']);
    final localExtractor = harness.extractorWithGit(git);
    final taskWithWorktree = await harness.buildTaskWithContext('task-fis-paths', {
      'fis_paths': ['fis/s01-foo.md', 'fis/s02-bar.md'],
    }, worktreePath: worktree.path);

    final step = harness.makeStep(outputs: const {'fis_paths': OutputConfig(format: OutputFormat.lines)});

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
    expect(git.events, contains('diff --name-only'));
  });

  test('rejects phantom path claims against workflow git diff', () async {
    final worktree = harness.createWorktree('worktree-phantom');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, const []));
    final taskWithWorktree = await harness.buildTaskWithContext('task-phantom-path', {
      'prd': 'docs/prd.md',
    }, worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/prd.md'])
            .having((failure) => failure.missingPaths, 'missingPaths', ['docs/prd.md'])
            .having((failure) => failure.worktreePath, 'worktreePath', worktree.path)
            .having((failure) => failure.fieldName, 'fieldName', 'prd')
            .having((failure) => failure.reason, 'reason', 'path claimed but not present in worktree diff'),
      ),
    );
  });

  test('accepts claimed existing path outputs even when they are unchanged in the worktree diff', () async {
    final worktree = harness.createWorktree('worktree-existing-claim');
    harness.writeWorktreeFile(worktree, 'docs/prd.md', '# Existing PRD\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, const []));
    final taskWithWorktree = await harness.buildTaskWithContext('task-existing-path', {
      'prd': 'docs/prd.md',
    }, worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], 'docs/prd.md');
  });

  test('prefers an explicitly claimed path over unrelated diff matches for singular outputs', () async {
    final worktree = harness.createWorktree('worktree-explicit-singular');
    harness.writeWorktreeFile(worktree, 'docs/prd.md', '# Existing PRD\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, ['other/prd.md']));
    final taskWithWorktree = await harness.buildTaskWithContext('task-explicit-singular', {
      'prd': 'docs/prd.md',
    }, worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], 'docs/prd.md');
  });

  test('preserves unchanged claimed files in list outputs alongside changed ones', () async {
    final worktree = harness.createWorktree('worktree-explicit-list');
    harness.writeWorktreeFile(worktree, 'fis/s01-foo.md', '# Existing Foo\n');
    harness.writeWorktreeFile(worktree, 'fis/s02-bar.md', '# Bar\n');
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, ['fis/s02-bar.md']));
    final taskWithWorktree = await harness.buildTaskWithContext('task-explicit-list', {
      'fis_paths': ['fis/s01-foo.md', 'fis/s02-bar.md'],
    }, worktreePath: worktree.path);

    final step = harness.makeStep(outputs: const {'fis_paths': OutputConfig(format: OutputFormat.lines)});

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
  });

  test('throws StateError when singular filesystem output has multiple matches', () async {
    final worktree = harness.createWorktree('worktree-ambiguous');
    harness.writeWorktreeFile(worktree, 'docs/a/prd.md', '# A\n');
    harness.writeWorktreeFile(worktree, 'docs/b/prd.md', '# B\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/a/prd.md', 'docs/b/prd.md']),
    );
    final taskWithWorktree = await harness.buildTask('task-ambiguous-path', worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Multiple filesystem artifacts'))),
    );
  });

  test('prefers plan.json when the default plan resolver also sees plan.md', () async {
    final worktree = harness.createWorktree('worktree-plan-json-preferred');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.json', '{"schemaVersion":"1","stories":[]}');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.md', '# Plan\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/specs/demo/plan.md', 'docs/specs/demo/plan.json']),
    );
    final taskWithWorktree = await harness.buildTask('task-plan-json-preferred', worktreePath: worktree.path);
    final step = harness.makeStep(outputs: const {'plan': OutputConfig(format: OutputFormat.path)});

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['plan'], 'docs/specs/demo/plan.json');
  });

  test('prefers canonical prd.md when the default PRD resolver also sees dashed drafts', () async {
    final worktree = harness.createWorktree('worktree-prd-preferred');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/prd.md', '# PRD\n');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/draft-prd.md', '# Draft\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/specs/demo/draft-prd.md', 'docs/specs/demo/prd.md']),
    );
    final taskWithWorktree = await harness.buildTask('task-prd-preferred', worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], 'docs/specs/demo/prd.md');
  });

  test('uses inline values for narrative-only outputs', () async {
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: 'Done.\n\n<workflow-context>{"summary":"Inline summary","confidence":8}</workflow-context>',
    );
    final taskWithSession = await harness.buildTask('task-narrative-inline', sessionId: session.id);
    final fallbackCalls = <String>[];
    final localExtractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      structuredOutputFallbackRecorder:
          (_, {required stepId, required outputKey, required failureReason, String? providerSubtype}) {
            fallbackCalls.add(outputKey);
          },
    );
    final step = harness.makeStep(
      outputs: const {
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithSession);

    expect(outputs['summary'], 'Inline summary');
    expect(outputs['confidence'], 8);
    expect(fallbackCalls, isEmpty);
  });

  test('resolves mixed filesystem and inline narrative outputs', () async {
    final worktree = Directory(p.join(tempDir.path, 'worktree-mixed'))..createSync();
    File(p.join(worktree.path, 'fis', 's01-foo.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Foo\n');
    File(p.join(worktree.path, 'fis', 's02-bar.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Bar\n');
    final git = FakeGitGateway()
      ..initWorktree(worktree.path)
      ..addUntracked(worktree.path, 'fis/s01-foo.md')
      ..addUntracked(worktree.path, 'fis/s02-bar.md');
    final localExtractor = harness.extractorWithGit(git);
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Done.\n\n<workflow-context>${jsonEncode({
            'fis_paths': ['fis/s02-bar.md', 'fis/s01-foo.md'],
            'summary': 'Inline summary',
            'confidence': 9,
          })}</workflow-context>',
    );
    final taskWithWorktree = await harness.buildTask(
      'task-mixed-output',
      sessionId: session.id,
      worktreePath: worktree.path,
    );
    final step = harness.makeStep(
      outputs: const {
        'fis_paths': OutputConfig(format: OutputFormat.lines),
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
    expect(outputs['summary'], 'Inline summary');
    expect(outputs['confidence'], 9);
  });

  test(
    'uses the most recent assistant message containing workflow-context, not only the last assistant message',
    () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Done.\n\n<workflow-context>{"prd":"PRD text","stories":{"items":[{"id":"S01"}]}}</workflow-context>',
      );
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '{"stories":{"items":[{"id":"S01"}]}}',
      );

      final taskWithSession = await harness.buildTask('task-workflow-context-history', sessionId: session.id);

      final step = harness.makeStep(
        outputs: const {
          'prd': OutputConfig(format: OutputFormat.text),
          'stories': OutputConfig(format: OutputFormat.json, schema: 'story_plan'),
        },
      );
      final outputs = await extractor.extract(step, taskWithSession);

      expect(outputs['prd'], equals('PRD text'));
      expect(outputs['stories'], isA<Map<Object?, Object?>>());
      expect(((outputs['stories'] as Map<Object?, Object?>)['items'] as List<Object?>), hasLength(1));
    },
  );

  test('format-aware json output stores parsed list from last assistant message', () async {
    final taskWithSession = await harness.buildTaskWithAssistantMessage(
      'task-json-list-1',
      '[{"id":"s01"},{"id":"s02"}]',
    );

    final step = harness.makeStep(outputs: {'result': const OutputConfig(format: OutputFormat.json)});

    final outputs = await extractor.extract(step, taskWithSession);
    final result = outputs['result'] as List<Object?>;

    expect(result, hasLength(2));
    expect((result.first as Map<String, dynamic>)['id'], equals('s01'));
    expect((result.last as Map<String, dynamic>)['id'], equals('s02'));
  });

  test('format-aware lines output stores trimmed non-empty lines', () async {
    final taskWithSession = await harness.buildTaskWithAssistantMessage('task-lines-1', 'alpha\n  beta  \n\n gamma ');

    final step = harness.makeStep(outputs: {'result': const OutputConfig(format: OutputFormat.lines)});

    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['result'], equals(['alpha', 'beta', 'gamma']));
  });

  test('schema preset warnings stay soft for format-aware json extraction', () async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final sub = Logger('ContextExtractor').onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await sub.cancel();
    });

    final taskWithSession = await harness.buildTaskWithAssistantMessage('task-schema-1', '{"summary":"Only summary"}');

    final step = harness.makeStep(
      outputs: {'result': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
    );

    final outputs = await extractor.extract(step, taskWithSession);
    final result = outputs['result'] as Map<String, dynamic>;

    expect(result['summary'], equals('Only summary'));
    expect(
      records.any(
        (record) =>
            record.level == Level.WARNING &&
            record.message.contains('Schema validation for "result"') &&
            record.message.contains('"pass"'),
      ),
      isTrue,
    );
  });

  test('extracts diff.json artifact for diff-related key', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'diff.json',
      kind: ArtifactKind.data,
      content: jsonEncode({'files': 3, 'additions': 45, 'deletions': 12}),
    );

    final step = harness.makeStep(outputs: {'diff_summary': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['diff_summary'], contains('3 files changed'));
    expect(outputs['diff_summary'], contains('+45'));
    expect(outputs['diff_summary'], contains('-12'));
  });

  test('ExtractionConfig with artifact type finds named artifact', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'special-report.md',
      content: 'Special report content here.',
    );

    final step = harness.makeStep(
      outputs: {'report': OutputConfig()},
      extraction: const ExtractionConfig(type: ExtractionType.artifact, pattern: 'special-report'),
    );
    final outputs = await extractor.extract(step, task);
    expect(outputs['report'], equals('Special report content here.'));
  });

  test('large content value (>10K chars) is returned without truncation', () async {
    final largeContent = 'x' * 15000;
    final task = await harness.createTaskWithArtifact(name: 'large.md', content: largeContent);

    final step = harness.makeStep(outputs: {'large_output': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    // Content should not be truncated – only a warning is logged.
    expect(outputs['large_output'], equals(largeContent));
  });

  test('multiple output keys: diff key extracts diff.json, plain key falls back to empty', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'diff.json',
      kind: ArtifactKind.data,
      content: jsonEncode({'files': 1, 'additions': 5, 'deletions': 2}),
    );

    final step = harness.makeStep(outputs: {'notes': OutputConfig(), 'diff_changes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['notes'], equals(''));
    expect(outputs['diff_changes'], contains('1 files changed'));
  });

  test('structured output mode reads provider payload from task config', () async {
    final task = await harness.buildTaskWithStructuredOutput(
      'task-structured-config',
      '{"verdict":{"pass":true,"findings_count":0,"findings":[],"summary":"Clean"}}',
    );

    final step = harness.makeStep(
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await extractor.extract(step, task);

    expect(outputs['verdict'], isA<Map<Object?, Object?>>());
    expect((outputs['verdict'] as Map<Object?, Object?>)['pass'], isTrue);
  });

  test('structured output mode rejects provider payload that violates schema', () async {
    final task = await harness.buildTaskWithStructuredOutput('task-structured-invalid', '{"count":-1}');

    final step = harness.makeStep(
      outputs: const {
        'count': OutputConfig(
          format: OutputFormat.json,
          outputMode: OutputMode.structured,
          schema: 'non_negative_integer',
        ),
      },
    );

    await expectLater(
      extractor.extract(step, task),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('failed schema validation'))),
    );
  });

  test('inline payload wins for narrative fields before structured fallback payload', () async {
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: 'Done.\n\n<workflow-context>{"summary":"Inline summary"}</workflow-context>',
    );
    final task = await harness.buildTaskWithStructuredOutput(
      'task-narrative-precedence',
      '{"summary":"Structured summary","confidence":7}',
      sessionId: session.id,
    );
    final step = harness.makeStep(
      outputs: const {
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await extractor.extract(step, task);

    expect(outputs['summary'], 'Inline summary');
    expect(outputs['confidence'], 7);
  });

  test('structured output mode records fallback and uses heuristic json when payload is missing', () async {
    final task = await harness.buildTaskWithAssistantMessage(
      'task-structured-fallback',
      '{"verdict":{"pass":true,"findings_count":0,"findings":[],"summary":"Clean"}}',
    );

    final fallbackCalls = <Map<String, Object?>>[];
    final localExtractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      structuredOutputFallbackRecorder:
          (taskId, {required stepId, required outputKey, required failureReason, String? providerSubtype}) {
            fallbackCalls.add({
              'taskId': taskId,
              'stepId': stepId,
              'outputKey': outputKey,
              'failureReason': failureReason,
              'providerSubtype': providerSubtype,
            });
          },
    );

    final step = harness.makeStep(
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await localExtractor.extract(step, task);

    expect(outputs['verdict'], isA<Map<Object?, Object?>>());
    expect((outputs['verdict'] as Map<Object?, Object?>)['pass'], isTrue);
    expect(fallbackCalls, [
      {
        'taskId': 'task-structured-fallback',
        'stepId': 'step1',
        'outputKey': 'verdict',
        'failureReason': 'missing_payload',
        'providerSubtype': null,
      },
    ]);
  });

  test('derived outputs reuse fields from an earlier parsed JSON output', () async {
    final task = await harness.buildTaskWithAssistantMessage(
      'task-session-json',
      jsonEncode({
        'pass': false,
        'findings_count': 2,
        'findings': [
          {'severity': 'high', 'location': 'lib/a.dart:10', 'description': 'Issue A'},
          {'severity': 'low', 'location': 'lib/b.dart:12', 'description': 'Issue B'},
        ],
        'summary': 'Two findings remain.',
      }),
    );

    final step = harness.makeStep(
      outputs: const {
        'review_summary': OutputConfig(format: OutputFormat.json, schema: 'verdict'),
        'findings_count': OutputConfig(format: OutputFormat.text),
      },
    );

    final outputs = await extractor.extract(step, task);
    expect(outputs['review_summary'], isA<Map<String, dynamic>>());
    expect((outputs['review_summary'] as Map<String, dynamic>)['findings_count'], 2);
    expect(outputs['findings_count'], 2);
  });

  test('review producer outputs preserve distinct total and gating findings counts', () async {
    for (final producer in reviewSummaryProducers) {
      for (final gatingCount in const [0, 1]) {
        final payload = <String, Object?>{'findings_count': 3, producer.totalKey: 3, producer.gatingKey: gatingCount};
        final summaryKey = producer.summaryKey;
        if (summaryKey != null) {
          payload[summaryKey] = {
            'pass': gatingCount == 0,
            'findings_count': 3,
            'findings': [
              {
                'severity': gatingCount == 0 ? 'low' : 'medium',
                'location': 'lib/workflow.dart:1',
                'description': 'Representative review finding',
              },
            ],
            'summary': gatingCount == 0 ? 'Only LOW findings remain.' : 'A MEDIUM finding remains.',
          };
        }
        final taskId = 'task-${producer.stepId}-$gatingCount';
        final task = await harness.buildTaskWithAssistantMessage(
          taskId,
          '<workflow-context>${jsonEncode(payload)}</workflow-context>',
        );
        final step = harness.makeStep(
          id: producer.stepId,
          outputs: harness.reviewCountOutputs(producer, includeSummary: true),
        );

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], 3, reason: producer.name);
        expect(outputs[producer.gatingKey], gatingCount, reason: producer.name);
      }
    }
  });

  test('review producer outputs derive scoped counts from verdict findings when scoped keys are missing', () async {
    for (final producer in reviewSummaryProducers.where((producer) => producer.summaryKey != null)) {
      for (final testCase in const [(gatingCount: 0, severity: 'low'), (gatingCount: 1, severity: 'medium')]) {
        final payload = <String, Object?>{
          producer.summaryKey!: {
            'pass': testCase.gatingCount == 0,
            'findings_count': 3,
            'findings': [
              {
                'severity': testCase.severity,
                'location': 'lib/workflow.dart:1',
                'description': 'Representative review finding',
              },
              {'severity': 'low', 'location': 'lib/workflow.dart:2', 'description': 'Low severity review finding'},
              {
                'severity': 'low',
                'location': 'lib/workflow.dart:3',
                'description': 'Another low severity review finding',
              },
            ],
            'summary': testCase.gatingCount == 0 ? 'Only LOW findings remain.' : 'A MEDIUM finding remains.',
          },
        };
        final taskId = 'task-${producer.stepId}-derived-${testCase.gatingCount}';
        final task = await harness.buildTaskWithAssistantMessage(
          taskId,
          '<workflow-context>${jsonEncode(payload)}</workflow-context>',
        );
        final step = harness.makeStep(
          id: producer.stepId,
          outputs: harness.reviewCountOutputs(producer, includeSummary: true),
        );

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], 3, reason: producer.name);
        expect(outputs[producer.gatingKey], testCase.gatingCount, reason: producer.name);
      }
    }
  });

  test('file-backed review producers fall back to total count when gating count is missing', () async {
    const producers = <ReviewProducer>[
      (
        name: 'dartclaw-review',
        stepId: 'plan-review',
        summaryKey: null,
        totalKey: 'plan-review.findings_count',
        gatingKey: 'plan-review.gating_findings_count',
      ),
      (
        name: 'dartclaw-architecture',
        stepId: 'architecture-review',
        summaryKey: null,
        totalKey: 'architecture-review.findings_count',
        gatingKey: 'architecture-review.gating_findings_count',
      ),
    ];

    for (final producer in producers) {
      for (final findingsCount in const [0, 2]) {
        final payload = <String, Object?>{'review_findings': 'docs/specs/review.md', producer.totalKey: findingsCount};
        final taskId = 'task-${producer.stepId}-file-backed-$findingsCount';
        final task = await harness.buildTaskWithAssistantMessage(
          taskId,
          '<workflow-context>${jsonEncode(payload)}</workflow-context>',
        );
        final step = harness.makeStep(id: producer.stepId, outputs: harness.reviewCountOutputs(producer));

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], findingsCount, reason: producer.name);
        expect(outputs[producer.gatingKey], findingsCount, reason: producer.name);
      }
    }
  });

  test('file-backed review producers accept unscoped count fallbacks', () async {
    const producers = <ReviewProducer>[
      (
        name: 'dartclaw-review',
        stepId: 'plan-review',
        summaryKey: null,
        totalKey: 'plan-review.findings_count',
        gatingKey: 'plan-review.gating_findings_count',
      ),
      (
        name: 'dartclaw-architecture',
        stepId: 'architecture-review',
        summaryKey: null,
        totalKey: 'architecture-review.findings_count',
        gatingKey: 'architecture-review.gating_findings_count',
      ),
    ];

    for (final producer in producers) {
      for (final payload in const [
        {'findings_count': 3, 'gating_findings_count': 1},
        {'findings_count': 2},
      ]) {
        final taskId = 'task-${producer.stepId}-unscoped-${payload.length}';
        final task = await harness.buildTaskWithAssistantMessage(
          taskId,
          '<workflow-context>${jsonEncode(payload)}</workflow-context>',
        );
        final step = harness.makeStep(id: producer.stepId, outputs: harness.reviewCountOutputs(producer));

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], payload['findings_count'], reason: producer.name);
        expect(
          outputs[producer.gatingKey],
          payload['gating_findings_count'] ?? payload['findings_count'],
          reason: producer.name,
        );
      }
    }
  });

  test('file-backed review producers prefer scoped total over unscoped gating fallback', () async {
    final payload = <String, Object?>{'plan-review.findings_count': 2, 'gating_findings_count': 0};
    final task = await harness.buildTaskWithAssistantMessage(
      'task-plan-review-scoped-total-wins',
      '<workflow-context>${jsonEncode(payload)}</workflow-context>',
    );
    final step = harness.makeStep(
      id: 'plan-review',
      outputs: const {
        'plan-review.findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'plan-review.gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await extractor.extract(step, task);

    expect(outputs['plan-review.findings_count'], 2);
    expect(outputs['plan-review.gating_findings_count'], 2);
  });

  test('file-backed review producers prefer scoped total over already-extracted unscoped gating fallback', () async {
    final payload = <String, Object?>{'plan-review.findings_count': 2, 'gating_findings_count': 0};
    final task = await harness.buildTaskWithAssistantMessage(
      'task-plan-review-extracted-unscoped-gating',
      '<workflow-context>${jsonEncode(payload)}</workflow-context>',
    );
    final step = harness.makeStep(
      id: 'plan-review',
      outputs: const {
        'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'plan-review.findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'plan-review.gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    );

    final outputs = await extractor.extract(step, task);

    expect(outputs['gating_findings_count'], 0);
    expect(outputs['plan-review.findings_count'], 2);
    expect(outputs['plan-review.gating_findings_count'], 2);
  });

  group('worktree source outputs', () {
    for (final testCase in const [
      (
        name: 'branch extracts branch from task.worktreeJson',
        id: 'task-wt1',
        outputKey: 'branch',
        source: 'worktree.branch',
        branch: 'feat/fix-bug-123',
        path: '/worktrees/fix-bug-123',
        expected: 'feat/fix-bug-123',
      ),
      (
        name: 'path extracts path from task.worktreeJson',
        id: 'task-wt2',
        outputKey: 'worktree_path',
        source: 'worktree.path',
        branch: 'feat/fix-bug',
        path: '/opt/worktrees/fix-bug',
        expected: '/opt/worktrees/fix-bug',
      ),
      (
        name: 'branch returns empty string when task has no worktreeJson',
        id: 'task-wt3',
        outputKey: 'branch',
        source: 'worktree.branch',
        branch: null,
        path: null,
        expected: '',
      ),
    ]) {
      test('source: worktree.${testCase.name}', () async {
        final task = await harness.buildTaskWithWorktreeSource(
          testCase.id,
          branch: testCase.branch,
          path: testCase.path,
        );
        final outputs = await extractor.extract(harness.worktreeSourceStep(testCase.outputKey, testCase.source), task);
        expect(outputs[testCase.outputKey], equals(testCase.expected));
      });
    }
  });

  group('setValue', () {
    for (final testCase in const [
      (name: 'explicit null literal overrides extraction', value: null, withArtifact: true),
      (name: 'non-null literal', value: 'literal', withArtifact: false),
    ]) {
      test('writes ${testCase.name} to context', () async {
        final task = testCase.withArtifact
            ? await harness.createTaskWithArtifact(
                name: 'output.md',
                content: 'extracted content',
                artifactId: 'art-setvalue-null',
              )
            : await harness.createTask();
        final outputs = await extractor.extract(
          harness.makeStep(outputs: {'k': OutputConfig(setValue: testCase.value)}),
          task,
        );
        expect(outputs.containsKey('k'), isTrue);
        expect(outputs['k'], testCase.value);
      });
    }

    test('without setValue the key extracts normally', () async {
      final task = await harness.createTaskWithArtifact(
        name: 'output.md',
        content: 'extracted content',
        artifactId: 'art-no-setvalue',
      );

      final step = harness.makeStep(outputs: {'k': OutputConfig()});
      final outputs = await extractor.extract(step, task);
      expect(outputs['k'], 'extracted content');
    });

    test('setValue wins over extraction at first-key position', () async {
      // Reproduces the precedence guard against the legacy ExtractionConfig
      // priority branch in extract() – without the guard, extraction would
      // silently beat setValue for the first output key only.
      final task = await harness.createTaskWithArtifact(
        name: 'special-report.md',
        content: 'Special report content here.',
        artifactId: 'art-precedence',
      );

      final step = harness.makeStep(
        extraction: const ExtractionConfig(type: ExtractionType.artifact, pattern: 'special-report'),
        outputs: const {'k': OutputConfig(setValue: 'wins')},
      );

      final outputs = await extractor.extract(step, task);
      expect(outputs['k'], 'wins');
    });
  });
}
