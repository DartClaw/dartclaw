import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/workflow_detail.dart';
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
  );

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
    test('renders correct number of step cards', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(count: 4),
        contextEntries: const [],
        loopInfo: const [],
      );
      // Each step has a workflow-step-card element.
      final count = RegExp(r'workflow-step-card').allMatches(html).length;
      expect(count, 4);
    });

    test('progress bar: 0/6 -> 0%', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(),
        steps: makeSteps(count: 6, completedCount: 0),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('width: 0%'));
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

    test('error message rendered when errorMessage is non-null', () {
      final html = workflowDetailPageTemplate(
        sidebarData: emptySidebar,
        navItems: const [],
        run: makeRun(status: 'paused', errorMessage: 'Step failed: timeout'),
        steps: makeSteps(),
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('Step failed: timeout'));
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

    test('step icon CSS class matches step status', () {
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
        ],
        contextEntries: const [],
        loopInfo: const [],
      );
      expect(html, contains('workflow-step-icon--completed'));
    });
  });

  group('workflowStepDetailFragment', () {
    test('renders session section when messagesHtml provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: '<div class="msg">Hello</div>',
        artifacts: const [],
        contextInputs: const [],
        contextOutputs: const [],
      );
      expect(html, contains('workflow-step-chat'));
      expect(html, contains('<div class="msg">Hello</div>'));
    });

    test('renders no-session empty state when messagesHtml is null', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        artifacts: const [],
        contextInputs: const [],
        contextOutputs: const [],
      );
      expect(html, contains('No session started yet.'));
    });

    test('renders artifacts when provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        artifacts: [
          {'name': 'output.md', 'kindLabel': 'Document'},
        ],
        contextInputs: const [],
        contextOutputs: const [],
      );
      expect(html, contains('output.md'));
      expect(html, contains('Document'));
    });

    test('renders token count when provided', () {
      final html = workflowStepDetailFragment(
        messagesHtml: null,
        artifacts: const [],
        contextInputs: const [],
        contextOutputs: const [],
        tokenCount: 15000,
      );
      expect(html, contains('15,000'));
    });
  });
}
