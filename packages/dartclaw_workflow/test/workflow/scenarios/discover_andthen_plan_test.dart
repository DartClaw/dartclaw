@Tags(['component'])
library;

import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, OutputConfig, OutputFormat, TaskType, WorkflowStep;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: discovery, plan-json

void main() {
  group('dartclaw-discover-andthen-plan handoff', () {
    test('skill contract keeps fail-fast PRD and JSON story parsing instructions', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);

      final skill = harness.readRepoFile('packages/dartclaw_workflow/skills/dartclaw-discover-andthen-plan/SKILL.md');

      expect(skill, contains('If no PRD exists, fail the step'));
      expect(skill, contains('plan.json'));
      expect(skill, contains('*-plan.json'));
      expect(skill, contains('stories[]'));
      expect(skill, contains('Always emit `dependencies` as an array'));
      expect(skill, contains('Do not emit `spec_source` or `spec_confidence` from discovery'));
      expect(skill, contains('skipped/done stories are not re-emitted'));
      expect(skill, contains('normalized to `pending`'));
      expect(skill, isNot(contains('project_index')));
      // Examples for DC-native skills live in SKILL.md alongside the contract –
      // the workflow YAML does not duplicate them via outputExamples.
      expect(skill, contains('<workflow-context>'));
    });

    test('extracts flat prd, plan, and story_specs outputs', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('sample-project');
      const prdPath = 'dev/specs/0.16.5/prd.md';
      const planPath = 'dev/specs/0.16.5/s-plan-json-adoption-sample-plan.json';
      final planContent = harness.readRepoFile(
        'packages/dartclaw_workflow/test/fixtures/s-plan-json-adoption-sample-plan.json',
      );
      harness.writeProjectFile(projectRoot, prdPath, '# PRD\n');
      harness.writeProjectFile(projectRoot, planPath, planContent);
      final plan = jsonDecode(planContent) as Map<String, dynamic>;
      for (final story in (plan['stories'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        harness.writeProjectFile(
          projectRoot,
          p.posix.join('dev/specs/0.16.5', story['fis'] as String),
          '# ${story['name']}\n',
        );
      }

      final outputs = await _extractDiscoverAndthenPlanOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {
          'prd': prdPath,
          'plan': planPath,
          'story_specs': _storySpecsFromPlan(plan, planDir: 'dev/specs/0.16.5'),
        },
      );

      final storySpecs = outputs['story_specs'] as Map<String, dynamic>;
      final items = (storySpecs['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(outputs['prd'], prdPath);
      expect(outputs['plan'], planPath);
      expect(items.map((item) => item['id']), ['S01', 'S02', 'S04', 'S05']);
      expect(items.first, containsPair('title', 'Stimulus Foundation and Loading Contract'));
      expect(items.first, containsPair('spec_path', 'dev/specs/0.16.5/fis/s01-stimulus-foundation.md'));
      expect(items.first, containsPair('dependencies', <String>[]));
      expect(items[1], containsPair('dependencies', ['S01']));
      expect(items[1], containsPair('risk', 'high'));
      expect(items.last, containsPair('phase', 'P4'));
      expect(items.last, containsPair('wave', 'W4'));
      expect(items.every((item) => item.containsKey('parallel') && item.containsKey('status')), isTrue);
    });

    test('schema accepts plan-emitted spec_source and spec_confidence fields', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('confidence-project');
      harness.writeProjectFile(projectRoot, 'docs/specs/demo/prd.md', '# PRD\n');
      harness.writeProjectFile(projectRoot, 'docs/specs/demo/plan.json', '{}\n');
      harness.writeProjectFile(projectRoot, 'docs/specs/demo/fis/s01-story.md', '# Story\n');

      final outputs = await _extractDiscoverAndthenPlanOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {
          'prd': 'docs/specs/demo/prd.md',
          'plan': 'docs/specs/demo/plan.json',
          'story_specs': {
            'items': [
              {
                'id': 'S01',
                'title': 'Story',
                'spec_path': 'docs/specs/demo/fis/s01-story.md',
                'dependencies': <String>[],
                'spec_source': 'synthesized',
                'spec_confidence': 5,
              },
            ],
          },
        },
      );

      final storySpecs = outputs['story_specs'] as Map<String, dynamic>;
      final item = (storySpecs['items'] as List<dynamic>).single as Map<String, dynamic>;
      expect(item['spec_source'], 'synthesized');
      expect(item['spec_confidence'], 5);
    });

    test('empty optional plan handoff stays empty without project_index defaults', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('prd-only-project');
      harness.writeProjectFile(projectRoot, 'docs/specs/demo/prd.md', '# PRD\n');

      final outputs = await _extractDiscoverAndthenPlanOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {
          'prd': 'docs/specs/demo/prd.md',
          'plan': '',
          'story_specs': {'items': <Map<String, dynamic>>[]},
        },
      );

      expect(outputs['prd'], 'docs/specs/demo/prd.md');
      expect(outputs['plan'], '');
      expect(outputs['story_specs'], {'items': <Map<String, dynamic>>[]});
    });

    // This scenario pins the `_storySpecsFromPlan` helper's contract, which
    // mirrors the SKILL.md resume-filter rule. The production-side regression
    // gate for the prompt text lives in `built_in_skill_inventory_test.dart`
    // (`discover-andthen-plan documents flat PRD/plan/story-spec contract`),
    // which greps the SKILL.md for `closed set {done, skipped}`,
    // `pending, spec-ready, in-progress, done, skipped, blocked`, and the
    // missing/unknown → pending clause. If those drift apart, both tests must
    // be updated in lockstep.
    test('filter excludes done and skipped but keeps blocked resumable', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('resume-project');
      const prdPath = 'docs/specs/demo/prd.md';
      const planPath = 'docs/specs/demo/plan.json';
      harness.writeProjectFile(projectRoot, prdPath, '# PRD\n');
      harness.writeProjectFile(projectRoot, planPath, '{}\n');
      for (final path in ['fis/s02-story.md', 'fis/s03-story.md', 'fis/s05-story.md']) {
        harness.writeProjectFile(projectRoot, 'docs/specs/demo/$path', '# Story\n');
      }

      final outputs = await _extractDiscoverAndthenPlanOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {
          'prd': prdPath,
          'plan': planPath,
          'story_specs': _storySpecsFromPlan(
            _planWithStories([
              _story('S01', status: 'done', fis: 'fis/s01-story.md'),
              _story('S02', status: 'spec-ready', fis: 'fis/s02-story.md'),
              _story('S03', status: 'in-progress', fis: 'fis/s03-story.md'),
              _story('S04', status: 'skipped', fis: 'fis/s04-story.md'),
              // `blocked` is an AndThen status enum member but remains
              // resumable; only terminal statuses are filtered.
              _story('S05', status: 'blocked', fis: 'fis/s05-story.md'),
            ]),
            planDir: 'docs/specs/demo',
          ),
        },
      );

      final items = ((outputs['story_specs'] as Map<String, dynamic>)['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(items.map((item) => item['id']), ['S02', 'S03', 'S05']);
      expect(items.map((item) => item['status']), ['spec-ready', 'in-progress', 'blocked']);
    });

    test('all-done plan emits empty items', () async {
      final storySpecs = _storySpecsFromPlan(
        _planWithStories([
          _story('S01', status: 'done', fis: 'fis/s01-story.md'),
          _story('S02', status: 'done', fis: 'fis/s02-story.md'),
        ]),
        planDir: 'docs/specs/demo',
      );

      expect(storySpecs, {'items': <Map<String, dynamic>>[]});
    });

    test('missing or unknown status normalizes to pending and emits', () async {
      final storySpecs = _storySpecsFromPlan(
        _planWithStories([
          _story('S01', fis: 'fis/s01-story.md'),
          _story('S02', status: 'frozen', fis: 'fis/s02-story.md'),
          _story('S03', status: 'spec-ready', fis: 'fis/s03-story.md'),
        ]),
        planDir: 'docs/specs/demo',
      );

      final items = (storySpecs['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(items.map((item) => item['id']), ['S01', 'S02', 'S03']);
      expect(items.map((item) => item['status']), ['pending', 'pending', 'spec-ready']);
    });
  });
}

