import 'dart:io';

import 'package:test/test.dart';

void main() {
  final baseDir = File('packages/dartclaw_server/lib/src/static/controllers/index.js').existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';

  final componentsCssPath = '$baseDir/app.css';
  final designSystemCssPath = '$baseDir/design-system.css';

  group('S04 legacy removal', () {
    test('streaming cursor retains the canonical block glyph', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(appCss, isNot(contains('.streaming::after')));
      expect(designSystemCss, contains(".streaming::after {\n  content: '\\2588';"));
    });

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
    });

    test('scheduling controller owns migrated behavior directly', () {
      final source = File('$baseDir/controllers/dc_scheduling_controller.js').readAsStringSync();
      expect(source, isNot(contains('dartclaw.pages')));
      expect(source, contains('submitJobForm(event)'));
      expect(source, contains('toggleScheduledTask(event)'));
      expect(source, contains("dataset.action = 'click->dc-scheduling#executeDeleteJob'"));
      expect(source, contains('form.hidden = visible;'));
      expect(source, contains('form.hidden = false;'));
      expect(source, isNot(contains('form.style.display')));
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

    test('workflow lifecycle events reconcile the server-rendered detail page', () {
      final source = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();
      expect(source, contains('function refreshWorkflowDetail(owner)'));
      expect(source, contains("case 'connected':"));
      expect(source, contains("detailPage.getAttribute('data-run-status')"));
      expect(source, contains("htmx.ajax('GET', window.location.pathname + qs"));
      expect(source, contains("['completed', 'failed', 'cancelled'].includes(runStatus)"));
      expect(source, isNot(contains('let workflowEventSource')));
      expect(source, contains('owner.workflowEventSource'));
      expect(source, contains('if (owner) initWorkflowDetailSSE(owner)'));
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
      expect(chatSource, contains('finalizeTurn(options = {})'));
    });

    test('mobile menu toggle swaps its glyph in sync with open state', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      expect(shellSource, contains("menuToggle.setAttribute('data-icon', open ? 'x' : 'menu')"));
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

    test('navigation notification badges use hidden state', () {
      final tasksSource = File('$baseDir/controllers/dc_tasks_controller.js').readAsStringSync();
      final workflowsSource = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();

      expect(tasksSource, contains('badge.hidden = count <= 0;'));
      expect(workflowsSource, contains('badge.hidden = count <= 0;'));
      expect(tasksSource, isNot(contains('badge.style.display')));
      expect(workflowsSource, isNot(contains('badge.style.display')));
    });

    test('tasks controller handles turn wait state and early cancel', () {
      final source = File('$baseDir/controllers/dc_tasks_controller.js').readAsStringSync();
      expect(source, contains("data.type === 'turn_wait_state'"));
      expect(source, contains("'/api/sessions/' + encodeURIComponent(sessionId) + '/turn-status'"));
      expect(source, contains("'/turns/' + encodeURIComponent(turnId) + '/cancel'"));
      expect(source, contains("JSON.stringify({ reason: 'operator_cancel' })"));
      expect(source, contains('[data-turn-cancel]'));
      expect(source, contains('panel.hidden = !hasActiveTurn'));
      expect(source, contains("button.removeAttribute('data-turn-id')"));
    });

    test('chat controller stops turns through the turn-id cancel contract', () {
      final source = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      expect(source, contains("sessionPath + '/turn-status'"));
      expect(source, contains("sessionPath + '/turns/' + encodeURIComponent(status.turn_id) + '/cancel'"));
      expect(source, contains("JSON.stringify({ reason: 'operator_cancel' })"));
      expect(source, isNot(contains("fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/turn/stop'")));
    });

    test('feedback controllers use canonical loaders and progress primitives', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      final tasksSource = File('$baseDir/controllers/dc_tasks_controller.js').readAsStringSync();
      final chatSource = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      final memorySource = File('$baseDir/controllers/dc_memory_controller.js').readAsStringSync();
      final workflowSource = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();

      expect(shellSource, contains('class="claw-loader"'));
      expect(shellSource, isNot(contains('restart-spinner')));
      expect(tasksSource, contains('ensureMeter'));
      expect(tasksSource, contains('showScanBar'));
      expect(tasksSource, isNot(contains('task-progress-indeterminate')));
      expect(chatSource, contains('data-load-earlier-skeleton'));
      expect(chatSource, contains('#streaming-content .claw-loader'));
      expect(chatSource, contains("if (event.detail?.type === 'delta')"));
      expect(chatSource, isNot(contains("if (event.detail?.type !== 'delta') return")));
      expect(chatSource, contains('scrollToBottom(this.element);'));
      expect(memorySource, contains('skeleton skeleton-text'));
      expect(memorySource, isNot(contains("textContent = 'Loading...'")));
      expect(workflowSource, contains('loadingEl.hidden'));
      expect(workflowSource, isNot(contains('loadingEl.style.display')));
      expect(workflowSource, contains("section?.querySelector('.meter-fill')"));
      expect(workflowSource, isNot(contains("document.querySelector('.workflow-progress-fill')")));
      expect(workflowSource, contains("percentage.textContent = percent + '%'"));
    });

    test('workflow dialog feedback states use hidden and sized placeholders', () {
      final workflowSource = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(workflowSource, contains('loadingEl.hidden = false'));
      expect(workflowSource, contains('loadingEl.hidden = true'));
      expect(workflowSource, contains('emptyEl.hidden = false'));
      expect(workflowSource, contains('emptyEl.hidden = true'));
      expect(workflowSource, contains('formEl.hidden = false'));
      expect(workflowSource, contains('formEl.hidden = true'));
      expect(workflowSource, contains('projectEl.hidden = !hasProjectVar'));
      expect(appCss, contains('[hidden] { display: none !important; }'));
      expect(appCss, contains('.workflow-list-loading .skeleton { width: 100%; min-height: 4rem; }'));
      expect(appCss, contains('.pairing-status-row .scan-bar { flex: 0 0 min(6rem, 30%); }'));
    });
  });

  group('running sidebar styling', () {
    test('running items reuse live status dots and define review styling', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      expect(appCss, contains('.sidebar-running-item .running-review-label'));
      expect(appCss, contains('.sidebar-running-item .running-elapsed'));
      expect(designSystemCss, contains('.status-dot--live::before'));
      expect(designSystemCss, contains('.status-dot--live::after'));
    });

    test('shell uses shrinkable content tracks on desktop and mobile', () {
      final css = File(designSystemCssPath).readAsStringSync();
      expect(css, contains('grid-template-columns: var(--sidebar-w) minmax(0, 1fr);'));
      expect(css, contains('.shell { grid-template-columns: minmax(0, 1fr); }'));
    });
  });

  group('S13 identicons', () {
    test('shared utility computes and applies identicons behaviorally', () async {
      final sharedFile = File('$baseDir/controllers/shared.js').absolute;
      ProcessResult result;
      try {
        result = await Process.run('node', [
          '--input-type=module',
          '--eval',
          _identiconHarness,
          sharedFile.uri.toString(),
        ]);
      } on ProcessException {
        markTestSkipped('Node is unavailable');
        return;
      }

      expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
    });

    test('shared utility owns bounded identity variants without dependencies', () {
      final source = File('$baseDir/controllers/shared.js').readAsStringSync();

      expect(source, contains('export function identiconVariant(id)'));
      expect(source, contains('return (hash % 6) + 1;'));
      expect(source, contains('export function applyIdenticons(root = document)'));
      expect(source, isNot(contains("from './")));
    });

    test('shell reapplies identicons after swaps and history navigation', () {
      final source = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();

      expect(source, contains('applyIdenticons();'));
      expect(RegExp(r'handleAfterSwap[\s\S]*?applyIdenticons\(\);').hasMatch(source), isTrue);
      expect(RegExp(r'handleHistoryRestore[\s\S]*?applyIdenticons\(\);').hasMatch(source), isTrue);
      expect(RegExp(r'handleHistoryCacheMissLoad[\s\S]*?applyIdenticons\(\);').hasMatch(source), isTrue);
      expect(source, contains('list.hidden = isCollapsed;'));
      expect(source, contains('list.hidden = wasExpanded;'));
      expect(source, isNot(contains('list.style.display')));
    });

    test('sidebar entity actions retain mobile touch targets', () {
      final css = File(componentsCssPath).readAsStringSync();

      expect(css, contains('.session-item { padding: 0; }'));
      expect(css, contains('.session-item-link,'));
      expect(css, contains('.session-item .session-delete {\n    min-height: 48px;'));
      expect(css, contains('.session-item .session-delete { min-width: 48px; }'));
    });
  });

  test('task dialog backdrop mixes a theme token with transparency', () {
    final appCss = File(componentsCssPath).readAsStringSync();

    expect(appCss, contains('background: color-mix(in srgb, var(--bg-pit) 64%, transparent);'));
    expect(RegExp(r'\.task-dialog::backdrop\s*\{[^}]*var\(--bg-crust\)', dotAll: true).hasMatch(appCss), isFalse);
  });
}

