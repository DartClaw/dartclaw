import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/workflow_list.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

const SidebarData _emptySidebar = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  showChannels: false,
  tasksEnabled: false,
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
  List<String> variableNames = const ['FEATURE', 'PROJECT'],
}) {
  return {
    'name': name,
    'description': description,
    'stepCount': stepCount,
    'hasLoops': hasLoops,
    'variableNames': variableNames,
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
    filters: filters ?? _makeFilters(),
  );
}

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('workflowListPageTemplate', () {
    test('renders without error with empty data', () {
      final html = _render();
      expect(html, contains('workflow-list-page'));
    });

    test('shows empty state when no runs', () {
      final html = _render();
      expect(html, contains('No workflow runs found'));
    });

    test('renders run cards when runs present', () {
      final html = _render(runs: [_makeRun()]);
      expect(html, contains('workflow-run-card'));
      expect(html, contains('spec-and-implement'));
    });

    test('renders status badge with correct class', () {
      final html = _render(runs: [_makeRun(status: 'running', statusBadgeClass: 'status-badge-running')]);
      expect(html, contains('status-badge-running'));
      expect(html, contains('Running'));
    });

    test('renders completed status badge', () {
      final html = _render(runs: [
        _makeRun(
          status: 'completed',
          statusLabel: 'Completed',
          statusBadgeClass: 'status-badge-completed',
        ),
      ]);
      expect(html, contains('status-badge-completed'));
      expect(html, contains('Completed'));
    });

    test('renders step progress in X/Y format', () {
      final html = _render(runs: [_makeRun(completedSteps: 3, totalSteps: 6)]);
      expect(html, contains('3'));
      expect(html, contains('6'));
      expect(html, contains('steps'));
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

    test('active filter button gets btn-active class', () {
      final html = _render(filters: _makeFilters(activeStatus: 'running'));
      expect(html, contains('btn-active'));
    });

    test('definition browser not shown when no definitions', () {
      final html = _render(definitions: []);
      expect(html, isNot(contains('workflow-definitions-section')));
    });

    test('definition browser shown when definitions present', () {
      final html = _render(definitions: [_makeDefinition()]);
      expect(html, contains('workflow-definitions-section'));
      expect(html, contains('spec-and-implement'));
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
      final html = _render(definitions: [
        _makeDefinition(variableNames: ['FEATURE', 'PROJECT']),
      ]);
      expect(html, contains('workflow-var-chip'));
      expect(html, contains('FEATURE'));
      expect(html, contains('PROJECT'));
    });

    test('renders definition select dropdown', () {
      final html = _render(
        filters: _makeFilters(definitionOptions: ['spec-and-implement', 'fix-bug']),
      );
      expect(html, contains('workflow-definition-filter'));
      expect(html, contains('spec-and-implement'));
      expect(html, contains('fix-bug'));
    });

    test('multiple runs rendered correctly', () {
      final html = _render(runs: [
        _makeRun(id: 'run-001', definitionName: 'spec-and-implement'),
        _makeRun(id: 'run-002', definitionName: 'fix-bug'),
      ]);
      expect(html, contains('spec-and-implement'));
      expect(html, contains('fix-bug'));
      expect(html, contains('/workflows/run-001'));
      expect(html, contains('/workflows/run-002'));
    });
  });
}
