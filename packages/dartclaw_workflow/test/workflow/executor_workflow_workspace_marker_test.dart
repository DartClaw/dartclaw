@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowStep;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

/// Drives the default-path workflow-workspace `AGENTS.md` reconcile in
/// `_resolveWorkflowWorkspaceDir`. Each case uses a fresh executor (so the
/// per-instance `_workflowWorkspaceDirCache` memoization runs the reconcile
/// once) and asserts the resulting file/marker state.
void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  var runSeq = 0;

  WorkflowDefinition singleStepDefinition() => h.makeDefinition(
    steps: [
      const WorkflowStep(
        id: 'spec',
        name: 'Generate Spec',
        prompts: ['Write the specification.'],
        outputs: {'result': OutputConfig(format: OutputFormat.json)},
      ),
    ],
  );

  /// Runs one workflow step against [executor], completing its task, which
  /// triggers `_resolveWorkflowWorkspaceDir` and the managed-marker reconcile.
  Future<void> runWorkflowStep(WorkflowExecutor executor) async {
    final definition = singleStepDefinition();
    final run = h.makeRun(definition).copyWith(id: 'run-${runSeq++}');
    await h.repository.insert(run);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });
    await executor.execute(run, definition, WorkflowContext());
    await sub.cancel();
  }

  String agentsPath() => p.join(h.tempDir.path, 'workflow-workspace', 'AGENTS.md');
  String markerPath() => p.join(h.tempDir.path, 'workflow-workspace', 'AGENTS.md.dartclaw-managed.json');

  /// The shipped template content, captured by materializing into a throwaway
  /// data dir so the test never imports the internal template constant.
  Future<String> shippedTemplate() async {
    final scratch = Directory.systemTemp.createTempSync('dartclaw_wf_tpl_');
    addTearDown(() {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });
    final executor = h.makeExecutor(dataDir: scratch.path);
    final definition = singleStepDefinition();
    final run = h.makeRun(definition).copyWith(id: 'run-${runSeq++}');
    await h.repository.insert(run);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });
    await executor.execute(run, definition, WorkflowContext());
    await sub.cancel();
    return File(p.join(scratch.path, 'workflow-workspace', 'AGENTS.md')).readAsStringSync();
  }

  String markerContentFor(String content) => jsonEncode({
    'managedContent': content,
    'note':
        'Managed by DartClaw; edits are preserved once changed. '
        'Override the default via workflow.workspace_dir.',
  });

  test('S01 absent file is materialized with a marker', () async {
    final template = await shippedTemplate();

    await runWorkflowStep(h.executor);

    expect(File(agentsPath()).readAsStringSync(), template);
    final marker = jsonDecode(File(markerPath()).readAsStringSync()) as Map<String, dynamic>;
    expect(marker['managedContent'], template);
  });

  test('S02 user edits are preserved', () async {
    final template = await shippedTemplate();
    Directory(p.dirname(agentsPath())).createSync(recursive: true);
    File(agentsPath()).writeAsStringSync('user customization');
    File(markerPath()).writeAsStringSync(markerContentFor(template));

    await runWorkflowStep(h.executor);

    expect(File(agentsPath()).readAsStringSync(), 'user customization');
    expect(jsonDecode(File(markerPath()).readAsStringSync())['managedContent'], template);
  });

  test('S03 unmodified file refreshes when the template changes', () async {
    final template = await shippedTemplate();
    Directory(p.dirname(agentsPath())).createSync(recursive: true);
    // Marker + file both record a stale prior template.
    File(agentsPath()).writeAsStringSync('stale template');
    File(markerPath()).writeAsStringSync(markerContentFor('stale template'));

    await runWorkflowStep(h.executor);

    expect(File(agentsPath()).readAsStringSync(), template);
    expect(jsonDecode(File(markerPath()).readAsStringSync())['managedContent'], template);
  });

  test('S04 unmodified file with up-to-date template is a no-op', () async {
    final template = await shippedTemplate();
    Directory(p.dirname(agentsPath())).createSync(recursive: true);
    File(agentsPath()).writeAsStringSync(template);
    // Seed a non-canonical marker (pretty-printed) whose managedContent already
    // equals the current template. A spurious rewrite would re-encode it
    // compactly, changing the bytes – so byte-identity, not mtime, proves the
    // no-op even on coarse-mtime filesystems.
    final seededMarker = const JsonEncoder.withIndent(
      '  ',
    ).convert({'managedContent': template, 'note': 'seeded non-canonical marker'});
    File(markerPath()).writeAsStringSync(seededMarker);

    await runWorkflowStep(h.executor);

    expect(File(agentsPath()).readAsStringSync(), template);
    expect(File(markerPath()).readAsStringSync(), seededMarker);
  });

  test('S05 pre-marker install reconciles once, then respects edits', () async {
    final template = await shippedTemplate();
    Directory(p.dirname(agentsPath())).createSync(recursive: true);
    // Existing install: file present, no marker.
    File(agentsPath()).writeAsStringSync('legacy content');
    expect(File(markerPath()).existsSync(), isFalse);

    await runWorkflowStep(h.executor);

    // One-time reconcile to the current template + marker write.
    expect(File(agentsPath()).readAsStringSync(), template);
    expect(jsonDecode(File(markerPath()).readAsStringSync())['managedContent'], template);

    // A later user edit on a fresh executor is preserved.
    File(agentsPath()).writeAsStringSync('edited after migration');
    await runWorkflowStep(h.makeExecutor());
    expect(File(agentsPath()).readAsStringSync(), 'edited after migration');
  });

  test('S06 custom workspace_dir is never touched', () async {
    final customDir = Directory(p.join(h.tempDir.path, 'operator-workspace'))..createSync(recursive: true);
    final executor = h.makeExecutor(turnAdapter: standardTurnAdapter(workflowWorkspaceDir: customDir.path));

    await runWorkflowStep(executor);

    expect(File(p.join(customDir.path, 'AGENTS.md')).existsSync(), isFalse);
    expect(File(p.join(customDir.path, 'AGENTS.md.dartclaw-managed.json')).existsSync(), isFalse);
  });

  // A present-but-unparseable marker is treated as no-usable-marker, so the file
  // is reconciled once to the current template (same boundary as a pre-marker
  // install). This pins that deliberate decision so a future marker-read change
  // can't silently flip it.
  test('corrupt marker is treated as absent and reconciled once', () async {
    final template = await shippedTemplate();
    Directory(p.dirname(agentsPath())).createSync(recursive: true);
    File(agentsPath()).writeAsStringSync('pre-existing content');
    File(markerPath()).writeAsStringSync('{not valid json');

    await runWorkflowStep(h.executor);

    expect(File(agentsPath()).readAsStringSync(), template);
    expect(jsonDecode(File(markerPath()).readAsStringSync())['managedContent'], template);
  });
}
