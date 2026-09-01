@Tags(['component'])
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, FileSystemOutput, MessageService, MissingArtifactFailure, OutputConfig, OutputFormat;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show executionEnvelopeMarkerKey, executionEnvelopeVersion;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'context_extractor_test_support.dart';

/// `format: path` output resolution: the explicit claim, the host-owned step
/// artifacts dir behind it, and the failures that surface when neither answers.
void main() {
  late ContextExtractorTestHarness harness;
  late Directory tempDir;
  late TaskService taskService;
  late MessageService messageService;
  late ContextExtractor extractor;

  setUp(() {
    harness = ContextExtractorTestHarness()..setUp();
    tempDir = harness.tempDir;
    taskService = harness.taskService;
    messageService = harness.messageService;
    extractor = harness.extractor;
  });

  tearDown(() => harness.tearDown());

  test('throws MissingArtifactFailure for missing path outputs', () async {
    final taskWithSession = await harness.buildTaskWithContext('task-path-1', {'prd': 'docs/specs/demo/prd.md'});

    final step = harness.makeStep(outputs: const {'prd': OutputConfig(format: OutputFormat.path)});

    await expectLater(
      extractor.extract(step, taskWithSession),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.claimedPaths, 'claimedPaths', ['docs/specs/demo/prd.md'])
            .having((failure) => failure.missingPaths, 'missingPaths', ['docs/specs/demo/prd.md'])
            .having((failure) => failure.reason, 'reason', 'path claimed but not found under an allowed root'),
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
    final localExtractor = harness.extractorFor();

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
    final localExtractor = harness.extractorFor();

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
    // Regression: a `format: path` output's discovery glob selects an unclaimed
    // artifact out of the step artifacts dir — it is never a filter on a path the
    // skill claimed explicitly. A committed PRD named `prd-brief.md` (filename not
    // matching a narrow prd glob, and no longer gated on any worktree diff) must
    // still resolve from the explicit claim; the trust boundary is containment +
    // existence, not the glob (ADR-041).
    final worktree = harness.createWorktree('worktree-explicit-nonglob-prd');
    const prdPath = 'docs/specs/demo/prd-brief.md';
    harness.writeWorktreeFile(worktree, prdPath, '# PRD Brief\n');
    final localExtractor = harness.extractorFor();

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

  test('the shipped review preset excludes a non-markdown file an agent drops in the step dir', () async {
    // TI04: the engine has no built-in `.md` filter — the `review_report_path`
    // preset's own declared `**/*.md` is what excludes the scratch file, even
    // though it is the newer of the two. `pathOutputStep` declares that preset,
    // exactly as every shipped review step does.
    const runId = 'run-ignore-nonmd';
    const stepId = 'integrated-review';
    harness.stepArtifactsDir(runId, stepId); // ensure the dir exists
    final reportPath = harness.writeStepReview(runId, stepId, 'report.md');
    final scratch = harness.writeStepReview(runId, stepId, 'raw-findings.json', content: '{}');
    File(reportPath).setLastModifiedSync(DateTime(2026, 4, 1));
    File(scratch).setLastModifiedSync(DateTime(2026, 4, 2));

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

  test('a symlink an agent plants in its own step dir is not captured', () async {
    // The step artifacts dir is host-created but agent-writable, and a captured
    // value reaches context absolute (exempt from the downstream argument-safety
    // check). Following a link here would hand the next step an arbitrary host
    // path, so links are not candidates at all.
    const runId = 'run-step-dir-symlink';
    const stepId = 'integrated-review';
    final stepDir = harness.stepArtifactsDir(runId, stepId);
    final outsideDir = Directory(p.join(tempDir.path, 'outside-step-dir'))..createSync();
    final outsideReport = File(p.join(outsideDir.path, 'secret.md'))..writeAsStringSync('# Outside\n');
    Link(p.join(stepDir.path, 'report.md')).createSync(outsideReport.path);

    await expectLater(
      harness.extractStepFromContext(
        extractor,
        harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
        'task-step-dir-symlink',
        {'$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
        prefix: 'Review complete.',
        workflowRunId: runId,
      ),
      throwsA(isA<MissingArtifactFailure>()),
    );
  });

  test('a step artifact whose name is not argument-safe is not captured', () async {
    // The captured value is absolute, so `_assertArgumentSafeFileSystemOutput`
    // exempts it; the filename is agent-authored, so the check moves to capture
    // time. A flag-shaped, whitespace-bearing name would otherwise be
    // interpolated verbatim into the next step's command line.
    const runId = 'run-unsafe-artifact-name';
    const stepId = 'integrated-review';
    harness.stepArtifactsDir(runId, stepId);
    final safe = harness.writeStepReview(runId, stepId, 'report.md');
    final unsafe = harness.writeStepReview(runId, stepId, 'my report --dangerous.md', content: '# Unsafe\n');
    File(safe).setLastModifiedSync(DateTime(2026, 4, 1));
    File(unsafe).setLastModifiedSync(DateTime(2026, 4, 2));

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-unsafe-artifact-name',
      {'$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
      prefix: 'Review complete.',
      workflowRunId: runId,
    );

    expect(outputs['review_report_path'], safe);
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
            .having((failure) => failure.reason, 'reason', 'no artifact found in the step artifacts dir'),
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

  test('captures from the step dir in the nested-.dartclaw profile, over an unresolvable claim', () async {
    // Maintainer profile: data dir nested inside the worktree. A claim that
    // names no existing file falls through to the host-owned step dir, which
    // sits inside the worktree here — the nested case must still resolve to the
    // report and not to some other worktree file.
    const runId = 'run-nested-data';
    const stepId = 'plan-review-council';
    final worktree = harness.createWorktree('worktree-nested-data');
    final nestedDataDir = p.join(worktree.path, '.data');
    final reportPath = harness.writeStepReview(runId, stepId, 'council.md', dataDir: nestedDataDir);

    harness.writeWorktreeFile(worktree, 'lib/a.dart', '// a\n');
    harness.writeWorktreeFile(worktree, 'CHANGELOG.md', '# changelog\n');
    final localExtractor = harness.extractorFor(dataDir: nestedDataDir);

    final outputs = await harness.extractStepFromContext(
      localExtractor,
      harness.makeStep(
        id: stepId,
        outputs: harness.reviewOutputs(stepId, pathKey: '$stepId.review_report_path'),
      ),
      'task-nested-data-council',
      {
        '$stepId.review_report_path': 'reports/never-written.md',
        '$stepId.findings_count': 38,
        '$stepId.gating_findings_count': 19,
      },
      prefix: 'Council review complete.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['$stepId.review_report_path'], reportPath);
    expect(outputs['$stepId.gating_findings_count'], 19);
  });

  test('a review claim naming an existing worktree file wins over the host-captured report', () async {
    // OC01, and the behaviour change the CHANGELOG flags: the host no longer
    // ignores a review's own path. A claim that exists and is contained is used
    // as written, even when the step dir holds a report the host captured.
    const runId = 'run-review-claim-wins';
    const stepId = 'integrated-review';
    harness.writeStepReview(runId, stepId, 'captured.md', content: '# Captured\n');
    final worktree = harness.createWorktree('worktree-review-claim-wins');
    const claimed = 'docs/specs/demo/review.md';
    harness.writeWorktreeFile(worktree, claimed, '# Claimed review\n');

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-review-claim-wins',
      {'review_report_path': claimed, '$stepId.findings_count': 2, '$stepId.gating_findings_count': 1},
      prefix: 'Review complete.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['review_report_path'], claimed);
  });

  test('a relative claim colliding between the step dir and the worktree resolves to the step-dir copy', () async {
    // TD-093 tie-break, now a consequence of root ordering rather than a
    // name-keyed special case: the host-owned step artifacts dir is the first
    // containment root, so a relative claim that exists in both places resolves
    // to the copy the host controls — as an absolute path.
    const runId = 'run-root-order-collision';
    const stepId = 'integrated-review';
    const claim = 'report.md';
    final stepCopy = harness.writeStepReview(runId, stepId, claim, content: '# Step-dir copy\n');
    final worktree = harness.createWorktree('worktree-root-order-collision');
    harness.writeWorktreeFile(worktree, claim, '# Worktree copy\n');

    final outputs = await harness.extractStepFromContext(
      extractor,
      harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)),
      'task-root-order-collision',
      {'review_report_path': claim, '$stepId.findings_count': 1, '$stepId.gating_findings_count': 1},
      prefix: 'Review complete.',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );

    expect(outputs['review_report_path'], stepCopy);
    expect(p.isAbsolute(outputs['review_report_path'] as String), isTrue);
  });

  test('per-map-iteration steps resolve their own disjoint step dir', () async {
    const runId = 'run-map-iteration';
    const stepId = 'story-review';
    // Iteration 2's report lives in `steps/story-review-2`; iteration 0's dir
    // holds a decoy that must not be captured.
    harness.writeStepReview(runId, stepId, 'iter0.md', content: '# iter 0\n', mapIterationIndex: 0);
    final iter2Report = harness.writeStepReview(runId, stepId, 'iter2.md', content: '# iter 2\n', mapIterationIndex: 2);

    final task = await harness.buildTask('task-map-iteration', workflowRunId: runId);
    // Seed the side-table row carrying the map iteration index the extractor
    // reads, alongside the envelope the finalizer would have written.
    await harness.agentExecutions.create(AgentExecution(id: 'ae-map-iteration'));
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
    await harness.seedEnvelopeOutputs(task.id, {
      '$stepId.findings_count': 3,
      '$stepId.gating_findings_count': 1,
    }, workflowRunId: runId);

    final outputs = await extractor.extract(harness.makeStep(id: stepId, outputs: harness.reviewOutputs(stepId)), task);

    expect(outputs['review_report_path'], iter2Report);
    expect(outputs['review_report_path'], isNot(contains('iter0')));
  });

  test('a claim colliding between the worktree and runtime-artifacts keeps the worktree copy', () async {
    // Root order below the step artifacts dir is unchanged: worktree before
    // runtime-artifacts. With no step dir in play the collision resolves to the
    // worktree copy, root-relative, in the nested profile too.
    const runId = 'run-non-review-collision';
    final worktree = harness.createWorktree('worktree-non-review-collision');
    final nestedDataDir = p.join(worktree.path, '.data');
    const relativeClaim = 'artifacts/output.txt';
    // Runtime-artifacts copy under a consumer-created subdir.
    final runtimeArtifactsDir = p.join(nestedDataDir, 'workflows', 'runs', runId, 'runtime-artifacts');
    harness.writeFile(runtimeArtifactsDir, relativeClaim, 'runtime copy\n');
    harness.writeWorktreeFile(worktree, relativeClaim, 'worktree copy\n');
    final localExtractor = harness.extractorFor(dataDir: nestedDataDir);

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
    final localExtractor = harness.extractorFor();

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

  test('refuses a path claim that symlinks outside the worktree, substituting no sibling file', () async {
    // The symlink-resolved containment check is the only thing between a model
    // string and a host path. A claim escaping the worktree is refused and the
    // step fails naming the claim — the sibling report present in the worktree
    // is never returned in its place.
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
    // The shipped configuration: a workflow run whose step artifacts dir exists
    // and is empty (S05), so the refusal is reached through the same path a real
    // step takes rather than by having no step dir at all.
    const runId = 'run-symlink-escape';
    harness.stepArtifactsDir(runId, 'step1');
    final localExtractor = harness.extractorFor();

    final taskWithWorktree = await harness.buildTaskWithContext(
      'task-symlink-report-path',
      {'report': symlinkPath},
      prefix: 'Report generated.',
      suffix: '\n<step-outcome>{"status":"passed"}</step-outcome>',
      workflowRunId: runId,
      worktreePath: worktree.path,
    );
    final step = harness.pathOutputStep('report');

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.claimedPaths, 'claimedPaths', [symlinkPath])
            .having((failure) => failure.missingPaths, 'missingPaths', [symlinkPath])
            .having((failure) => failure.fieldName, 'fieldName', 'report'),
      ),
    );
  });

  test('resolves list path outputs from explicit claims', () async {
    final worktree = harness.createWorktree('worktree');
    harness.writeWorktreeFile(worktree, 'fis/s01-foo.md', '# Foo\n');
    harness.writeWorktreeFile(worktree, 'fis/s02-bar.md', '# Bar\n');
    final localExtractor = harness.extractorFor();
    final taskWithWorktree = await harness.buildTaskWithContext('task-fis-paths', {
      'fis_paths': ['fis/s01-foo.md', 'fis/s02-bar.md'],
    }, worktreePath: worktree.path);

    final step = harness.makeStep(outputs: const {'fis_paths': OutputConfig(format: OutputFormat.lines)});

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
  });

  test('rejects phantom path claims', () async {
    final worktree = harness.createWorktree('worktree-phantom');
    final localExtractor = harness.extractorFor();
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
            .having((failure) => failure.reason, 'reason', 'path claimed but not found under an allowed root'),
      ),
    );
  });

  test('accepts a claimed existing path output whatever the worktree state', () async {
    final worktree = harness.createWorktree('worktree-existing-claim');
    harness.writeWorktreeFile(worktree, 'docs/prd.md', '# Existing PRD\n');
    final localExtractor = harness.extractorFor();
    final taskWithWorktree = await harness.buildTaskWithContext('task-existing-path', {
      'prd': 'docs/prd.md',
    }, worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['prd'], 'docs/prd.md');
  });

  test('a claim whose leading segment repeats the worktree name is taken literally', () async {
    // The prefix-stripping repair is gone: a claim resolves to the path it
    // names, or fails naming that path — never to a same-named file one
    // directory up.
    final worktree = harness.createWorktree('myproj');
    harness.writeWorktreeFile(worktree, 'myproj/report.md', '# Nested\n');
    harness.writeWorktreeFile(worktree, 'report.md', '# Top level\n');
    harness.writeWorktreeFile(worktree, 'x.md', '# Only at top level\n');
    final localExtractor = harness.extractorFor();

    final claimedNested = await harness.buildTaskWithContext('task-prefix-literal', {
      'report': 'myproj/report.md',
    }, worktreePath: worktree.path);

    expect(
      (await localExtractor.extract(harness.pathOutputStep('report'), claimedNested))['report'],
      'myproj/report.md',
    );

    final claimedMissing = await harness.buildTaskWithContext('task-prefix-no-repair', {
      'report': 'myproj/x.md',
    }, worktreePath: worktree.path);

    await expectLater(
      localExtractor.extract(harness.pathOutputStep('report'), claimedMissing),
      throwsA(
        isA<MissingArtifactFailure>()
            .having((failure) => failure.missingPaths, 'missingPaths', ['myproj/x.md'])
            .having((failure) => failure.fieldName, 'fieldName', 'report'),
      ),
    );
  });

  test('resolves every claimed file in a list output', () async {
    final worktree = harness.createWorktree('worktree-explicit-list');
    harness.writeWorktreeFile(worktree, 'fis/s01-foo.md', '# Existing Foo\n');
    harness.writeWorktreeFile(worktree, 'fis/s02-bar.md', '# Bar\n');
    final localExtractor = harness.extractorFor();
    final taskWithWorktree = await harness.buildTaskWithContext('task-explicit-list', {
      'fis_paths': ['fis/s01-foo.md', 'fis/s02-bar.md'],
    }, worktreePath: worktree.path);

    final step = harness.makeStep(outputs: const {'fis_paths': OutputConfig(format: OutputFormat.lines)});

    final outputs = await localExtractor.extract(step, taskWithWorktree);

    expect(outputs['fis_paths'], ['fis/s01-foo.md', 'fis/s02-bar.md']);
  });

  test('throws StateError when a singular filesystem output claims multiple existing paths', () async {
    final worktree = harness.createWorktree('worktree-ambiguous');
    harness.writeWorktreeFile(worktree, 'docs/a/prd.md', '# A\n');
    harness.writeWorktreeFile(worktree, 'docs/b/prd.md', '# B\n');
    final localExtractor = harness.extractorFor();
    final taskWithWorktree = await harness.buildTaskWithContext('task-ambiguous-path', {
      'prd': ['docs/a/prd.md', 'docs/b/prd.md'],
    }, worktreePath: worktree.path);
    final step = harness.pathOutputStep('prd');

    await expectLater(
      localExtractor.extract(step, taskWithWorktree),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Multiple filesystem artifacts'))),
    );
  });

  // The canonical-basename tie-break is declarative (`preferPatterns:` on the
  // filesystem output), never a hard-coded engine preference on the `plan`/`prd`
  // output key. TI04 re-points the selector from the worktree diff to the
  // host-owned step artifacts dir; its semantics are unchanged.
  test('preferPatterns picks plan.json when the step dir also holds plan.md', () async {
    const runId = 'run-plan-json-preferred';
    final planJson = harness.writeStepReview(runId, 'step1', 'plan.json', content: '{"schemaVersion":"1"}');
    harness.writeStepReview(runId, 'step1', 'plan.md', content: '# Plan\n');
    final step = harness.makeStep(
      outputs: const {
        'plan': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(
            pathPattern: '**/*plan.{json,md}',
            listMode: false,
            preferPatterns: ['plan.json', 'plan.md'],
          ),
        ),
      },
    );

    final outputs = await harness.extractStepFromContext(
      extractor,
      step,
      'task-plan-json-preferred',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['plan'], planJson);
  });

  test('preferPatterns picks canonical prd.md when the step dir also holds dashed drafts', () async {
    const runId = 'run-prd-preferred';
    final prd = harness.writeStepReview(runId, 'step1', 'prd.md', content: '# PRD\n');
    harness.writeStepReview(runId, 'step1', 'draft-prd.md', content: '# Draft\n');
    final step = harness.makeStep(
      outputs: const {
        'prd': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/*prd.md', listMode: false, preferPatterns: ['prd.md']),
        ),
      },
    );

    final outputs = await harness.extractStepFromContext(
      extractor,
      step,
      'task-prd-preferred',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['prd'], prd);
  });

  test('without preferPatterns the engine applies no built-in plan/prd preference', () async {
    // Regression guard: no framework basename is hard-coded in the engine, so a
    // bare `plan` path output seeing both plan.json and plan.md falls through to
    // the generic newest-modified tie-break rather than silently preferring
    // plan.json.
    const runId = 'run-no-builtin-pref';
    final planJson = harness.writeStepReview(runId, 'step1', 'plan.json', content: '{"schemaVersion":"1"}');
    final planMd = harness.writeStepReview(runId, 'step1', 'plan.md', content: '# Plan\n');
    File(planJson).setLastModifiedSync(DateTime(2026, 4, 1));
    File(planMd).setLastModifiedSync(DateTime(2026, 4, 2));
    final step = harness.makeStep(outputs: const {'plan': OutputConfig(format: OutputFormat.path)});

    final outputs = await harness.extractStepFromContext(
      extractor,
      step,
      'task-no-builtin-pref',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['plan'], planMd);
  });

  test('a step declaring three path outputs resolves each by its own declared pattern', () async {
    // The built-in `discover-plan-state` shape: three `format: path` outputs
    // whose only discriminator is their declared pattern. A single engine-side
    // rule (newest file, or newest `.md`) would hand all three the same file and
    // could never produce plan.json.
    const runId = 'run-multi-path-outputs';
    const stepId = 'discover-plan-state';
    final prd = harness.writeStepReview(runId, stepId, 'prd.md', content: '# PRD\n');
    final planJson = harness.writeStepReview(runId, stepId, 'plan.json', content: '{"schemaVersion":"1"}');
    harness.writeStepReview(runId, stepId, 'plan.md', content: '# Legacy plan\n');
    final research = harness.writeStepReview(runId, stepId, '.technical-research.md', content: '# Research\n');

    final step = harness.makeStep(
      id: stepId,
      outputs: const {
        'prd': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/*prd.md', listMode: false, preferPatterns: ['prd.md']),
        ),
        'plan': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(
            pathPattern: '**/*plan.{json,md}',
            listMode: false,
            preferPatterns: ['plan.json', 'plan.md'],
          ),
        ),
        'technical_research': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/.technical?research.md', listMode: false),
        ),
      },
    );

    final outputs = await harness.extractStepFromContext(
      extractor,
      step,
      'task-multi-path-outputs',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['prd'], prd);
    expect(outputs['plan'], planJson);
    expect(outputs['technical_research'], research);
    expect({outputs['prd'], outputs['plan'], outputs['technical_research']}, hasLength(3));
  });

  test('an unclaimed path output whose pattern matches nothing resolves empty, borrowing no file', () async {
    const runId = 'run-pattern-no-match';
    const stepId = 'discover-plan-state';
    final unrelated = harness.writeStepReview(runId, stepId, 'notes.md', content: '# Notes\n');
    final step = harness.makeStep(
      id: stepId,
      outputs: const {
        'plan': OutputConfig(
          format: OutputFormat.path,
          resolverOverride: FileSystemOutput(pathPattern: '**/*plan.{json,md}', listMode: false),
        ),
      },
    );

    final outputs = await harness.extractStepFromContext(
      extractor,
      step,
      'task-pattern-no-match',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['plan'], '');
    expect(outputs['plan'], isNot(unrelated));
  });

  test('a non-review path output with no claim is captured from the same step artifacts dir', () async {
    // OC02: no output key, preset name or pattern marks an output as a review —
    // a plain `design_notes` path output resolves through the identical path a
    // review report does, and gets an absolute step-dir value.
    const runId = 'run-design-notes';
    final notes = harness.writeStepReview(runId, 'step1', 'notes.md', content: '# Design notes\n');

    final outputs = await harness.extractPathOutputFromContext(
      extractor,
      'design_notes',
      'task-design-notes',
      const {},
      workflowRunId: runId,
    );

    expect(outputs['design_notes'], notes);
    expect(p.isAbsolute(outputs['design_notes'] as String), isTrue);
  });

  test('an explicitly empty path claim short-circuits without a step-dir capture', () async {
    const runId = 'run-empty-claim';
    harness.writeStepReview(runId, 'step1', 'stray-plan.md', content: '# Stray\n');

    final emptyString = await harness.extractPathOutputFromContext(extractor, 'plan', 'task-empty-string-claim', const {
      'plan': '',
    }, workflowRunId: runId);
    expect(emptyString['plan'], '');
  });

  test('a null envelope path value is no claim at all, leaving the step-dir capture reachable', () async {
    // The envelope schema declares path keys required+nullable so "no claim"
    // survives strict mode; `null` therefore means the model named nothing, not
    // that it named emptiness. Only `""` is an explicit "no path".
    const runId = 'run-null-claim';
    final stray = harness.writeStepReview(runId, 'step1', 'stray-plan.md', content: '# Stray\n');

    final jsonNull = await harness.extractPathOutputFromContext(extractor, 'plan', 'task-json-null-claim', const {
      'plan': null,
    }, workflowRunId: runId);

    expect(jsonNull['plan'], stray);
  });

  test('the literal string "null" is an ordinary path claim, not a sentinel', () async {
    final worktree = harness.createWorktree('worktree-literal-null');
    final localExtractor = harness.extractorFor();
    final task = await harness.buildTaskWithContext('task-literal-null-claim', {
      'plan': 'null',
    }, worktreePath: worktree.path);

    await expectLater(
      localExtractor.extract(harness.pathOutputStep('plan'), task),
      throwsA(isA<MissingArtifactFailure>().having((failure) => failure.claimedPaths, 'claimedPaths', ['null'])),
    );
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
      // means "no claim", so the key never reaches the claim view and the host
      // captures from the step dir — a dirty worktree is irrelevant.
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
      // A claim naming no existing, contained file is unusable, so resolution
      // falls through to the host-owned step dir instead of borrowing a
      // worktree file that happens to be lying around.
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
