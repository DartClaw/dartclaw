import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/tasks.dart';
import 'package:dartclaw_runtime/src/templates/workflow_list.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

final SidebarData _emptySidebar = (
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

Map<String, dynamic> _makeRun({
  String id = 'run-001',
  String definitionName = 'spec-and-implement',
  String status = 'running',
  String statusLabel = 'Running',
  String statusBadgeClass = 'status-badge-running',
  int completedSteps = 2,
  int totalSteps = 4,
  int progressPercent = 50,
  bool hasStepCount = true,
  String startedAtDisplay = '1h ago',
  String totalTokens = '12,000',
}) {
  return {
    'id': id,
    'definitionName': definitionName,
    'status': status,
    'statusLabel': statusLabel,
    'statusBadgeClass': statusBadgeClass,
    'completedSteps': completedSteps,
    'totalSteps': totalSteps,
    'progressPercent': progressPercent,
    'hasStepCount': hasStepCount,
    'dotClass': 'status-dot--live',
    'attention': false,
    'meterFillClass': '',
    'percentageClass': '',
    'startedAtIso': '2026-03-24T10:00:00Z',
    'startedAtDisplay': startedAtDisplay,
    'totalTokens': totalTokens,
    'href': '/workflows/$id',
  };
}

Map<String, dynamic> _makeDefinition({
  String name = 'spec-and-implement',
  String description = 'Full feature pipeline',
  int stepCount = 6,
  bool hasLoops = false,
  List<Map<String, dynamic>> variableHints = const [
    {'name': 'FEATURE', 'description': 'Feature to implement', 'required': true},
    {'name': 'PROJECT', 'description': 'Target project', 'required': false},
  ],
}) {
  return {
    'name': name,
    'description': description,
    'stepCount': stepCount,
    'hasLoops': hasLoops,
    'errorId': 'workflow-error-$name',
    'projectSelectId': 'workflow-project-$name',
    'variableHints': variableHints,
    'variableInputs': [
      for (final hint in variableHints)
        {
          'id': 'workflow-var-$name-${hint['name']}',
          'inputName': 'var_${hint['name']}',
          'label': hint['name'],
          'placeholder': hint['description'],
          'required': hint['required'],
          'defaultValue': '',
        },
    ],
  };
}

Map<String, dynamic> _makeFilters({
  String activeStatus = 'all',
  String? activeDefinition,
  List<String> statusOptions = const ['all', 'running', 'paused', 'completed', 'failed', 'cancelled'],
  List<String> definitionOptions = const [],
}) {
  return {
    'activeStatus': activeStatus,
    'activeDefinition': activeDefinition,
    'statusOptions': statusOptions,
    'definitionOptions': definitionOptions,
  };
}

String _render({
  List<Map<String, dynamic>> runs = const [],
  List<Map<String, dynamic>> definitions = const [],
  Map<String, dynamic>? filters,
}) {
  return workflowListPageTemplate(
    sidebarData: _emptySidebar,
    navItems: const [],
    runs: runs,
    definitions: definitions,
    projectOptions: const [],
    filters: filters ?? _makeFilters(),
  );
}

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('workflowListPageTemplate', () {
    test('renders without error with empty data', () {
      final html = _render();
      expect(html, contains('workflow-list-page'));
      expect(html, contains('class="content-area print-in"'));
      expect(html, contains('class="content-inner content-inner--wide workflow-list-page"'));
      expect(html, isNot(contains('page-content')));
      expect(html, isNot(contains('page-inner')));
    });

    test('workflow launch actions use the orchestration button tier', () {
      final html = _render(definitions: [_makeDefinition()]);

      expect(html, contains('<summary class="btn btn-secondary btn-sm btn-full">Run</summary>'));
      expect(html, contains('<button type="submit" class="btn btn-secondary btn-sm">Launch</button>'));
      expect(html, isNot(contains('onclick=')));
    });

    test('renders run cards when runs present', () {
      final html = _render(runs: [_makeRun(completedSteps: 3, totalSteps: 6)]);
      expect(html, contains('class="workflow-runs-stack"'));
      expect(html, contains('card run-card print-in'));
      expect(html, contains('spec-and-implement'));
      // The positive half of the S03 pair below: a known step count renders the
      // counts and the meter, so that case's two absences cannot be satisfied
      // by a template that emits neither for any run.
      expect(html, contains('<span>3</span>/<span>6</span> steps'));
      expect(html, contains('class="meter"'));
    });

    test('renders status badge with correct class', () {
      final html = _render(
        runs: [_makeRun(status: 'running', statusBadgeClass: 'status-badge-running')],
      );
      expect(html, contains('status-badge-running'));
      expect(html, contains('Running'));
    });

    test('renders completed status badge', () {
      final html = _render(
        runs: [_makeRun(status: 'completed', statusLabel: 'Completed', statusBadgeClass: 'status-badge-completed')],
      );
      expect(html, contains('status-badge-completed'));
      expect(html, contains('Completed'));
    });

    test('S03 unknown step count renders absent value without meter', () {
      final html = _render(runs: [_makeRun(hasStepCount: false, completedSteps: 0, totalSteps: 0)]);
      expect(html, contains('class="value-absent"'));
      expect(html, isNot(contains('class="meter"')));
    });

    test('renders run link to detail page', () {
      final html = _render(runs: [_makeRun(id: 'run-abc')]);
      expect(html, contains('/workflows/run-abc'));
    });

    test('renders started time display', () {
      final html = _render(runs: [_makeRun(startedAtDisplay: '2h ago')]);
      expect(html, contains('2h ago'));
    });

    test('renders all status filter buttons', () {
      final html = _render(filters: _makeFilters());
      expect(html, contains('Running'));
      expect(html, contains('Paused'));
      expect(html, contains('Completed'));
      expect(html, contains('Failed'));
    });

    test('active filter gets canonical active tab marker', () {
      final html = _render(filters: _makeFilters(activeStatus: 'running'));
      expect(html, contains('<nav class="tabs" aria-labelledby="workflow-status-filter-label">'));
      expect(html, contains('class="tab t-label active"'));
      expect(html, contains('aria-current="page"'));
    });

    test('definition browser uses the shared empty state when no definitions exist', () {
      final html = _render(definitions: []);
      expect(html, contains('workflow-definitions-section'));
      expect(html, contains('No workflows available'));
    });

    test('definition browser shown when definitions present', () {
      final html = _render(definitions: [_makeDefinition()]);
      expect(html, contains('workflow-definitions-section'));
      expect(html, contains('class="workflow-definition-card card"'));
      expect(html, contains('data-icon="workflow"'));
      expect(html, contains('<h3 class="workflow-definition-name t-heading">spec-and-implement</h3>'));
      expect(html, contains('spec-and-implement'));
    });

    test('definition cards include launch forms', () {
      final html = _render(definitions: [_makeDefinition()]);
      expect(html, contains('data-workflow-launch-form'));
      expect(html, contains('Run'));
      expect(html, contains('var_FEATURE'));
      expect(html, isNot(contains('onclick=')));
    });

    test('tasks dialog and workflows page embed the same launch fragment', () {
      final definitions = [_makeDefinition()];
      final shared = workflowDefinitionsFragment(definitions: definitions, projectOptions: const []);
      final page = _render(definitions: definitions);
      final dialog = taskCreateDialogFragment(
        goalOptions: const [],
        projectOptions: const [],
        workflowDefinitions: definitions,
      );

      expect(page, contains(shared));
      expect(dialog, contains(shared));
      expect(shared, contains('hx-post="/api/workflows/run-form"'));
    });

    test('launch forms expose required variables without blocking server validation', () {
      final html = _render(definitions: [_makeDefinition()]);
      final requiredVariableInput = RegExp(r'<input[^>]*name="var_FEATURE"[^>]*>').firstMatch(html)?.group(0);

      expect(requiredVariableInput, isNotNull);
      expect(requiredVariableInput, contains('aria-required="true"'));
      expect(requiredVariableInput, isNot(contains(' required')));
      expect(html, contains('id="workflow-error-spec-and-implement"'));
    });

    test('renders definition description', () {
      final html = _render(definitions: [_makeDefinition(description: 'Full feature pipeline')]);
      expect(html, contains('Full feature pipeline'));
    });

    test('renders definition step count', () {
      final html = _render(definitions: [_makeDefinition(stepCount: 6)]);
      expect(html, contains('6 steps'));
    });

    test('loop badge shown for definitions with loops', () {
      final html = _render(definitions: [_makeDefinition(hasLoops: true)]);
      expect(html, contains('workflow-loop-badge'));
    });

    test('loop badge not shown for definitions without loops', () {
      final html = _render(definitions: [_makeDefinition(hasLoops: false)]);
      expect(html, isNot(contains('workflow-loop-badge')));
    });

    test('variable chips rendered for definition variables', () {
      final html = _render(
        definitions: [
          _makeDefinition(
            variableHints: [
              {'name': 'FEATURE', 'description': 'Feature to implement', 'required': true},
              {'name': 'PROJECT', 'description': 'Target project', 'required': false},
            ],
          ),
        ],
      );
      expect(html, contains('workflow-var-chip'));
      expect(html, contains('class="chip workflow-var-chip"'));
      expect(html, contains('FEATURE'));
      expect(html, contains('PROJECT'));
    });

    test('variable chip title shows description hint', () {
      final html = _render(
        definitions: [
          _makeDefinition(
            variableHints: [
              {'name': 'FEATURE', 'description': 'Feature description to implement', 'required': true},
            ],
          ),
        ],
      );
      expect(html, contains('Feature description to implement'));
    });

    test('renders definition select dropdown', () {
      final html = _render(filters: _makeFilters(definitionOptions: ['spec-and-implement', 'fix-bug']));
      expect(html, contains('workflow-definition-filter'));
      expect(html, contains('spec-and-implement'));
      expect(html, contains('fix-bug'));
    });

    test('multiple runs rendered correctly', () {
      final html = _render(
        runs: [
          _makeRun(id: 'run-001', definitionName: 'spec-and-implement'),
          _makeRun(id: 'run-002', definitionName: 'fix-bug'),
        ],
      );
      expect(html, contains('spec-and-implement'));
      expect(html, contains('fix-bug'));
      expect(html, contains('/workflows/run-001'));
      expect(html, contains('/workflows/run-002'));
    });
  });
}