Future<Map<String, dynamic>> _extractDiscoverAndthenPlanOutputs(
  ScenarioTaskHarness harness, {
  required String projectRoot,
  required Map<String, dynamic> payload,
}) async {
  final session = await harness.sessions.getOrCreateMainSession();
  await harness.messages.insertMessage(
    sessionId: session.id,
    role: 'assistant',
    content: '<workflow-context>${jsonEncode(payload)}</workflow-context>',
  );
  final task = await harness.tasks.create(
    id: 'task-${DateTime.now().microsecondsSinceEpoch}',
    title: 'Discover',
    description: 'Discover',
    type: TaskType.research,
    autoStart: true,
  );
  await harness.tasks.updateFields(task.id, sessionId: session.id, worktreeJson: {'path': projectRoot});
  final taskWithSession = (await harness.tasks.get(task.id))!;
  final extractor = ContextExtractor(
    taskService: harness.tasks,
    messageService: harness.messages,
    dataDir: harness.tempDir.path,
    workflowStepExecutionRepository: harness.workflowStepExecutions,
  );
  return extractor.extract(
    const WorkflowStep(
      id: 'discover-plan-state',
      name: 'Discover Plan State',
      outputs: {
        'prd': OutputConfig(format: OutputFormat.path),
        'plan': OutputConfig(format: OutputFormat.path),
        'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs'),
      },
    ),
    taskWithSession,
  );
}

Map<String, dynamic> _storySpecsFromPlan(Map<String, dynamic> plan, {required String planDir}) {
  const statusEnum = {'pending', 'spec-ready', 'in-progress', 'done', 'skipped', 'blocked'};
  final items = <Map<String, dynamic>>[];
  for (final story in (plan['stories'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    final fis = story['fis'];
    if (fis is! String || fis.trim().isEmpty) continue;
    final rawStatus = story['status'];
    final status = rawStatus is String && statusEnum.contains(rawStatus) ? rawStatus : 'pending';
    if (status == 'done' || status == 'skipped') continue;
    items.add({
      'id': story['id'],
      'title': story['name'],
      'spec_path': p.posix.normalize(p.posix.join(planDir, fis)),
      'dependencies': (story['dependsOn'] as List<dynamic>?)?.cast<String>() ?? <String>[],
      'parallel': story['parallel'],
      'wave': story['wave'],
      'phase': story['phase'],
      'risk': story['risk'],
      'status': status,
    });
  }
  return {'items': items};
}

Map<String, dynamic> _planWithStories(List<Map<String, dynamic>> stories) => {'stories': stories};

Map<String, dynamic> _story(String id, {String? status, required String fis}) {
  final story = <String, dynamic>{'id': id, 'name': 'Story $id', 'fis': fis};
  if (status != null) story['status'] = status;
  return story;
}
