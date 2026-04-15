import 'dart:io';

import 'package:test/test.dart';

void main() {
  final baseDir = File('packages/dartclaw_server/lib/src/static/app.js').existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';

  final scriptPath = '$baseDir/app.js';
  final componentsCssPath = '$baseDir/components.css';

  group('app.js HTMX SSE lifecycle', () {
    test('defines initSseLifecycle function', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('function initSseLifecycle()'));
    });

    test('listens for htmx:sseClose event', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('htmx:sseClose'));
    });

    test('defines dartclaw.handleTurnError', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('dartclaw.handleTurnError'));
    });

    test('finalizeTurn is shared by done and turn_error paths', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('function finalizeTurn()'));
      // Both htmx:sseClose handler and handleTurnError call finalizeTurn
      final calls = 'finalizeTurn()'.allMatches(source).length;
      expect(calls, greaterThanOrEqualTo(3)); // definition + sseClose + handleTurnError
    });

    test('handles failed HTMX requests by re-enabling input', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('htmx:afterRequest'));
      expect(source, contains('if (event.detail.successful)'));
      expect(source, contains('enableInput();'));
    });

    test('manual rename marks session as titled to prevent auto-title overwrite', () {
      final source = File(scriptPath).readAsStringSync();
      final matches = RegExp(r"dataset\.hasTitle\s*=\s*'true'").allMatches(source).length;
      expect(matches, greaterThanOrEqualTo(2));
    });

    test('archive flow preserves sidebar open state across OOB swap', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("const wasSidebarOpen = !!(sidebar && sidebar.classList.contains('open'));"));
      expect(source, contains('if (wasSidebarOpen) {'));
      expect(source, contains('setSidebarOpen(true);'));
    });

    test('toast and banner dismiss buttons use icon system markup', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('class="toast-dismiss" aria-label="Dismiss" data-icon="x"'));
      expect(source, contains('class="dismiss" aria-label="Dismiss" data-icon="x"'));
      expect(source, isNot(contains('class="toast-dismiss" aria-label="Dismiss">&times;')));
      expect(source, isNot(contains('class="dismiss" aria-label="Dismiss">&#10005;')));
    });
  });

  group('app.js no legacy EventSource code', () {
    test('does not contain native EventSource management', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, isNot(contains('activeSource')));
      expect(source, isNot(contains('parseSsePayload')));
      expect(source, isNot(contains('initSseConnectorHandling')));
      expect(source, isNot(contains('startStream(')));
      expect(source, isNot(contains('closeActiveStream')));
    });
  });

  group('app.js init idempotency guards', () {
    test('initThemeToggle checks dataset.themeInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('btn.dataset.themeInit'));
    });

    test('initSidebar guards menuToggle and scrim listeners', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('menuToggle.dataset.sidebarInit'));
      expect(source, contains('scrim.dataset.sidebarInit'));
    });

    test('initTextareaResize checks dataset.resizeInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('textarea.dataset.resizeInit'));
    });

    test('initSendButtonState checks dataset.sendInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('btn.dataset.sendInit'));
    });

    test('initInlineRename checks dataset.renameInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('input.dataset.renameInit'));
    });

    test('initKeyboardSubmit checks dataset.keyboardInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('textarea.dataset.keyboardInit'));
    });

    test('initSettingsForm checks dataset.settingsInit (in settings.js)', () {
      final source = File('$baseDir/settings.js').readAsStringSync();
      expect(source, contains('form.dataset.settingsInit'));
    });
  });

  group('app.js delete confirmation uses safe DOM API', () {
    test('confirmDeleteJob uses createElement not innerHTML for job name (in scheduling.js)', () {
      final source = File('$baseDir/scheduling.js').readAsStringSync();
      // Should use textContent and dataset for safe attribute assignment
      expect(source, contains("msg.textContent = \"Delete '\" + jobName"));
      expect(source, contains('confirmBtn.dataset.jobName = jobName'));
    });
  });

  group('memory dashboard (in memory.js)', () {
    test('initMemoryDefaultTab auto-loads active tab', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains('function initMemoryDefaultTab()'));
      expect(source, contains('switchMemoryTab(activeTab, tabId)'));
    });

    test('prune success uses htmx.ajax for immediate refresh', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains("htmx.ajax('GET', '/memory/content'"));
    });
  });

  group('app.js module split', () {
    test('page-specific module files exist', () {
      expect(File('$baseDir/settings.js').existsSync(), isTrue);
      expect(File('$baseDir/scheduling.js').existsSync(), isTrue);
      expect(File('$baseDir/memory.js').existsSync(), isTrue);
      expect(File('$baseDir/whatsapp.js').existsSync(), isTrue);
    });

    test('app.js does not contain extracted function bodies', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, isNot(contains('function initSettingsForm')));
      expect(source, isNot(contains('function toggleJobForm')));
      expect(source, isNot(contains('function switchMemoryTab')));
      expect(source, isNot(contains('function initQrFallback')));
    });

    test('settings.js contains settings functions', () {
      final source = File('$baseDir/settings.js').readAsStringSync();
      expect(source, contains('function initSettingsForm'));
      expect(source, contains('function activateSettingsTab'));
      expect(source, contains('function populateSettingsForm'));
      expect(source, contains('function handleFormSave'));
    });

    test('scheduling.js contains scheduling functions', () {
      final source = File('$baseDir/scheduling.js').readAsStringSync();
      expect(source, contains('function toggleJobForm'));
      expect(source, contains('function submitJobForm'));
      expect(source, contains('function editJob'));
      expect(source, contains('function confirmDeleteJob'));
      expect(source, contains('function cancelDeleteJob'));
    });

    test('memory.js contains memory functions', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains('function initMemoryDefaultTab'));
      expect(source, contains('function switchMemoryTab'));
      expect(source, contains('function applyMemoryViewMode'));
      expect(source, contains('function toggleMemoryView'));
      expect(source, contains('function confirmPrune'));
      expect(source, contains('function initMemoryViewToggle'));
    });

    test('whatsapp.js contains WhatsApp functions', () {
      final source = File('$baseDir/whatsapp.js').readAsStringSync();
      expect(source, contains('function initQrFallback'));
      expect(source, contains('function initQrCountdown'));
    });

    test('app.js uses typeof guards for page-specific init calls', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("typeof initSettingsForm === 'function'"));
      expect(source, contains("typeof initQrFallback === 'function'"));
      expect(source, contains("typeof initQrCountdown === 'function'"));
      expect(source, contains("typeof initMemoryDefaultTab === 'function'"));
      expect(source, contains("typeof initMemoryViewToggle === 'function'"));
      expect(source, contains("typeof toggleJobForm === 'function'"));
      expect(source, contains("typeof switchMemoryTab === 'function'"));
      expect(source, contains("typeof confirmPrune === 'function'"));
    });
  });

  group('app.js task page helpers', () {
    test('connects to task SSE and restores badge state after swaps', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("new EventSource('/api/tasks/events')"));
      expect(source, contains("fetch('/api/tasks/sidebar-state')"));
      expect(source, contains('let latestTaskReviewCount = null;'));
      expect(source, contains('function restoreTaskBadge()'));
      expect(source, contains('restoreTaskBadge();'));
    });

    test('only starts task SSE when the server advertises task support', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("if (taskEventSource || !document.querySelector('[data-tasks-enabled]')) return;"));
    });

    test('defines running sidebar rendering with cached active tasks', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('let cachedActiveTasks = [];'));
      expect(source, contains('function renderRunningSidebar(tasks) {'));
      expect(source, contains("const existing = document.getElementById('sidebar-running');"));
      expect(source, contains("const sidebar = document.getElementById('sidebar');"));
      expect(source, contains("container.id = 'sidebar-running';"));
      expect(source, contains("'<div class=\"sidebar-section-label sidebar-running-label\">Running</div>'"));
    });

    test('running sidebar removes the section when no active tasks remain', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('if (!cachedActiveTasks.length) {'));
      expect(source, contains('existing && existing.remove();'));
    });

    test('running sidebar renders task links, review labels, and elapsed timers', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("const href = '/tasks/' + taskId;"));
      expect(
        source,
        contains(
          "' hx-target=\"#main-content\" hx-select=\"#main-content\" hx-swap=\"outerHTML\" hx-push-url=\"true\"'",
        ),
      );
      expect(source, contains("' hx-select-oob=\"#topbar,#sidebar\">'"));
      expect(source, contains("? '<span class=\"running-review-label\">review</span>'"));
      expect(source, contains("? '<span class=\"task-elapsed running-elapsed\" data-started-at=\"' +"));
      expect(
        source,
        contains("'<span class=\"provider-badge provider-badge-' + provider + '\">' + providerLabel + '</span>'"),
      );
    });

    test('running sidebar re-renders after HTMX swaps and task SSE messages', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('refreshSidebarTaskState();'));
      expect(source, contains('renderRunningSidebar(cachedActiveTasks);'));
      expect(source, contains('renderRunningSidebar(data.activeTasks || []);'));
      expect(source, contains('if (Array.isArray(data.activeWorkflows)) {'));
      expect(source, contains('renderWorkflowSidebar(data.activeWorkflows);'));
      expect(
        RegExp(
          r"if \(data\.type === 'connected'\)[\s\S]*renderRunningSidebar\(data\.activeTasks \|\| \[\]\);",
        ).hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(
          r"if \(data\.type === 'task_status_changed'\)[\s\S]*renderRunningSidebar\(data\.activeTasks \|\| \[\]\);",
        ).hasMatch(source),
        isTrue,
      );
    });

    test('refreshes tasks content without forcing a full reload', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('async function refreshTasksPageContent()'));
      expect(source, contains('refreshTasksPageContent();'));
      expect(source, contains("headers: { 'HX-Request': 'true' }"));
    });

    test('task elapsed timers use a single managed interval', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('let taskElapsedTimer = null;'));
      expect(source, contains('clearInterval(taskElapsedTimer);'));
      expect(source, contains('function refreshTaskElapsedTimes()'));
    });

    test('sidebar task state refreshes from server after navigation and history restore', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('async function refreshSidebarTaskState()'));
      expect(source, contains("if (target && target.id === 'main-content') {"));
      expect(source, contains('refreshSidebarTaskState();'));
      expect(source, contains("document.body.addEventListener('htmx:historyRestore'"));
    });

    test('applyTaskFilters remains exposed on window', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('window.applyTaskFilters = function()'));
      expect(source, contains("window.location.href = '/tasks' + (qs ? '?' + qs : '');"));
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

    test('sidebar scrolls vertically instead of clipping overflow', () {
      final css = File(componentsCssPath).readAsStringSync();
      expect(css, contains('overflow-y: auto;'));
      expect(css, contains('overflow-x: hidden;'));
      expect(css, contains('overscroll-behavior: contain;'));
    });

    test('reduced motion disables pulsing status-dot animation', () {
      final css = File(componentsCssPath).readAsStringSync();
      expect(css, contains('@media (prefers-reduced-motion: reduce)'));
      expect(css, contains('.status-dot--live::before,'));
      expect(css, contains('.status-dot--live::after { animation: none; }'));
    });
  });

  group('system nav icon mappings', () {
    test('projects and workflows nav icons have explicit mask mappings', () {
      final css = File('$baseDir/icons.css').readAsStringSync();
      expect(css, contains('--icon-folder-git:'));
      expect(css, contains('--icon-workflow:'));
      expect(css, contains('[data-icon="folder-git"]::before'));
      expect(css, contains('[data-icon="workflows"]::before'));
    });

    test('desktop topbar hides the sidebar toggle despite generic btn-icon rules', () {
      final css = File('$baseDir/icons.css').readAsStringSync();
      expect(css, contains('.topbar .menu-toggle.btn-icon[data-icon]'));
      expect(css, contains('display: none;'));
      expect(css, contains('@media (max-width: 768px)'));
      expect(css, contains('display: inline-flex;'));
    });
  });
}
