@Tags(['component'])
library;

import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show OutputConfig, OutputFormat, WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/story_specs_contract_validator.dart' show validateStorySpecsContract;
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
      expect(skill, contains('every story that depends on a `skipped` story, directly or transitively'));
      expect(skill, contains('normalized to `pending`'));
      expect(skill, isNot(contains('project_index')));
      // Examples for DC-native skills live in SKILL.md alongside the contract –
      // the workflow YAML does not duplicate them via outputExamples. They show
      // the envelope's `outputs`, never a tagged block.
      expect(skill, contains('execution envelope'));
      expect(skill, isNot(contains('<workflow-context>')));
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
    // which greps the SKILL.md for `closed set {done, skipped}`, the
    // skipped-dependent omission, `pending, in-progress, done, skipped`, and the
    // missing/unknown → pending clause. If those drift apart, both tests must
    // be updated in lockstep.
    test('filter excludes done and skipped, and retired statuses resume as pending', () async {
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
              _story('S02', status: 'pending', fis: 'fis/s02-story.md'),
              _story('S03', status: 'in-progress', fis: 'fis/s03-story.md'),
              _story('S04', status: 'skipped', fis: 'fis/s04-story.md'),
              // `blocked` left AndThen's enum: an old plan's row still resumes,
              // normalized to `pending`; only terminal statuses are filtered.
              _story('S05', status: 'blocked', fis: 'fis/s05-story.md'),
            ]),
            planDir: 'docs/specs/demo',
          ),
        },
      );

      final items = ((outputs['story_specs'] as Map<String, dynamic>)['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(items.map((item) => item['id']), ['S02', 'S03', 'S05']);
      expect(items.map((item) => item['status']), ['pending', 'in-progress', 'pending']);
    });

    test('stories depending on a skipped story are omitted, transitively', () async {
      // A skipped story was never built, so its dependents cannot run. Emitting
      // them would leave a dependency no item satisfies, which fails the whole
      // plan at `Unknown dependency IDs` instead of just the blocked chain.
      final storySpecs = _storySpecsFromPlan(
        _planWithStories([
          _story('S01', status: 'skipped', fis: 'fis/s01-story.md'),
          _story('S02', status: 'pending', fis: 'fis/s02-story.md', dependsOn: ['S01']),
          _story('S03', status: 'pending', fis: 'fis/s03-story.md', dependsOn: ['S02']),
          _story('S04', status: 'pending', fis: 'fis/s04-story.md'),
          _story('S05', status: 'pending', fis: 'fis/s05-story.md', dependsOn: ['S04']),
        ]),
        planDir: 'docs/specs/demo',
      );

      final items = (storySpecs['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(items.map((item) => item['id']), ['S04', 'S05']);
      expect(validateStorySpecsContract(storySpecs).validationFailure, isNull);
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
      expect(items.map((item) => item['status']), ['pending', 'pending', 'pending']);
    });
  });
}

Future<Map<String, dynamic>> _extractDiscoverAndthenPlanOutputs(
  ScenarioTaskHarness harness, {
  required String projectRoot,
  required Map<String, dynamic> payload,
}) async {
  final session = await harness.sessions.getOrCreateMainSession();
  final runId = 'run-discover-plan-${DateTime.now().microsecondsSinceEpoch}';
  final task = await harness.tasks.create(
    id: 'task-${DateTime.now().microsecondsSinceEpoch}',
    title: 'Discover',
    description: 'Discover',
    autoStart: true,
  );
  await harness.tasks.updateFields(task.id, sessionId: session.id, worktreeJson: {'path': projectRoot});
  await harness.seedEnvelopeOutputs(task.id, payload, workflowRunId: runId);
  final taskWithSession = (await harness.tasks.get(task.id))!;
  final extractor = harness.contextExtractor();
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
  const statusEnum = {'pending', 'in-progress', 'done', 'skipped'};
  final stories = (plan['stories'] as List<dynamic>).cast<Map<String, dynamic>>();
  // Skipped stories and everything that depends on one, directly or transitively.
  final blocked = {
    for (final story in stories)
      if (story['status'] == 'skipped') story['id'],
  };
  for (var grew = true; grew;) {
    grew = false;
    for (final story in stories) {
      final deps = (story['dependsOn'] as List<dynamic>?) ?? const <dynamic>[];
      if (!blocked.contains(story['id']) && deps.any(blocked.contains)) {
        blocked.add(story['id']);
        grew = true;
      }
    }
  }
  final items = <Map<String, dynamic>>[];
  for (final story in stories) {
    final fis = story['fis'];
    if (fis is! String || fis.trim().isEmpty) continue;
    final rawStatus = story['status'];
    final status = rawStatus is String && statusEnum.contains(rawStatus) ? rawStatus : 'pending';
    if (status == 'done' || blocked.contains(story['id'])) continue;
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

Map<String, dynamic> _story(String id, {String? status, required String fis, List<String>? dependsOn}) {
  final story = <String, dynamic>{'id': id, 'name': 'Story $id', 'fis': fis};
  if (status != null) story['status'] = status;
  if (dependsOn != null) story['dependsOn'] = dependsOn;
  return story;
}
