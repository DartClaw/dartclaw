import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show TaskType, WorkflowRunStatus;
import 'package:test/test.dart';

import 'workflow_builtin_test_support.dart';

void main() {
  final driver = BuiltInWorkflowDriver();
  setUpAll(driver.setUpAll);
  setUp(driver.setUp);
  tearDown(driver.tearDown);

  test('plan-and-implement integration runs per-story foreach pipeline after merged plan step', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {'FEATURE': 'Ship validate step', 'PROJECT': 'demo-project', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
              'marker': 'PLAN_DISCOVER_MARKER',
            }),
          ),
          'prd' => StubResponse(
            assistantContent: contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          // The merged plan step now emits stories + story_specs in one pass.
          'plan' => StubResponse(
            assistantContent: contextOutput({
              'plan': 'docs/specs/test/plan.md',
              'plan_source': 'synthesized',
              'stories': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'description': 'First integration story',
                    'acceptance_criteria': ['first passes'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                  },
                  {
                    'id': 'S02',
                    'title': 'Story Two',
                    'description': 'Second integration story',
                    'acceptance_criteria': ['second passes'],
                    'type': 'coding',
                    'dependencies': ['S01'],
                    'key_files': ['lib/b.dart'],
                    'effort': 'small',
                  },
                ],
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'description': 'First integration story',
                    'acceptance_criteria': ['first passes'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/test/fis/s01-story-one.md',
                    'fis_source': 'synthesized',
                    'spec_confidence': 5,
                  },
                  {
                    'id': 'S02',
                    'title': 'Story Two',
                    'description': 'Second integration story',
                    'acceptance_criteria': ['second passes'],
                    'type': 'coding',
                    'dependencies': ['S01'],
                    'key_files': ['lib/b.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/test/fis/s02-story-two.md',
                    'fis_source': 'existing',
                    'spec_confidence': 0,
                  },
                ],
              },
            }),
          ),
          'revise-story-spec' => StubResponse(assistantContent: contextOutput({})),
          _ => planAndImplementCommonStub(
            queued,
            storyResult: 'STORY_RESULT_${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
            branch: queued.mapIndex == 0 ? 'story-alpha' : 'story-beta',
            worktreePath: '/tmp/worktrees/${queued.mapIndex == 0 ? 'alpha' : 'beta'}',
            remediationSummary: 'No batch remediation needed',
            diffSummary: 'batch clean',
          ),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
    // PRD is discovered input; merged plan emits stories + story_specs once; foreach runs per story.
    expect(trace.count('prd'), 0);
    expect(trace.count('plan'), 1);
    // The PRD path is passed through to the plan step unchanged.
    expect(trace.descriptionsByStep['plan']!.single, contains('docs/specs/test/prd.md'));
    expect(trace.count('revise-story-spec'), 1);
    expect(trace.count('implement'), 2);
    expect(trace.count('quick-review'), 0, reason: 'quick-review is replaced by the per-story review + nested loop');
    expect(trace.count('simplify-code'), 2);
    expect(trace.count('review-story'), 2);
    expect(trace.count('plan-review'), 1);

    // Per-iteration `continueSession` isolation guard: each iteration's
    // simplify-code (the continueSession step now that quick-review is gone)
    // must inherit a *distinct* implement session id, never the prior
    // iteration's. Foreach runs each iteration in a fresh iterContext so the
    // bare `${implement.id}.sessionId` never bleeds across iterations; this
    // assertion is the runtime check that proves that structural property.
    final continueSessionTasks = trace.tasksForStep('simplify-code');
    expect(continueSessionTasks, hasLength(2));
    final iter0SessionId = continueSessionTasks[0].configJson['_continueSessionId'];
    final iter1SessionId = continueSessionTasks[1].configJson['_continueSessionId'];
    expect(iter0SessionId, isNotNull, reason: 'iteration 0 simplify-code should resolve a continueSessionId');
    expect(iter1SessionId, isNotNull, reason: 'iteration 1 simplify-code should resolve a continueSessionId');
    expect(
      iter0SessionId,
      isNot(equals(iter1SessionId)),
      reason: 'per-iteration session isolation: continueSession must resolve to distinct ids across iterations',
    );

    // Per-story results are aggregated in story_results from the foreach controller outputs.
    final storyResults = trace.context['story_results'] as List<dynamic>;
    expect(storyResults, hasLength(2));
    final r0 = storyResults[0] as Map<String, dynamic>;
    final r1 = storyResults[1] as Map<String, dynamic>;
    expect((r0['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_ALPHA');
    expect((r1['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_BETA');
  });

  test('plan-and-implement integration binds project-aware steps to the workflow PROJECT', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Project binding check for plan workflow',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'prd' => StubResponse(
            assistantContent: contextOutput({
              'prd': 'docs/specs/project-bound/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'plan' => StubResponse(
            assistantContent: contextOutput({
              'plan': 'docs/specs/project-bound/plan.md',
              'plan_source': 'synthesized',
              'stories': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Project Bound Story',
                    'description': 'Verify project propagation',
                    'acceptance_criteria': ['all coding steps use the workflow project'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                  },
                ],
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Project Bound Story',
                    'description': 'Verify project propagation',
                    'acceptance_criteria': ['all coding steps use the workflow project'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/project-bound/fis/s01-project-bound-story.md',
                  },
                ],
              },
            }),
          ),
          _ => planAndImplementCommonStub(
            queued,
            storyResult: 'PROJECT_BOUND_RESULT',
            branch: 'project-bound-story',
            worktreePath: '/tmp/worktrees/project-bound-story',
          ),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
    expect(trace.tasksForStep('discover-plan-state').single.projectId, 'demo-project');
    expect(trace.tasksForStep('discover-plan-state').single.type, TaskType.coding);
    expect(trace.tasksForStep('plan').single.projectId, 'demo-project');
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.type, TaskType.coding);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('implement').single.type, TaskType.coding);
    expect(trace.tasksForStep('simplify-code').single.projectId, 'demo-project');
    expect(trace.tasksForStep('simplify-code').single.type, TaskType.coding);
    // simplify-code uses `continueSession: true` to pin to the implement task's
    // harness session – the dispatcher must have threaded the prior root's
    // session id through `_continueSessionId`. Provider-session id only
    // propagates when the implement task actually emitted one (the test stub
    // does not, so that key stays absent).
    expect(trace.tasksForStep('simplify-code').single.configJson.containsKey('_continueSessionId'), isTrue);
    expect(trace.tasksForStep('simplify-code').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan-review').single.projectId, 'demo-project');
    expect(trace.tasksForStep('plan-review').single.type, TaskType.coding);
    expect(trace.tasksForStep('plan-review').single.configJson['_workflowNeedsWorktree'], isTrue);
    expect(trace.tasksForStep('update-state'), isEmpty);
  });

  test(
    'plan-and-implement marks per-story analysis steps as worktree-bound when map parallelism resolves to per-map-item',
    () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'plan-and-implement.yaml',
        variables: {
          'FEATURE': 'Per-map-item worktree flag check',
          'PROJECT': 'demo-project',
          'BRANCH': 'main',
          'MAX_PARALLEL': '2',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-plan-state' => StubResponse(
              assistantContent: jsonEncode({
                'framework': 'none',
                'project_root': '/repo/demo-project',
                'document_locations': {'product': null},
                'state_protocol': {'type': 'none'},
              }),
            ),
            'prd' => StubResponse(
              assistantContent: contextOutput({
                'prd': 'docs/specs/demo/prd.md',
                'prd_source': 'synthesized',
                'prd_confidence': 9,
              }),
            ),
            'plan' => StubResponse(
              assistantContent: contextOutput({
                'plan': 'docs/specs/demo/plan.md',
                'plan_source': 'synthesized',
                'story_specs': {
                  'items': [
                    {
                      'id': 'S01',
                      'title': 'Story One',
                      'spec_path': 'docs/specs/demo/fis/s01-story-one.md',
                      'acceptance_criteria': ['first passes'],
                      'dependencies': <String>[],
                    },
                    {
                      'id': 'S02',
                      'title': 'Story Two',
                      'spec_path': 'docs/specs/demo/fis/s02-story-two.md',
                      'acceptance_criteria': ['second passes'],
                      'dependencies': <String>[],
                    },
                  ],
                },
              }),
            ),
            _ => planAndImplementCommonStub(
              queued,
              branch: 'story-branch-${queued.mapIndex}',
              worktreePath: '/tmp/worktrees/story-${queued.mapIndex}',
            ),
          };
        },
      );

      final reviewStories = trace.tasksForStep('review-story');
      expect(reviewStories, hasLength(2));
      for (final reviewStory in reviewStories) {
        expect(reviewStory.type, TaskType.coding);
        expect(reviewStory.configJson['_workflowNeedsWorktree'], isTrue);
      }
    },
  );

  test('plan-and-implement discovery prompt excludes authored feature text', () async {
    const feature = 'FEATURE_SHOULD_NOT_APPEAR_IN_DISCOVERY_PROMPT';
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': feature,
        'PROJECT': 'demo-project',
        'BRANCH': 'feature/discovery-baseline',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => StubResponse(
            assistantContent: contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'plan': '',
              'story_specs': {'items': <Map<String, dynamic>>[]},
            }),
          ),
          'prd' => StubResponse(assistantContent: contextOutput({'prd': '# PRD\n\nDISCOVERY_SCOPE_PRD'})),
          'plan' => StubResponse(
            assistantContent: contextOutput({
              'stories': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Minimal Story',
                    'description': 'Verify discover prompt scope',
                    'acceptance_criteria': ['discover prompt stays narrow'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['README.md'],
                    'effort': 'small',
                  },
                ],
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Minimal Story',
                    'description': 'Verify discover prompt scope',
                    'acceptance_criteria': ['discover prompt stays narrow'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['README.md'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/discovery/fis/s01-minimal-story.md',
                  },
                ],
              },
            }),
          ),
          _ => planAndImplementCommonStub(queued, storyResult: 'STORY_RESULT'),
        };
      },
    );

    // discover-plan-state receives FEATURE via workflowVariables so it can
    // fast-path when the input resolves to a pre-authored PRD/plan file.
    final discover = trace.tasksForStep('discover-plan-state').single.description;
    expect(discover, contains("Use the 'dartclaw-discover-andthen-plan' skill."));
    expect(discover, contains(feature));
    expect(discover, isNot(contains('feature/discovery-baseline')));
  });

  test('plan-and-implement threads authored feature only into discovery', () async {
    const feature = 'Create exactly two thin note stories from this request.';
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {'FEATURE': feature, 'PROJECT': 'demo-project', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => StubResponse(
            assistantContent: jsonEncode({
              'framework': 'none',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': null},
              'state_protocol': {'type': 'none'},
            }),
          ),
          'prd' => StubResponse(
            assistantContent: contextOutput({
              'prd': 'docs/specs/demo/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 8,
            }),
          ),
          'plan' => StubResponse(
            assistantContent: contextOutput({
              'plan': 'docs/specs/demo/plan.md',
              'plan_source': 'synthesized',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Thin Story',
                    'spec_path': 'docs/specs/demo/fis/s01-thin-story.md',
                    'acceptance_criteria': ['prompt includes authored feature'],
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          _ => planAndImplementCommonStub(queued, storyResult: 'Implemented the thin story.'),
        };
      },
    );

    final discover = trace.tasksForStep('discover-plan-state').single.description;
    final plan = trace.tasksForStep('plan').single.description;

    // Discovery opts in to FEATURE as a path/context hint. The plan step
    // and all downstream steps must not receive the raw feature string.
    expect(discover, contains(feature));
    expect(plan, isNot(contains(feature)));
    expect(plan, isNot(contains('<FEATURE>')));
  });

  test('plan-and-implement normalizes relative story spec paths against the emitted plan path', () async {
    final trace = await driver.executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Normalize story spec paths',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => StubResponse(
            assistantContent: jsonEncode({
              'framework': 'none',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': null},
              'state_protocol': {'type': 'none'},
            }),
          ),
          'prd' => StubResponse(
            assistantContent: contextOutput({
              'prd': 'docs/specs/demo/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'plan' => StubResponse(
            assistantContent: contextOutput({
              'plan': 'docs/specs/demo/plan.md',
              'plan_source': 'synthesized',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'spec_path': 'fis/s01-story-one.md',
                    'acceptance_criteria': ['first passes'],
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          _ => planAndImplementCommonStub(queued),
        };
      },
    );

    final implementPrompt = trace.tasksForStep('implement').single.description;
    expect(implementPrompt, contains('docs/specs/demo/fis/s01-story-one.md'));
    expect(implementPrompt, isNot(contains('(story 1 of 1):')));
    expectReviewOutputDir(trace.descriptionsByStep['plan-review']!.single);
  });

  test(
    'plan-and-implement integration enters remediation when plan-review finds issues and exits after re-validation',
    () async {
      final trace = await driver.executeBuiltInWorkflow(
        workflowFileName: 'plan-and-implement.yaml',
        variables: {
          'FEATURE': 'Loop until findings are cleared',
          'PROJECT': 'demo-project',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-plan-state' => StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
                'marker': 'PLAN_DISCOVER_LOOP',
              }),
            ),
            'prd' => StubResponse(
              assistantContent: contextOutput({
                'prd': 'docs/specs/loop/prd.md',
                'prd_source': 'synthesized',
                'prd_confidence': 9,
              }),
            ),
            'plan' => StubResponse(
              assistantContent: contextOutput({
                'plan': 'docs/specs/loop/plan.md',
                'plan_source': 'synthesized',
                'stories': {
                  'items': [
                    {
                      'id': 'S01',
                      'title': 'Loop Story Alpha',
                      'description': 'First story for remediation loop',
                      'acceptance_criteria': ['alpha passes'],
                      'type': 'coding',
                      'dependencies': <String>[],
                      'key_files': ['lib/a.dart'],
                      'effort': 'small',
                    },
                    {
                      'id': 'S02',
                      'title': 'Loop Story Beta',
                      'description': 'Second story for remediation loop',
                      'acceptance_criteria': ['beta passes'],
                      'type': 'coding',
                      'dependencies': ['S01'],
                      'key_files': ['lib/b.dart'],
                      'effort': 'small',
                    },
                  ],
                },
                'story_specs': {
                  'items': [
                    {
                      'id': 'S01',
                      'title': 'Loop Story Alpha',
                      'description': 'First story for remediation loop',
                      'acceptance_criteria': ['alpha passes'],
                      'type': 'coding',
                      'dependencies': <String>[],
                      'key_files': ['lib/a.dart'],
                      'effort': 'small',
                      'spec_path': 'docs/specs/loop/fis/s01-loop-alpha.md',
                    },
                    {
                      'id': 'S02',
                      'title': 'Loop Story Beta',
                      'description': 'Second story for remediation loop',
                      'acceptance_criteria': ['beta passes'],
                      'type': 'coding',
                      'dependencies': ['S01'],
                      'key_files': ['lib/b.dart'],
                      'effort': 'small',
                      'spec_path': 'docs/specs/loop/fis/s02-loop-beta.md',
                    },
                  ],
                },
              }),
            ),
            'implement' => StubResponse(
              assistantContent: contextOutput({
                'story_result': 'LOOP_RESULT_${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
              }),
              worktreeJson: {
                'branch': queued.mapIndex == 0 ? 'loop-alpha' : 'loop-beta',
                'path': '/tmp/worktrees/${queued.mapIndex == 0 ? 'loop-alpha' : 'loop-beta'}',
                'createdAt': DateTime.now().toIso8601String(),
              },
            ),
            // Per-story review reports clean so the story-remediation loop's
            // entry gate skips it; the plan-level loop is what this test drives.
            'review-story' || 're-review-story' => StubResponse(
              assistantContent: contextOutput({'findings_count': 0, 'gating_findings_count': 0}),
            ),
            'remediate-story' => StubResponse(assistantContent: contextOutput({'remediation_summary': 'none'})),
            'plan-review' => StubResponse(
              assistantContent: contextOutput({
                ...reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: runtimeArtifactsDirForTask(queued.task, driver.tempDir.path),
                  findingsCount: 2,
                ),
                'implementation_summary': 'Batch needs remediation',
                'remediation_plan': 'Fix the lingering review findings',
                'needs_remediation': true,
              }),
            ),
            'plan-review-council' => StubResponse(
              assistantContent: contextOutput({
                'plan-review-council.findings_count': 0,
                'plan-review-council.gating_findings_count': 0,
              }),
            ),
            'remediate' => StubResponse(
              assistantContent: contextOutput({
                'remediation_summary': 'Remediated batch findings',
                'diff_summary': 'REMEDIATED_DIFF',
              }),
            ),
            're-review' => StubResponse(
              assistantContent: contextOutput({
                'remediation_plan': 'No further remediation needed',
                'findings_count': 0,
                're-review.findings_count': 0,
                'gating_findings_count': 0,
                're-review.gating_findings_count': 0,
              }),
            ),
            'update-state' => StubResponse(
              assistantContent: contextOutput({'state_update_summary': 'updated after remediation'}),
            ),
            'architecture-review' => StubResponse(
              assistantContent: contextOutput({
                'architecture-review.findings_count': 0,
                'architecture-review.gating_findings_count': 0,
              }),
            ),
            // simplify-code declares no outputs in plan-and-implement.yaml.
            'simplify-code' => StubResponse(assistantContent: contextOutput({})),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(trace.count('remediate'), 1);
      expect(trace.count('re-review'), 1);
    },
  );

  // A6: discovery/reuse/resume fast-path matrix. Each row drives the shipped
  // plan-and-implement graph with a distinct discover-plan-state payload and
  // asserts the resulting prd/plan/implement/plan-review step counts (plus the
  // implement-prompt path where the original test did). One row per original
  // behavioral case; a failing row names its scenario.
  group('plan-and-implement discovery/reuse/resume matrix', () {
    for (final row in _discoveryMatrix) {
      test('plan-and-implement ${row.name}', () async {
        final trace = await driver.executeBuiltInWorkflow(
          workflowFileName: 'plan-and-implement.yaml',
          variables: {'FEATURE': row.feature, 'PROJECT': 'demo-project', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
          responseForStep: (queued) async {
            switch (queued.stepKey) {
              case 'discover-plan-state':
                return StubResponse(assistantContent: contextOutput(row.discover));
              case 'prd':
                return StubResponse(
                  assistantContent: contextOutput({
                    'prd': 'docs/specs/reused/prd.md',
                    'prd_source': 'synthesized',
                    'prd_confidence': 9,
                  }),
                );
              case 'plan':
                return StubResponse(assistantContent: contextOutput(row.plan!));
              case 'plan-review':
                return StubResponse(
                  assistantContent: contextOutput({
                    ...reviewReportContext(
                      queued.stepKey,
                      runtimeArtifactsDir: runtimeArtifactsDirForTask(queued.task, driver.tempDir.path),
                      findingsCount: row.planReviewFindings,
                    ),
                  }),
                );
              default:
                return planAndImplementCommonStub(
                  queued,
                  branch: 'matrix-story',
                  worktreePath: '/tmp/worktrees/matrix-story',
                  remediationSummary: 'Fixed the reused-plan issue',
                  diffSummary: 'UPDATED_DIFF',
                );
            }
          },
        );

        expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: '${row.name}: run did not complete');
        expect(trace.count('prd'), row.expectPrd, reason: '${row.name}: prd count');
        expect(trace.count('plan'), row.expectPlan, reason: '${row.name}: plan count');
        expect(trace.count('implement'), row.expectImplement, reason: '${row.name}: implement count');
        expect(trace.count('plan-review'), row.expectPlanReview, reason: '${row.name}: plan-review count');
        if (row.expectQuickReview != null) {
          expect(trace.count('quick-review'), row.expectQuickReview, reason: '${row.name}: quick-review count');
        }
        if (row.expectSimplifyCode != null) {
          expect(trace.count('simplify-code'), row.expectSimplifyCode, reason: '${row.name}: simplify-code count');
        }
        if (row.expectRevisePrd != null) {
          expect(trace.count('revise-prd'), row.expectRevisePrd, reason: '${row.name}: revise-prd count');
        }
        if (row.expectRemediate != null) {
          expect(trace.count('remediate'), row.expectRemediate, reason: '${row.name}: remediate count');
        }
        if (row.expectReReview != null) {
          expect(trace.count('re-review'), row.expectReReview, reason: '${row.name}: re-review count');
        }
        if (row.planDescriptionContains != null) {
          expect(
            trace.descriptionsByStep['plan']!.single,
            contains(row.planDescriptionContains),
            reason: '${row.name}: plan description',
          );
        }
        if (row.implementPromptContains.isNotEmpty || row.implementPromptExcludes.isNotEmpty) {
          final implementPrompt = trace.tasksForStep('implement').single.description;
          for (final fragment in row.implementPromptContains) {
            expect(implementPrompt, contains(fragment), reason: '${row.name}: implement prompt contains $fragment');
          }
          for (final fragment in row.implementPromptExcludes) {
            expect(
              implementPrompt,
              isNot(contains(fragment)),
              reason: '${row.name}: implement prompt excludes $fragment',
            );
          }
        }
      });
    }
  });
}

