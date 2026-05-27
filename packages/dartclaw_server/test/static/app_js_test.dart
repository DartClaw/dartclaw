import 'dart:io';

import 'package:test/test.dart';

void main() {
  final baseDir = File('packages/dartclaw_server/lib/src/static/controllers/index.js').existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';

  final componentsCssPath = '$baseDir/components.css';

  group('S04 legacy removal', () {
    test('legacy page scripts are removed', () {
      expect(File('$baseDir/tasks.js').existsSync(), isFalse);
      expect(File('$baseDir/workflows.js').existsSync(), isFalse);
      expect(File('$baseDir/settings.js').existsSync(), isFalse);
      expect(File('$baseDir/scheduling.js').existsSync(), isFalse);
      expect(File('$baseDir/memory.js').existsSync(), isFalse);
      expect(File('$baseDir/whatsapp.js').existsSync(), isFalse);
    });

    test('app.js is no longer loaded as the shell owner', () {
      expect(File('$baseDir/app.js').existsSync(), isFalse);
      final layoutSource = File('packages/dartclaw_server/lib/src/templates/layout.dart').existsSync()
          ? File('packages/dartclaw_server/lib/src/templates/layout.dart').readAsStringSync()
          : File('lib/src/templates/layout.dart').readAsStringSync();
      expect(layoutSource, isNot(contains('/static/app.js')));
    });

    test('Stimulus controllers include S04 migrations', () {
      final indexSource = File('$baseDir/controllers/index.js').readAsStringSync();
      expect(indexSource, contains("application.register('dc-whatsapp', DcWhatsappController);"));
      expect(indexSource, contains("application.register('dc-canvas-admin', DcCanvasAdminController);"));
      expect(indexSource, contains('Canvas standalone intentionally remains outside Stimulus'));
    });

    test('scheduling controller owns migrated behavior directly', () {
      final source = File('$baseDir/controllers/dc_scheduling_controller.js').readAsStringSync();
      expect(source, isNot(contains('dartclaw.pages')));
      expect(source, contains('submitJobForm(event)'));
      expect(source, contains('toggleScheduledTask(event)'));
      expect(source, contains("dataset.action = 'click->dc-scheduling#executeDeleteJob'"));
    });

    test('memory controller owns migrated behavior directly', () {
      final source = File('$baseDir/controllers/dc_memory_controller.js').readAsStringSync();
      expect(source, isNot(contains('dartclaw.pages')));
      expect(source, contains('switchTab(event)'));
      expect(source, contains('toggleView(event)'));
      expect(source, contains('confirmPrune(event)'));
      expect(source, contains("fetch('/api/memory/files/'"));
      expect(source, contains("htmx.ajax('GET', '/memory/content'"));
    });

    test('health controller refreshes the controller root marker', () {
      final source = File('$baseDir/controllers/dc_health_controller.js').readAsStringSync();
      expect(source, contains("this.element.matches('[data-health-refresh]')"));
      expect(source, contains("window.htmx.trigger(panel, 'refresh')"));
    });

    test('controllers do not depend on the removed page hook shim', () {
      expect(File('$baseDir/controllers/_page_hooks.js').existsSync(), isFalse);

      final controllerDir = Directory('$baseDir/controllers');
      for (final file in controllerDir.listSync().whereType<File>().where((file) => file.path.endsWith('.js'))) {
        final source = file.readAsStringSync();
        expect(source, isNot(contains('_page_hooks')));
        expect(source, isNot(contains('runNamedPageHook')));
        expect(source, isNot(contains('runAllPagesHook')));
        expect(source, isNot(contains('dartclaw.pages')));
      }
    });

    test('running sidebar rendering is shared outside page controllers', () {
      final tasksSource = File('$baseDir/controllers/dc_tasks_controller.js').readAsStringSync();
      final workflowsSource = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();
      final sharedSource = File('$baseDir/controllers/sidebar_sections.js').readAsStringSync();
      expect(tasksSource, isNot(contains('function renderRunningSidebar')));
      expect(workflowsSource, isNot(contains('function renderWorkflowSidebar')));
      expect(sharedSource, contains('updateRunningTasksSection'));
      expect(sharedSource, contains('updateRunningWorkflowsSection'));
    });

    test('shell and chat controllers own migrated behavior directly', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      final chatSource = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      expect(shellSource, contains('connectGlobalEvents()'));
      expect(shellSource, contains('initThemeToggle()'));
      expect(shellSource, contains('initSidebar()'));
      expect(shellSource, contains('initInlineRename()'));
      expect(chatSource, contains('handleBeforeRequest(event)'));
      expect(chatSource, contains('handleTurnError()'));
      expect(chatSource, contains('finalizeTurn()'));
    });

    test('projects controller owns project actions on direct page load', () {
      final source = File('$baseDir/controllers/dc_projects_controller.js').readAsStringSync();
      expect(source, contains('data-project-dialog-open'));
      expect(source, contains('data-project-fetch'));
      expect(source, contains('data-project-remove'));
      expect(source, contains('data-project-edit'));
      expect(source, contains("fetch('/api/projects'"));
    });

    test('tasks controller does not duplicate project action handlers', () {
      final source = File('$baseDir/controllers/dc_tasks_controller.js').readAsStringSync();
      expect(source, isNot(contains('initProjectHandlers')));
      expect(source, isNot(contains('[data-project-fetch]')));
      expect(source, isNot(contains('[data-project-remove]')));
      expect(source, isNot(contains('[data-project-edit]')));
      expect(source, isNot(contains('[data-project-dialog-open]')));
      expect(source, isNot(contains('[data-project-dialog-close]')));
    });
  });

  group('running sidebar styling', () {
    test('running items reuse live status dots and define review styling', () {
      final css = File(componentsCssPath).readAsStringSync();
      expect(css, contains('.sidebar-running-item .running-review-label'));
      expect(css, contains('.sidebar-running-item .running-elapsed'));
      expect(css, contains('.status-dot--live::before'));
      expect(css, contains('.status-dot--live::after'));
    });
  });
}
