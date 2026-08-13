import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/workflow_detail.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRunStatus;
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: false,
    tasksEnabled: false,
    activeSessionId: null,
  );

  test('S01/S04 run presentation covers every workflow status field', () {
    final expected = <WorkflowRunStatus, WorkflowRunPresentation>{
      WorkflowRunStatus.pending: (
        label: 'Pending',
        badgeClass: 'status-badge-pending',
        terminal: false,
        progressOverride: null,
        meterFillClass: '',
        percentageClass: '',
        dotClass: 'status-dot--idle',
        attention: false,
      ),
      WorkflowRunStatus.running: (
        label: 'Running',
        badgeClass: 'status-badge-running',
        terminal: false,
        progressOverride: null,
        meterFillClass: '',
        percentageClass: '',
        dotClass: 'status-dot--live',
        attention: false,
      ),
      WorkflowRunStatus.paused: (
        label: 'Paused',
        badgeClass: 'status-badge-paused',
        terminal: false,
        progressOverride: null,
        meterFillClass: 'meter-fill--warning',
        percentageClass: 'text-warning',
        dotClass: 'status-dot--warning',
        attention: false,
      ),
      WorkflowRunStatus.awaitingApproval: (
        label: 'Awaiting approval',
        badgeClass: 'status-badge-awaiting-approval',
        terminal: false,
        progressOverride: null,
        meterFillClass: 'meter-fill--warning',
        percentageClass: 'text-warning',
        dotClass: 'status-dot--attention',
        attention: true,
      ),
      WorkflowRunStatus.completed: (
        label: 'Completed',
        badgeClass: 'status-badge-completed',
        terminal: true,
        progressOverride: 100,
        meterFillClass: '',
        percentageClass: 'text-success',
        dotClass: 'status-dot--success',
        attention: false,
      ),
      WorkflowRunStatus.failed: (
        label: 'Failed',
        badgeClass: 'status-badge-failed',
        terminal: true,
        progressOverride: null,
        meterFillClass: 'meter-fill--error',
        percentageClass: 'text-error',
        dotClass: 'status-dot--error',
        attention: false,
      ),
      WorkflowRunStatus.cancelled: (
        label: 'Cancelled',
        badgeClass: 'status-badge-cancelled',
        terminal: true,
        progressOverride: null,
        meterFillClass: 'meter-fill--warning',
        percentageClass: 'text-warning',
        dotClass: 'status-dot--warning',
        attention: false,
      ),
    };
    expect(WorkflowRunStatus.values, hasLength(expected.length));
    for (final status in WorkflowRunStatus.values) {
      expect(workflowRunPresentation(status), expected[status], reason: status.name);
    }
  });

  test('S02 pipeline decoder normalizes aliases and signals unknown values', () {
    final cases = {
      'completed': 'pipeline-step--done',
      'skipped': 'pipeline-step--done',
      'running': 'pipeline-step--running',
      'failed': 'pipeline-step--failed',
      'rejected': 'pipeline-step--failed',
      'interrupted': 'pipeline-step--failed',
      'cancelled': 'pipeline-step--failed',
      'timed_out': 'pipeline-step--failed',
      'timed-out': 'pipeline-step--failed',
      'timedOut': 'pipeline-step--failed',
      'awaiting_approval': 'pipeline-step--blocked',
      'awaiting-approval': 'pipeline-step--blocked',
      'awaitingApproval': 'pipeline-step--blocked',
      'review': 'pipeline-step--blocked',
      'queued': 'pipeline-step--pending',
      'pending': 'pipeline-step--pending',
    };
    for (final entry in cases.entries) {
      expect(workflowStepPresentation('  ${entry.key}  ').className, entry.value, reason: entry.key);
    }
    for (final value in [null, '', 'future_status_v2']) {
      final presentation = workflowStepPresentation(value);
      expect(presentation.className, 'pipeline-step--failed');
      expect(presentation.label, 'Unknown status');
    }
  });

  test('S02 approval decoder covers aliases and explicit unknown fallback', () {
    final cases = {
      'pending': 'approval-card--waiting',
      'waiting': 'approval-card--waiting',
      'awaiting_approval': 'approval-card--waiting',
      'awaiting-approval': 'approval-card--waiting',
      'awaitingApproval': 'approval-card--waiting',
      'approved': 'approval-card--approved',
      'completed': 'approval-card--approved',
      'rejected': 'approval-card--rejected',
      'expired': 'approval-card--expired',
      'timed_out': 'approval-card--expired',
      'timed-out': 'approval-card--expired',
      'timedOut': 'approval-card--expired',
    };
    for (final entry in cases.entries) {
      expect(workflowApprovalPresentation(' ${entry.key} ').className, entry.value, reason: entry.key);
    }
    for (final value in [null, '', 'future_approval_state']) {
      expect(workflowApprovalPresentation(value).label, 'Unknown approval status');
    }
  });

  Map<String, dynamic> makeRun({
    String id = 'run-001',
    String definitionName = 'spec-and-implement',
    String status = 'running',
    String? errorMessage,
  }) {
    return {
      'id': id,
      'definitionName': definitionName,
      'status': status,
      'statusValue': WorkflowRunStatus.values.asNameMap()[status]!,
      'hasStepCount': true,
      'startedAt': '2026-03-24T10:00:00.000Z',
      'updatedAt': '2026-03-24T10:30:00.000Z',
      'completedAt': null,
      'totalTokens': 12000,
      'errorMessage': errorMessage,
    };
  }

  List<Map<String, dynamic>> makeSteps({int count = 3, int completedCount = 1}) {
    return List.generate(count, (i) {
      String status;
      if (i < completedCount) {
        status = 'completed';
      } else if (i == completedCount) {
        status = 'running';
      } else {
        status = 'pending';
      }
      return {
        'index': i,
        'id': 'step-$i',
        'name': 'Step ${i + 1}',
        'status': status,
        'type': 'research',
        'parallel': false,
        'taskId': i < completedCount ? 'task-$i' : null,
      };
    });
  }

  group('workflowDetailPageTemplate', () {
    test('renders the workflow run identifier', () {
      const runId = '123e4567-e89b-12d3-a456-426614174000';
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(id: runId),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('data-workflow-run-id'));
      expect(html, contains('>$runId</code>'));
    });

    test('renders correct number of step cards', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(count: 4),
        contextEntries: const [],
        loopInfo: const [],
      );
      final count = RegExp(r'class="pipeline-step ').allMatches(html).length;
      expect(count, 4);
      expect(html, contains('data-controller="dc-workflows"'));
      expect(html, contains('data-run-status="running"'));
      expect(html, contains('class="content-area print-in"'));
      expect(html, contains('class="content-inner content-inner--wide workflow-detail-page"'));
      expect(html, contains('class="workflow-step-detail" hidden="" id="step-detail-0"'));
    });

    test('progress meter keeps count and percentage labels', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(count: 6, completedCount: 0),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('width: 0%'));
      expect(html, contains('data-workflow-progress-label'));
      expect(html, contains('<span>0</span> / <span>6</span> steps complete'));
      expect(html, contains('class="workflow-progress-pct">0%</span>'));
    });

    test('why-paused banner: awaitingApproval names the pending step and its request', () {
      final run = makeRun(status: 'awaitingApproval');
      run['pendingApprovalStepId'] = 'plan-approval';
      run['contextJson'] = {'plan-approval.approval.message': 'Review the plan before build.'};
      final steps = [
        {
          'index': 0,
          'id': 'plan-approval',
          'name': 'Plan Approval',
          'status': 'awaiting_approval',
          'type': 'approval',
          'parallel': false,
          'taskId': null,
          'approval': {'message': 'Review the plan before build.'},
        },
      ];

      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: run,
        steps: steps,
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('workflow-pause-banner'));
      expect(html, contains('Awaiting approval'));
      expect(html, contains('<strong>Approval request</strong>:'));
      expect(html, contains('Plan Approval'));
      expect(html, contains('Review the plan before build.'));
    });

    test('why-paused banner: needsInput hold on a non-approval step surfaces its reason', () {
      final run = makeRun(status: 'awaitingApproval');
      run['pendingApprovalStepId'] = 'build';
      run['contextJson'] = {'build.approval.message': 'Need the target branch to proceed.'};
      final steps = [
        {
          'index': 0,
          'id': 'build',
          'name': 'Build',
          'status': 'awaiting_approval',
          'type': 'agent',
          'parallel': false,
          'taskId': null,
        },
      ];

      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: run,
        steps: steps,
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('workflow-pause-banner'));
      expect(html, contains('Build'));
      expect(html, contains('Need the target branch to proceed.'));
    });

    test('why-paused banner: generic paused run surfaces its reason', () {
      final run = makeRun(status: 'paused', errorMessage: 'Paused by operator.');

      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: run,
        steps: makeSteps(count: 2, completedCount: 1),
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('workflow-pause-banner'));
      expect(html, contains('Paused by operator.'));
    });

    test('why-paused banner: absent for a running run', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'running'),
        steps: makeSteps(count: 2),
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, isNot(contains('workflow-pause-banner')));
    });

    test('progress bar: 3/6 -> 50%', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(count: 6, completedCount: 3),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('width: 50%'));
    });

    test('progress bar counts skipped steps as progressed', () {
      final steps = [
        ...makeSteps(count: 2, completedCount: 2),
        {
          'index': 2,
          'id': 'step-2',
          'name': 'Step 3',
          'status': 'skipped',
          'type': 'research',
          'parallel': false,
          'taskId': null,
        },
        {
          'index': 3,
          'id': 'step-3',
          'name': 'Step 4',
          'status': 'pending',
          'type': 'research',
          'parallel': false,
          'taskId': null,
        },
      ];

      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: steps,
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('width: 75%'));
    });

    test('progress bar: 6/6 -> 100%', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'completed'),
        steps: makeSteps(count: 6, completedCount: 6),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('width: 100%'));
    });

    test('S03 unknown step count renders absent value without a meter', () {
      final run = makeRun(status: 'completed')..['hasStepCount'] = false;
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: run,
        steps: const [],
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('class="value-absent"'));
      expect(html, isNot(contains('class="meter"')));
      expect(html, isNot(contains('class="workflow-actions"')));
    });

    test('S04 completed overrides partial progress and failed uses error treatment', () {
      final completed = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'completed'),
        steps: makeSteps(count: 4, completedCount: 1),
        contextEntries: const [],
        loopInfo: const [],
      );
      final failed = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'failed'),
        steps: makeSteps(count: 4, completedCount: 1),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(completed, contains('width: 100%'));
      expect(failed, contains('meter-fill--error'));
      expect(failed, contains('text-error'));
    });

    test('Pause button shown for running status', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'running'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('Pause'));
    });

    test('Resume button shown for paused status', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'paused'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('Resume'));
    });

    test('no Pause/Resume/Cancel buttons for terminal status', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'completed'),
        steps: makeSteps(count: 3, completedCount: 3),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, isNot(contains('hx-post')));
    });

    test('failed run with errorMessage and no pause renders the error block', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'failed', errorMessage: 'Step failed: timeout'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('workflow-error-message'));
      expect(html, contains('Step failed: timeout'));
      expect(html, isNot(contains('workflow-pause-banner')));
    });

    test('cancelled approval run does not surface the stale hold reason as an error', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'cancelled', errorMessage: 'approval required: plan-approval'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, isNot(contains('workflow-error-message')));
      expect(html, isNot(contains('approval required: plan-approval')));
    });

    test('awaitingApproval run renders the pause banner, not the error block', () {
      // The awaitingApproval path sets errorMessage ("approval required: <step>");
      // the pause banner must own that message and the red error block stay hidden.
      final run = makeRun(status: 'awaitingApproval', errorMessage: 'approval required: plan-approval');
      run['pendingApprovalStepId'] = 'plan-approval';
      run['contextJson'] = {'plan-approval.approval.message': 'Review the plan before build.'};
      final steps = [
        {
          'index': 0,
          'id': 'plan-approval',
          'name': 'Plan Approval',
          'status': 'awaiting_approval',
          'type': 'approval',
          'parallel': false,
          'taskId': null,
          'approval': {'message': 'Review the plan before build.'},
        },
      ];

      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: run,
        steps: steps,
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('workflow-pause-banner'));
      expect(html, isNot(contains('workflow-error-message')));
    });

    test('awaitingApproval run without pending metadata falls back to its error', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'awaitingApproval', errorMessage: 'approval required: missing-step'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, isNot(contains('workflow-pause-banner')));
      expect(html, contains('workflow-error-message'));
      expect(html, contains('approval required: missing-step'));
    });

    test('no error section when errorMessage is null', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, isNot(contains('workflow-error-message')));
    });

    test('context viewer entries rendered', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(),
        contextEntries: [
          {'key': 'research_output', 'value': 'Some research findings', 'isLong': false},
        ],
        loopInfo: const [],
      );
      expect(html, contains('research_output'));
      expect(html, contains('Some research findings'));
      expect(html, contains('workflow-context-viewer'));
    });

    test('no context viewer when contextEntries is empty', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, isNot(contains('workflow-context-viewer')));
    });

    test('loop step shows iteration badge when loopInfo matches', () {
      final steps = [
        {
          'index': 0,
          'id': 'review',
          'name': 'Review',
          'status': 'running',
          'type': 'research',
          'parallel': false,
          'taskId': null,
        },
      ];
      final loopInfo = [
        {
          'loopId': 'review-loop',
          'stepIds': ['review'],
          'maxIterations': 3,
          'currentIteration': 2,
        },
      ];
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: steps,
        contextEntries: const [],
        loopInfo: loopInfo,
      );
      expect(html, contains('Iteration 2/3'));
      expect(html, contains('workflow-loop-badge'));
    });

    test('pipeline class and non-colour cue match step status', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: [
          {
            'index': 0,
            'id': 'step-0',
            'name': 'Done',
            'status': 'completed',
            'type': 'research',
            'parallel': false,
            'taskId': 'task-0',
          },
          {
            'index': 1,
            'id': 'step-1',
            'name': 'Interrupted',
            'status': 'interrupted',
            'type': 'research',
            'parallel': false,
            'taskId': 'task-1',
          },
        ],
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('pipeline-step--done'));
      expect(html, contains('pipeline-step--failed'));
      expect(html, contains('Failed'));
    });

    test('lazy step details expose terminal error and retry states', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: [
          {
            'index': 0,
            'id': 'step-0',
            'name': 'Research',
            'status': 'running',
            'type': 'research',
            'parallel': false,
            'taskId': 'task-0',
          },
        ],
        contextEntries: const [],
        loopInfo: const [],
      );

      expect(html, contains('htmx:responseError->dc-workflows#showStepDetailError'));
      expect(html, contains('htmx:sendError->dc-workflows#showStepDetailError'));
      expect(html, contains('intersect once, workflow-step-detail-retry'));
      expect(html, contains('data-step-detail-loading'));
      expect(html, contains('data-step-detail-error'));
      expect(html, contains('dc-workflows#retryStepDetail'));
    });
  });

  group('workflowStepDetailFragment', () {
    test('renders session section when messagesHtml provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: '<div class="msg">Hello</div>',
        stepName: 'Research',
        artifacts: const [],
        inputs: const [],
        outputKeys: const [],
      );
      expect(html, contains('workflow-step-chat'));
      expect(html, contains('<div class="msg">Hello</div>'));
      expect(html, contains('terminal-frame'));
      expect(html, contains('terminal-frame-bar'));
      expect(html, contains('terminal-frame-dots'));
      expect(html, contains('terminal-frame-body'));
      expect(html, contains('<span>Research</span>'));
      expect(html, isNot(contains('terminal-frame--crt')));
    });

    test('renders no-session empty state when messagesHtml is null', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        stepName: 'Research',
        artifacts: const [],
        inputs: const [],
        outputKeys: const [],
      );
      expect(html, contains('No session started yet.'));
      expect(html, contains('workflow-step-no-session'));
      expect(html, isNot(contains('terminal-frame')));
    });

    test('renders artifacts when provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        stepName: 'Research',
        artifacts: [
          {'name': 'output.md', 'kindLabel': 'Document'},
        ],
        inputs: const [],
        outputKeys: const [],
      );
      expect(html, contains('output.md'));
      expect(html, contains('Document'));
    });

    test('renders token count when provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        stepName: 'Research',
        artifacts: const [],
        inputs: const [],
        outputKeys: const [],
        tokenCount: 15000,
      );
      expect(html, contains('15,000'));
    });
  });
}