const _identiconHarness = r'''
import { readFile } from 'node:fs/promises';

globalThis.window = {};
const source = await readFile(new URL(process.argv[1]), 'utf8');
const shared = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));

class FakeClassList {
  constructor(...names) {
    this.names = new Set(names);
  }

  add(...names) {
    names.forEach((name) => this.names.add(name));
  }

  remove(...names) {
    names.forEach((name) => this.names.delete(name));
  }

  [Symbol.iterator]() {
    return this.names[Symbol.iterator]();
  }
}

function mount(id, initials, ...classes) {
  return {
    classList: new FakeClassList('identicon', ...classes),
    dataset: { identiconId: id, identiconInitials: initials },
    textContent: '',
  };
}

const ids = ['', 'abc', 'arbitrary-entity-id'];
for (const id of ids) {
  const variant = shared.identiconVariant(id);
  if (!Number.isInteger(variant) || variant < 1 || variant > 6 || variant !== shared.identiconVariant(id)) {
    throw new Error('unstable or out-of-range variant for ' + JSON.stringify(id));
  }
}
const variants = new Set(Array.from({ length: 20 }, (_, index) => shared.identiconVariant('entity-' + index)));
if (variants.size < 2) throw new Error('distinct identities did not produce distinct variants');

const named = mount('entity-1', 'Alpha Name', 'identicon--1');
const fallback = mount('', '', 'identicon--6');
const root = { matches: () => false, querySelectorAll: () => [named, fallback] };
shared.applyIdenticons(root);
shared.applyIdenticons(root);

for (const item of [named, fallback]) {
  const variants = Array.from(item.classList).filter((name) => /^identicon--[1-6]$/.test(name));
  if (variants.length !== 1 || variants[0] !== 'identicon--' + shared.identiconVariant(item.dataset.identiconId)) {
    throw new Error('identicon variant was not idempotently applied');
  }
}
if (named.textContent !== 'AN') throw new Error('named initials were not derived');
if (fallback.textContent !== '?') throw new Error('fallback initials were not rendered');
''';
