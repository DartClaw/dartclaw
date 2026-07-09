@Tags(['component'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStepExecution;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        MessageService,
        MissingArtifactFailure,
        OutputConfig,
        OutputFormat,
        OutputMode,
        SessionService,
        WorkflowDefinitionParser;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show ContextExtractor, FileSystemOutput;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show executionEnvelopeMarkerKey, executionEnvelopeVersion;
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

  test('resolves an explicitly claimed existing path whose name does not match the output discovery glob', () async {
    // Regression: a `format: path` output's discovery glob is a selector for an
    // unnamed artifact in the worktree diff — not a filter on a path the skill
    // claimed explicitly. A committed PRD named `prd-brief.md` (absent from the
    // diff, filename not matching a narrow prd glob) must still resolve from the
    // explicit claim; the trust boundary is containment + existence, not the glob
    // (ADR-041).
    final worktree = harness.createWorktree('worktree-explicit-nonglob-prd');
    const prdPath = 'docs/specs/demo/prd-brief.md';
    harness.writeWorktreeFile(worktree, prdPath, '# PRD Brief\n');
    // Empty diff: a committed PRD is not listed by `git diff --name-only`.
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, const []));

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-explicit-nonglob-prd',
      {'prd': prdPath},
      prefix: 'PRD discovered.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('prd');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], prdPath);
  });

  test('captures the newest review report from the host step artifacts dir, ignoring the model claim', () async {
    const runId = 'run-step-capture';
    const stepId = 'plan-review-council';
    final reportPath = harness.writeStepReview(runId, stepId, 'council-20260706.md', content: '# Council Review\n');

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-step-capture',
      {
        // A bogus model-claimed path must be ignored — the host reads the dir.
        'review_report_path': '/totally/wrong/claimed-path.md',
        '$stepId.findings_count': 4,
        '$stepId.gating_findings_count': 2,
      },
      prefix: 'Council review complete.',
      workflowRunId: runId,
    );

    expect(outputs['review_report_path'], reportPath);
    expect(outputs['review_report_path'], isNot(contains('claimed-path')));
    expect(p.isAbsolute(outputs['review_report_path'] as String), isTrue);
    expect(outputs['$stepId.findings_count'], 4);
    expect(outputs['$stepId.gating_findings_count'], 2);
  });

  test('captures into the namespaced review path output key', () async {
    const runId = 'run-namespaced-capture';
    const stepId = 'plan-review-council';
    final reportPath = harness.writeStepReview(runId, stepId, 'council.md');

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(
        id: stepId,
        outputs: harness.reviewOutputs(stepId, pathKey: '$stepId.review_report_path'),
      ),
      'task-namespaced-capture',
      {'$stepId.findings_count': 6, '$stepId.gating_findings_count': 0},
      prefix: 'Council review complete.',
      workflowRunId: runId,
    );

    expect(outputs['$stepId.review_report_path'], reportPath);
    expect(outputs['$stepId.findings_count'], 6);
  });

  test('selects the newest .md when the step dir holds multiple reports', () async {
    const runId = 'run-multiple-reports';
    const stepId = 'integrated-review';
    final older = harness.writeStepReview(runId, stepId, 'older.md');
    final newer = harness.writeStepReview(runId, stepId, 'newer.md');
    File(older).setLastModifiedSync(DateTime(2026, 4, 1));
    File(newer).setLastModifiedSync(DateTime(2026, 4, 2));

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-multiple-reports',
      {'$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
      prefix: 'Review complete.',
      workflowRunId: runId,
    );

    expect(outputs['review_report_path'], newer);
  });

  test('ignores non-.md files an agent drops in the step dir', () async {
    const runId = 'run-ignore-nonmd';
    const stepId = 'integrated-review';
    harness.stepArtifactsDir(runId, stepId); // ensure the dir exists
    harness.writeStepReview(runId, stepId, 'notes.txt', content: 'scratch');
    final reportPath = harness.writeStepReview(runId, stepId, 'report.md');

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-ignore-nonmd',
      {'$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
      prefix: 'Review complete.',
      workflowRunId: runId,
    );

    expect(outputs['review_report_path'], reportPath);
  });

  test('materializes a clean-review stub in the step dir when the report is missing and findings are zero', () async {
    const runId = 'run-clean-stub';
    const stepId = 'integrated-review';
    final stepDir = harness.stepArtifactsDir(runId, stepId);

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-clean-stub',
      {'$stepId.findings_count': 0, '$stepId.gating_findings_count': 0},
      prefix: 'Review complete with no findings.',
      workflowRunId: runId,
    );
    final reportPath = outputs['review_report_path'] as String;

    expect(reportPath, startsWith(stepDir.path));
    expect(reportPath, endsWith('.md'));
    expect(File(reportPath).existsSync(), isTrue);
    expect(File(reportPath).readAsStringSync(), contains('did not leave a markdown report on disk'));
  });

  test('materializes the clean-review stub for custom findings output names too', () async {
    const runId = 'run-custom-clean-stub';
    const stepId = 'custom-review';
    final stepDir = harness.stepArtifactsDir(runId, stepId);

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(
        id: stepId,
        outputs: harness.reviewOutputs(stepId, pathKey: 'audit_report'),
      ),
      'task-custom-clean-stub',
      {'$stepId.findings_count': 0, '$stepId.gating_findings_count': 0},
      prefix: 'Custom review complete with no findings.',
      workflowRunId: runId,
    );
    final reportPath = outputs['audit_report'] as String;

    expect(reportPath, startsWith(stepDir.path));
    expect(File(reportPath).existsSync(), isTrue);
  });

  test('throws MissingArtifactFailure when the report is missing and findings are nonzero', () async {
    const runId = 'run-missing-nonzero';
    const stepId = 're-review';
    harness.stepArtifactsDir(runId, stepId); // empty step dir

    await expectLater(
      harness.extractStepFromContext(
        extractor,
        harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
        'task-missing-nonzero',
        {'$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
        prefix: 'Review found an issue but left no report.',
        workflowRunId: runId,
      ),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.fieldName, 'fieldName', 'review_report_path')
            .having((failure) => failure.reason, 'reason', 'no review artifact found in the step artifacts dir'),
      ),
    );
  });

  test('captures with an absolute value even when the data dir is relative', () async {
    final relativeDataDir = '.dartclaw-dev-test-${DateTime.now().microsecondsSinceEpoch}';
    try {
      const runId = 'run-relative-datadir';
      const stepId = 'integrated-review';
      final reportPath = p.normalize(
        p.absolute(harness.writeStepReview(runId, stepId, 'review.md', dataDir: relativeDataDir)),
      );
      final localExtractor = ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: relativeDataDir,
      );

      final outputs = await harness.extractStepFromContext(
        localExtractor,
        harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
        'task-relative-datadir',
        {'$stepId.findings_count': 2, '$stepId.gating_findings_count': 1},
        prefix: 'Review complete.',
        workflowRunId: runId,
      );

      expect(p.isRelative(relativeDataDir), isTrue);
      expect(outputs['review_report_path'], reportPath);
      expect(p.isAbsolute(outputs['review_report_path'] as String), isTrue);
    } finally {
      final dataDir = Directory(relativeDataDir);
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    }
  });

  test(
    'captures from the step dir in the nested-.dartclaw profile, ignoring a dirty worktree and stale claim',
    () async {
      // Maintainer profile: data dir nested inside the worktree. The host-owned
      // step dir is the only source — the dirty worktree and the model claim are
      // both irrelevant, so the nested case is trivially correct.
      const runId = 'run-nested-data';
      const stepId = 'plan-review-council';
      final worktree = harness.createWorktree('worktree-nested-data');
      final nestedDataDir = p.join(worktree.path, '.data');
      final reportPath = harness.writeStepReview(runId, stepId, 'council.md', dataDir: nestedDataDir);

      harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
      harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
      final localExtractor = harness.extractorWithGit(
        harness.gitWithUntracked(worktree, ['lib/a.dart', 'CHANGELOG.md']),
        dataDir: nestedDataDir,
      );

      final outputs = await harness.extractStepFromContext(
        localExtractor,
        harness.makeStep(
          id: stepId,
          outputs: harness.reviewOutputs(stepId, pathKey: '$stepId.review_report_path'),
        ),
        'task-nested-data-council',
        {
          '$stepId.review_report_path': 'CHANGELOG.md',
          '$stepId.findings_count': 38,
          '$stepId.gating_findings_count': 19,
        },
        prefix: 'Council review complete.',
        workflowRunId: runId,
        worktreePath: worktree.path,
      );

      expect(outputs['$stepId.review_report_path'], reportPath);
      expect(outputs['$stepId.gating_findings_count'], 19);
    },
  );

  test('per-map-iteration steps resolve their own disjoint step dir', () async {
    const runId = 'run-map-iteration';
    const stepId = 'story-review';
    // Iteration 2's report lives in `steps/story-review-2`; iteration 0's dir
    // holds a decoy that must not be captured.
    harness.writeStepReview(runId, stepId, 'iter0.md', content: '# iter 0\n', mapIterationIndex: 0);
    final iter2Report = harness.writeStepReview(runId, stepId, 'iter2.md', content: '# iter 2\n', mapIterationIndex: 2);

    final task = await harness.buildTaskWithContext(
      'task-map-iteration',
      {'$stepId.findings_count': 3, '$stepId.gating_findings_count': 1},
      prefix: 'Story review complete.',
      workflowRunId: runId,
    );
    // Seed the side-table row carrying the map iteration index the extractor reads.
    await harness.workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: task.id,
        agentExecutionId: 'ae-map-iteration',
        workflowRunId: runId,
        stepIndex: 0,
        stepId: stepId,
        mapIterationIndex: 2,
      ),
    );

    final outputs = await extractor.extract(harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)), task);

    expect(outputs['review_report_path'], iter2Report);
    expect(outputs['review_report_path'], isNot(contains('iter0')));
  });

  test('non-review path output with the same collision keeps the worktree copy (worktree-first default)', () async {
    // A non-review format:path key is not preserveRuntimeArtifactsRoot, so
    // the documented worktree-first order stands even in the nested profile.
    const runId = 'run-non-review-collision';
    final worktree = harness.createWorktree('worktree-non-review-collision');
    final nestedDataDir = p.join(worktree.path, '.data');
    const relativeClaim = 'artifacts/output.txt';
    // Runtime-artifacts copy under a consumer-created subdir.
    final runtimeArtifactsDir = p.join(nestedDataDir, 'workflows', 'runs', runId, 'runtime-artifacts');
    harness.writeFile(runtimeArtifactsDir, relativeClaim, 'runtime copy\n');
    harness.writeWorktreeFile(worktree, relativeClaim, 'worktree copy\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, [relativeClaim]),
      dataDir: nestedDataDir,
    );

    final outputs = await harness.extractStepFromContext(
      localExtractor,
      harness.pathOutputStep('artifact'),
      'task-non-review-collision',
      {'artifact': relativeClaim},
      prefix: 'Done.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['artifact'], relativeClaim);
  });

  test('custom-workflow claim under an absent non-engine subdir surfaces MissingArtifactFailure', () async {
    // TD-095: the engine pre-creates only reviews/ + merge-resolve/. A custom
    // step claiming a missing file under a subdir it never created (and that the
    // engine does not own) must fail clearly, not borrow an unrelated file. The
    // claim points into the runtime-artifacts `screenshots/` dir that no
    // consumer created, and the worktree has no changed file to substitute.
    const runId = 'run-missing-custom-subdir';
    final worktree = harness.createWorktree('worktree-missing-custom-subdir');
    // Engine-created reviews/ exists; screenshots/ never created.
    final runtimeArtifactsDir = harness.runtimeReviewsDir(runId).parent.path;
    final localExtractor = harness.extractorWithGit(harness.gitWithUntracked(worktree, const []));

    final task = await harness.buildTaskWithContext(
      'task-missing-custom-subdir',
      {'shot': p.join(runtimeArtifactsDir, 'screenshots', 'shot.png')},
      prefix: 'Captured screenshot.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('shot');

    await expectLater(localExtractor.extract(step, task), throwsA(isA<MissingArtifactFailure>()));
  });

  test('ignores symlinked non-review path claims that resolve outside the worktree', () async {
    final worktree = harness.createWorktree('worktree-symlink-report');
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
      'task-symlink-report-path',
      {'report': symlinkPath},
      prefix: 'Report generated.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('report');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['report'], actualPath);
  });

  test('filters unsafe diff-derived non-review path matches', () async {
    final worktree = harness.createWorktree('worktree-unsafe-diff-report');
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

    final taskWithWorktree = await harness.buildTask('task-unsafe-diff-report-path', worktreePath: worktree.path);
    final step = harness.pathOutputStep('report');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['report'], '');
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

  // TI09 parity: the canonical-basename tie-break is now declarative
  // (`preferPatterns:` on the filesystem output), not a hard-coded engine
  // preference on the `plan`/`prd` output key. With the declaration, resolution
  // is byte-identical to the old framework-basename behavior, including the
  // dirty-worktree multi-match case.
  test('preferPatterns picks plan.json when the diff also sees plan.md', () async {
    final worktree = harness.createWorktree('worktree-plan-json-preferred');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.json', '{"schemaVersion":"1","stories":[]}');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.md', '# Plan\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/specs/demo/plan.md', 'docs/specs/demo/plan.json']),
    );
    final taskWithWorktree = await harness.buildTask('task-plan-json-preferred', worktreePath: worktree.path);
    final step = harness.makeStep(
      outputs: const {
        'plan': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(
            pathPattern: '**/*',
            listMode: false,
            preferPatterns: ['plan.json', 'plan.md'],
          ),
        ),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['plan'], 'docs/specs/demo/plan.json');
  });

  test('preferPatterns picks canonical prd.md when the diff also sees dashed drafts', () async {
    final worktree = harness.createWorktree('worktree-prd-preferred');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/prd.md', '# PRD\n');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/draft-prd.md', '# Draft\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/specs/demo/draft-prd.md', 'docs/specs/demo/prd.md']),
    );
    final taskWithWorktree = await harness.buildTask('task-prd-preferred', worktreePath: worktree.path);
    final step = harness.makeStep(
      outputs: const {
        'prd': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/*', listMode: false, preferPatterns: ['prd.md']),
        ),
      },
    );

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], 'docs/specs/demo/prd.md');
  });

  test('without preferPatterns the engine applies no built-in plan/prd preference', () async {
    // Regression guard: the hard-coded prd.md/plan.json/plan.md basenames were
    // removed from the resolver, so a bare `plan` path output that sees both
    // plan.json and plan.md is now an ambiguity, not a silent plan.json pick.
    final worktree = harness.createWorktree('worktree-no-builtin-pref');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.json', '{"schemaVersion":"1","stories":[]}');
    harness.writeWorktreeFile(worktree, 'docs/specs/demo/plan.md', '# Plan\n');
    final localExtractor = harness.extractorWithGit(
      harness.gitWithUntracked(worktree, ['docs/specs/demo/plan.md', 'docs/specs/demo/plan.json']),
    );
    final taskWithWorktree = await harness.buildTask('task-no-builtin-pref', worktreePath: worktree.path);
    final step = harness.makeStep(outputs: const {'plan': OutputConfig(format: OutputFormat.path)});

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Multiple filesystem artifacts'))),
    );
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

  test('extracts parsed inline and narrative resolver aliases byte-identically', () async {
    const sharedText = 'Same extractor payload\nwith two lines';
    final session = await sessionService.getOrCreateMainSession();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Done.\n\n<workflow-context>${jsonEncode({'inline_summary': sharedText, 'narrative_summary': sharedText})}</workflow-context>',
    );
    final taskWithSession = await harness.buildTask('task-resolver-alias-inline-narrative', sessionId: session.id);
    final definition = WorkflowDefinitionParser().parse('''
name: resolver-alias-workflow
description: Checks resolver aliases at extraction time
steps:
  - id: extract
    name: Extract
    prompt: Extract
    outputs:
      inline_summary:
        format: text
        resolver: inline
      narrative_summary:
        format: text
        resolver: narrative
''');

    final outputs = await extractor.extract(definition.steps.single, taskWithSession);

    expect(outputs['inline_summary'], sharedText);
    expect(outputs['narrative_summary'], sharedText);
    expect(outputs['narrative_summary'], outputs['inline_summary']);
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
          'stories': OutputConfig(format: OutputFormat.json, schema: 'story_specs'),
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

  test('extracts diff.json artifact for canonical diff_summary key', () async {
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

  test('large content value (>10K chars) is returned without truncation', () async {
    final largeContent = 'x' * 15000;
    final task = await harness.createTaskWithArtifact(name: 'large.md', content: largeContent);

    final step = harness.makeStep(outputs: {'large_output': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    // Content should not be truncated – only a warning is logged.
    expect(outputs['large_output'], equals(largeContent));
  });

  test('dead diff/changes convention fallback does not read diff.json', () async {
    final task = await harness.createTaskWithArtifact(
      name: 'diff.json',
      kind: ArtifactKind.data,
      content: jsonEncode({'files': 1, 'additions': 5, 'deletions': 2}),
    );

    final step = harness.makeStep(outputs: {'notes': OutputConfig(), 'diff_changes': OutputConfig()});
    final outputs = await extractor.extract(step, task);
    expect(outputs['notes'], equals(''));
    expect(outputs['diff_changes'], equals(''));
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
                'severity': gatingCount == 0 ? 'low' : 'high',
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
            'summary': gatingCount == 0 ? 'Only LOW findings remain.' : 'A HIGH finding remains.',
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
      for (final testCase in const [(gatingCount: 0, severity: 'low'), (gatingCount: 0, severity: 'medium')]) {
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
            'summary': testCase.severity == 'low' ? 'Only LOW findings remain.' : 'A MEDIUM finding remains.',
          },
        };
        final taskId = 'task-${producer.stepId}-derived-${testCase.severity}';
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

  test('review producer outputs prefer explicit counters over structured verdict counts', () async {
    for (final producer in reviewSummaryProducers.where((producer) => producer.summaryKey != null)) {
      final payload = <String, Object?>{
        'findings_count': 0,
        'gating_findings_count': 0,
        producer.totalKey: 0,
        producer.gatingKey: 0,
        producer.summaryKey!: {
          'pass': false,
          'findings_count': 2,
          'findings': [
            {'severity': 'critical', 'location': 'lib/workflow.dart:1', 'description': 'Critical finding'},
            {'severity': 'low', 'location': 'lib/workflow.dart:2', 'description': 'Low finding'},
          ],
          'summary': 'A critical finding remains.',
        },
      };
      final task = await harness.buildTaskWithAssistantMessage(
        'task-${producer.stepId}-contradictory-counts',
        '<workflow-context>${jsonEncode(payload)}</workflow-context>',
      );
      final step = harness.makeStep(
        id: producer.stepId,
        outputs: harness.reviewCountOutputs(producer, includeSummary: true),
      );

      final outputs = await extractor.extract(step, task);

      expect(outputs[producer.totalKey], 0, reason: producer.name);
      expect(outputs[producer.gatingKey], 0, reason: producer.name);
    }
  });

  test('file-backed review producers do not substitute total count when gating count is missing', () async {
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
        final payload = <String, Object?>{
          'review_report_path': 'docs/specs/review.md',
          producer.totalKey: findingsCount,
        };
        final taskId = 'task-${producer.stepId}-file-backed-$findingsCount';
        final task = await harness.buildTaskWithAssistantMessage(
          taskId,
          '<workflow-context>${jsonEncode(payload)}</workflow-context>',
        );
        final step = harness.makeStep(id: producer.stepId, outputs: harness.reviewCountOutputs(producer));

        final outputs = await extractor.extract(step, task);

        expect(outputs[producer.totalKey], findingsCount, reason: producer.name);
        expect(outputs[producer.gatingKey], isNot(findingsCount), reason: producer.name);
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
        if (payload.containsKey('gating_findings_count')) {
          expect(outputs[producer.gatingKey], payload['gating_findings_count'], reason: producer.name);
        } else {
          expect(outputs[producer.gatingKey], isNot(payload['findings_count']), reason: producer.name);
        }
      }
    }
  });

  test('file-backed review producers keep unscoped gating alias independent from scoped total', () async {
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
    expect(outputs['plan-review.gating_findings_count'], 0);
  });

  test(
    'file-backed review producers keep already-extracted unscoped gating alias independent from scoped total',
    () async {
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
      expect(outputs['plan-review.gating_findings_count'], 0);
    },
  );

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
  });

  group('execution envelope outputs (TI03)', () {
    test('extracts declared outputs from the envelope outputs subobject first', () async {
      final task = await harness.buildTaskWithEnvelope('task-envelope-outputs', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final outputs = await extractor.extract(step, task);

      expect(outputs['summary'], 'X');
    });

    test('falls back to a legacy flat structured payload with no envelope marker', () async {
      final task = await harness.buildTaskWithEnvelope('task-legacy-flat', {'summary': 'Y'});
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final outputs = await extractor.extract(step, task);

      expect(outputs['summary'], 'Y');
    });

    test('does not crash on a malformed envelope whose outputs is missing or not a map', () async {
      final cases = <(String, Map<String, dynamic>)>[
        (
          'missing',
          {
            'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
            executionEnvelopeMarkerKey: executionEnvelopeVersion,
          },
        ),
        ('nonmap', {'outputs': 'not-a-map', executionEnvelopeMarkerKey: executionEnvelopeVersion}),
      ];
      for (final (label, envelope) in cases) {
        final task = await harness.buildTaskWithEnvelope('task-malformed-envelope-$label', envelope);
        final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

        final outputs = await extractor.extract(step, task);

        expect(outputs['summary'], '', reason: label);
      }
    });

    test('execution envelope outputs win over a legacy inline workflow-context block', () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Done.\n\n<workflow-context>{"summary":"inline"}</workflow-context>',
      );
      final task = await harness.buildTaskWithEnvelope('task-envelope-wins-over-inline', {
        'outputs': {'summary': 'envelope'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      }, sessionId: session.id);
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final outputs = await extractor.extract(step, task);

      expect(outputs['summary'], 'envelope');
    });

    test('a legacy flat structured payload keeps the historical inline-first ordering', () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Done.\n\n<workflow-context>{"summary":"inline"}</workflow-context>',
      );
      final task = await harness.buildTaskWithEnvelope('task-flat-inline-first', {
        'summary': 'flat',
      }, sessionId: session.id);
      final step = harness.makeStep(outputs: {'summary': const OutputConfig(format: OutputFormat.text)});

      final outputs = await extractor.extract(step, task);

      expect(outputs['summary'], 'inline');
    });
  });

  group('envelope-excluded *_source precedence', () {
    // On a finalizer step the envelope claims covered keys but never `*_source`
    // (host-owned). The excluded key falls through to the inline block, and the
    // `synthesized` floor only fills when it is still blank — so an inline
    // `spec_source: existing` must win over the default.
    final sourceOutputs = {
      'spec_source': const OutputConfig(format: OutputFormat.text, schema: 'narrative_text'),
      'summary': const OutputConfig(format: OutputFormat.text),
    };

    test('an inline-emitted spec_source wins over the synthesized default when the envelope omits it', () async {
      final session = await sessionService.getOrCreateMainSession();
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: 'Classified.\n\n<workflow-context>{"spec_source":"existing"}</workflow-context>',
      );
      final task = await harness.buildTaskWithEnvelope('task-source-inline-wins', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      }, sessionId: session.id);

      final outputs = await extractor.extract(harness.makeStep(outputs: sourceOutputs), task);

      expect(outputs['spec_source'], 'existing');
      expect(outputs['summary'], 'X');
    });

    test('an omitted spec_source still falls back to the synthesized default', () async {
      final task = await harness.buildTaskWithEnvelope('task-source-omitted-default', {
        'outputs': {'summary': 'X'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });

      final outputs = await extractor.extract(harness.makeStep(outputs: sourceOutputs), task);

      expect(outputs['spec_source'], 'synthesized');
      expect(outputs['summary'], 'X');
    });
  });

  group('finalizer filesystem (TI06)', () {
    test('captures a review report from the step dir, ignoring the envelope claim', () async {
      const runId = 'run-envelope-review';
      // pathOutputStep default step id is 'step1'; the report lives in its dir.
      final reportPath = harness.writeStepReview(runId, 'step1', 'integrated-review-codex-2026-04-30.md');
      final task = await harness.buildTaskWithEnvelope(
        'task-envelope-review-path',
        {
          // A wrong envelope claim must be ignored — the host reads the dir.
          'outputs': {'review_report_path': '/totally/wrong/claimed-path.md'},
          'step_outcome': {'outcome': 'succeeded', 'reason': 'clean'},
          executionEnvelopeMarkerKey: executionEnvelopeVersion,
        },
        projectId: 'workflow-test-todo-app',
        workflowRunId: runId,
      );
      final step = harness.pathOutputStep('review_report_path');

      final outputs = await extractor.extract(step, task);

      expect(outputs['review_report_path'], reportPath);
    });

    test('a missing required file claim fails even when the envelope claims succeeded', () async {
      final task = await harness.buildTaskWithEnvelope('task-envelope-missing-artifact', {
        'outputs': {'prd': 'docs/prd.md'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'wrote prd'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      });
      final step = harness.pathOutputStep('prd');

      await expectLater(
        extractor.extract(step, task),
        throwsA(
          isA<MissingArtifactFailure>()
              .having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/prd.md'])
              .having((failure) => failure.missingPaths, 'missingPaths', ['docs/prd.md']),
        ),
      );
    });

    test('a null envelope review-path claim still captures the step-dir report over a dirty worktree', () async {
      // The envelope declares path-claim keys required+nullable; a `null` value
      // means "no claim". The host reads the step dir regardless — a dirty
      // worktree is irrelevant to review-report capture.
      const runId = 'run-envelope-null-review-claim';
      const stepId = 'plan-review-council';
      final reportPath = harness.writeStepReview(
        runId,
        stepId,
        's09-mixed-review-council-20260607.md',
        content: '# Council Review\n\nVerdict: PASS.\n',
      );
      final worktree = harness.createWorktree('worktree-envelope-null-review');
      harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
      harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
      final localExtractor = ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
        workflowGitPort: harness.gitWithUntracked(worktree, ['lib/a.dart', 'CHANGELOG.md']),
        workflowStepExecutionRepository: harness.workflowStepExecutions,
      );
      final task = await harness.buildTaskWithEnvelope(
        'task-envelope-null-review-claim',
        {
          'outputs': {
            '$stepId.review_report_path': null,
            '$stepId.findings_count': 5,
            '$stepId.gating_findings_count': 4,
          },
          'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
          executionEnvelopeMarkerKey: executionEnvelopeVersion,
        },
        workflowRunId: runId,
        worktreePath: worktree.path,
      );
      final step = harness.makeStep(
        id: stepId,
        outputs: harness.reviewOutputs(stepId, pathKey: '$stepId.review_report_path'),
      );

      final outputs = await localExtractor.extract(step, task);

      expect(outputs['$stepId.review_report_path'], reportPath);
      expect(outputs['$stepId.review_report_path'], isNotEmpty);
    });

    test('a garbled envelope review-path claim is ignored in favor of the step-dir report', () async {
      // A garbled/nonexistent claimed path on a review output must never reach
      // the worktree diff — the host captures the report from the step dir.
      const runId = 'run-stale-review-claim';
      const stepId = 'review-story';
      final reportPath = harness.writeStepReview(
        runId,
        stepId,
        's10-review-story-20260704.md',
        content: '# Story Review\n\nVerdict: PASS.\n',
      );
      final worktree = harness.createWorktree('worktree-stale-review-claim');
      harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
      harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
      final localExtractor = ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
        workflowGitPort: harness.gitWithUntracked(worktree, ['lib/a.dart', 'CHANGELOG.md']),
        workflowStepExecutionRepository: harness.workflowStepExecutions,
      );
      final task = await harness.buildTaskWithEnvelope(
        'task-stale-review-claim',
        {
          'outputs': {
            '$stepId.review_report_path': '/var/folders/nonexistent/garbled/TODO',
            '$stepId.findings_count': 0,
            '$stepId.gating_findings_count': 0,
          },
          'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
          executionEnvelopeMarkerKey: executionEnvelopeVersion,
        },
        workflowRunId: runId,
        worktreePath: worktree.path,
      );
      final step = harness.makeStep(
        id: stepId,
        outputs: harness.reviewOutputs(stepId, pathKey: '$stepId.review_report_path'),
      );

      final outputs = await localExtractor.extract(step, task);

      expect(outputs['$stepId.review_report_path'], reportPath);
    });
  });
}