class _DiscoveryRow {
  final String name;
  final String feature;
  final Map<String, Object?> discover;
  final Map<String, Object?>? plan;
  final int planReviewFindings;
  final int expectPrd;
  final int expectPlan;
  final int expectImplement;
  final int expectPlanReview;
  final int? expectQuickReview;
  final int? expectSimplifyCode;
  final int? expectRevisePrd;
  final int? expectRemediate;
  final int? expectReReview;
  final String? planDescriptionContains;
  final List<String> implementPromptContains;
  final List<String> implementPromptExcludes;

  const _DiscoveryRow({
    required this.name,
    required this.feature,
    required this.discover,
    this.plan,
    this.planReviewFindings = 0,
    required this.expectPrd,
    required this.expectPlan,
    required this.expectImplement,
    required this.expectPlanReview,
    this.expectQuickReview,
    this.expectSimplifyCode,
    this.expectRevisePrd,
    this.expectRemediate,
    this.expectReReview,
    this.planDescriptionContains,
    this.implementPromptContains = const [],
    this.implementPromptExcludes = const [],
  });
}

final List<_DiscoveryRow> _discoveryMatrix = [
  // reuses-PRD: an active PRD is reused as the flat handoff for the plan step.
  _DiscoveryRow(
    name: 'reuses an active PRD as the flat handoff for the plan step',
    feature: 'Reuse an existing PRD only',
    discover: {
      'prd': 'docs/specs/reused/prd.md',
      'plan': '',
      'story_specs': {'items': <Map<String, dynamic>>[]},
    },
    plan: {
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Planned Story',
            'spec_path': 'docs/specs/reused/fis/s01-planned-story.md',
            'dependencies': <String>[],
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 1,
    expectImplement: 1,
    expectPlanReview: 1,
    planDescriptionContains: 'docs/specs/reused/prd.md',
  ),
  // replans-empty-catalog: a markdown plan with an empty discovered story
  // catalog cannot prove every story is terminal, so the discovery skill emits
  // an empty `plan` (S01 final-payload contract) and the plan step re-runs.
  _DiscoveryRow(
    name: 'replans when an empty discovered story catalog is unproven',
    feature: 'Recover a reused plan without a discovered story catalog',
    discover: {
      'prd': 'docs/specs/reused/prd.md',
      // Unproven non-JSON plan: the skill blanks `plan` itself (no engine
      // normalization), so the entryGate fires on the empty value.
      'plan': '',
      'story_specs': {'items': <Map<String, dynamic>>[]},
    },
    plan: {
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Recovered Story',
            'spec_path': 'docs/specs/reused/fis/s01-recovered-story.md',
            'dependencies': <String>[],
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 1,
    expectImplement: 1,
    expectPlanReview: 1,
  ),
  // resumes-all-closed: an empty discovered story catalog over a JSON plan
  // means all stories are closed; no plan/story work runs, only plan-review.
  _DiscoveryRow(
    name: 'resumes all-closed plans without replanning or story work',
    feature: 'Resume a completed plan',
    discover: {
      'prd': 'docs/specs/closed/prd.md',
      'plan': 'docs/specs/closed/plan.json',
      'story_specs': {'items': <Map<String, dynamic>>[]},
    },
    expectPrd: 0,
    expectPlan: 0,
    expectImplement: 0,
    expectPlanReview: 1,
    expectQuickReview: 0,
    expectSimplifyCode: 0,
  ),
  // uses-PRD-when-only-plan: only an active plan path was discovered, but its
  // empty story catalog is unproven over a non-JSON plan, so the skill blanks
  // `plan` (S01 final-payload contract) and the markdown plan re-plans.
  _DiscoveryRow(
    name: 'uses the required PRD path when only an active plan path was discovered',
    feature: 'Recover a discovered plan path without an active PRD',
    discover: {
      'prd': 'docs/specs/test/prd.md',
      'plan': '',
      'story_specs': {'items': <Map<String, dynamic>>[]},
    },
    plan: {
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Recovered Story',
            'spec_path': 'docs/specs/reused/fis/s01-recovered-story.md',
            'dependencies': <String>[],
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 1,
    expectImplement: 1,
    expectPlanReview: 1,
  ),
  // reuses-executable-plan: a reused plan with an active story catalog is
  // executed directly; the plan step does not re-run.
  _DiscoveryRow(
    name: 'reuses an executable plan with discovered PRD fallback',
    feature: 'Repair a missing PRD while reusing an executable plan',
    discover: {
      'prd': 'docs/specs/test/prd.md',
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Existing Story',
            'spec_path': 'docs/specs/reused/fis/s01-existing-story.md',
            'dependencies': <String>[],
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 0,
    expectImplement: 1,
    expectPlanReview: 1,
  ),
  // normalizes-reused-paths: relative reused-plan story spec paths are resolved
  // against the discovered plan path before the implement prompt is rendered.
  _DiscoveryRow(
    name: 'normalizes reused-plan story spec paths against the discovered plan path',
    feature: 'Normalize reused-plan story spec paths',
    discover: {
      'prd': 'docs/specs/reused/prd.md',
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Relative Story',
            'spec_path': 'fis/s01-relative-story.md',
            'dependencies': <String>[],
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 0,
    expectImplement: 1,
    expectPlanReview: 1,
    implementPromptContains: ['docs/specs/reused/fis/s01-relative-story.md'],
    implementPromptExcludes: ['(story 1 of 1):'],
  ),
  // resume-emits-open-only: on resume the discovery skill omits done/skipped
  // stories (S01 ownership), so the catalog it emits carries only the open
  // story. The engine maps over exactly the emitted catalog — it no longer
  // re-filters by status (ADR-041) — so the single open story flows into
  // implement.
  _DiscoveryRow(
    name: 'implements exactly the open story catalog discovery emits on resume',
    feature: 'Resume a partially completed plan',
    discover: {
      'prd': 'docs/specs/resume/prd.md',
      'plan': 'docs/specs/resume/plan.json',
      'story_specs': {
        'items': [
          {
            'id': 'S03',
            'title': 'Open Story',
            'spec_path': 'docs/specs/resume/fis/s03-open-story.md',
            'dependencies': <String>[],
            'status': 'spec-ready',
          },
        ],
      },
    },
    expectPrd: 0,
    expectPlan: 0,
    expectImplement: 1,
    expectPlanReview: 1,
    implementPromptContains: ['docs/specs/resume/fis/s03-open-story.md'],
  ),
  // runs-plan-review-on-reused: a reused plan still runs the full plan-review
  // and enters remediation when review finds issues.
  _DiscoveryRow(
    name: 'still runs plan-review when the plan was reused from disk',
    feature: 'Execute a pre-authored plan',
    discover: {
      'prd': 'docs/specs/reused/prd.md',
      'plan': 'docs/specs/reused/plan.md',
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Existing Story',
            'description': 'Already planned story',
            'acceptance_criteria': ['passes review'],
            'type': 'coding',
            'dependencies': <String>[],
            'key_files': ['lib/existing.dart'],
            'effort': 'small',
            'spec_path': 'docs/specs/reused/fis/s01-existing-story.md',
          },
        ],
      },
    },
    planReviewFindings: 1,
    expectPrd: 0,
    expectPlan: 0,
    expectImplement: 1,
    expectPlanReview: 1,
    expectRevisePrd: 0,
    expectRemediate: 1,
    expectReReview: 1,
  ),
];
