import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

import 'controller_test_support.dart';

void main() {
  final baseDir = File('packages/dartclaw_server/lib/src/static/controllers/index.js').existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';

  final componentsCssPath = '$baseDir/app.css';
  final designSystemCssPath = '$baseDir/design-system.css';
  final tokensCssPath = '$baseDir/tokens.css';

  group('legacy static asset removal', () {
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

    test('Stimulus registers the WhatsApp controller', () {
      final indexSource = File('$baseDir/controllers/index.js').readAsStringSync();
      expect(indexSource, contains("application.register('dc-whatsapp', DcWhatsappController);"));
    });

    test('scheduling controller owns migrated behavior directly', () {
      final source = File('$baseDir/controllers/dc_scheduling_controller.js').readAsStringSync();
      expect(source, isNot(contains('dartclaw.pages')));
      expect(source, contains('submitJobForm(event)'));
      expect(source, contains('toggleScheduledTask(event)'));
      expect(source, contains("dataset.action = 'click->dc-scheduling#' + confirmAction"));
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

    test('mobile drawer exposes visible and assistive close controls', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      expect(shellSource, contains("menuToggle.setAttribute('data-icon', open ? 'x' : 'menu')"));
      expect(shellSource, contains("menuToggle.setAttribute('aria-expanded', String(open))"));
      expect(shellSource, contains("scrim.setAttribute('aria-hidden', String(!open))"));
      // Pointer-only scrim: it must not become a tab stop while the drawer is open.
      expect(shellSource, contains('scrim.tabIndex = -1'));
      expect(shellSource, isNot(contains('scrim.tabIndex = open')));
      expect(shellSource, contains("sidebarClose.addEventListener('click', () => this.setSidebarOpen(false))"));
      // Focus moves into the drawer and returns to the toggle, and the page
      // behind the scrim goes inert so Tab cannot reach it.
      expect(shellSource, contains("document.querySelector('.sidebar-close')?.focus()"));
      expect(shellSource, contains('menuToggle?.focus()'));
      expect(shellSource, contains("document.querySelector('.shell-main')"));
      expect(shellSource, contains("region?.toggleAttribute('inert', open)"));
      // Escape closes an open drawer before it reaches the custom-select handler.
      expect(shellSource, contains("if (document.getElementById('sidebar')?.classList.contains('open'))"));
      // The persistent restart slot must survive the generic one-shot banner sweeper.
      expect(shellSource, contains("!event.target.closest('#restart-banner-slot')"));
      // Navigating from an open drawer replaces #sidebar out-of-band without any
      // .open class, so the inert boundary must be re-derived after every swap
      // and whenever the drawer breakpoint stops matching — otherwise
      // .menu-toggle is stranded inside the region it would have to un-inert.
      // Settle, not swap: the OOB #sidebar still carries the old .open class at
      // every afterSwap, so an earlier reconcile reads a stale open drawer.
      expect(shellSource, contains('this.reconcileDrawerState();'));
      expect(
        shellSource.indexOf('this.reconcileDrawerState();'),
        greaterThan(shellSource.indexOf('handleAfterSettle() {')),
      );
      expect(shellSource, contains('handleDrawerViewportChange'));
      expect(shellSource, contains("window.matchMedia('(max-width: 768px)')"));
    });

    test('projects controller owns project actions on direct page load', () {
      final source = File('$baseDir/controllers/dc_projects_controller.js').readAsStringSync();
      expect(source, contains('data-project-dialog-open'));
      expect(source, contains('data-project-fetch'));
      expect(source, contains('data-project-remove'));
      expect(source, contains('data-project-edit'));
      expect(source, contains("fetch('/api/projects'"));
      expect(source, isNot(contains('window.location.reload()')));
      expect(source, contains("target: '#projects-content'"));
      expect(source, contains("select: '#projects-content'"));
      expect(RegExp(r"refreshProjects\('Project (added|updated|fetched|removed)'\)").allMatches(source), hasLength(4));
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
      expect(source, contains('activeTurnStates.has(state)'));
      expect(source, contains('button.hidden = !hasActiveTurn || data.can_cancel !== true'));
      expect(source, contains("button.removeAttribute('data-turn-id')"));
    });

    test('chat controller stops turns through the turn-id cancel contract', () {
      final source = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      expect(source, contains("sessionPath + '/turn-status'"));
      expect(source, contains("sessionPath + '/turns/' + encodeURIComponent(status.turn_id) + '/cancel'"));
      expect(source, contains("JSON.stringify({ reason: 'operator_cancel' })"));
      expect(source, isNot(contains("fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/turn/stop'")));
    });

    test('chat title and send mutations synchronously retire draft reuse', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      final chatSource = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();

      expect(shellSource, contains('beginSessionDraftMutation(sessionId)'));
      expect(shellSource, contains('endSessionDraftMutation(sessionId)'));
      expect(chatSource, contains('beginSessionDraftMutation(this.sessionId)'));
      expect(chatSource, contains('endSessionDraftMutation(this.sessionId)'));
      expect(shellSource, contains("'dartclaw:session-draft-mutation-complete'"));
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
      // The pre-stream state is canon's composed .msg-thinking object, and it
      // yields to the block cursor on the first delta so the two never coexist.
      expect(chatSource, contains(".querySelector('.msg-thinking')?.remove()"));
      expect(chatSource, contains("classList.add('streaming')"));
      expect(chatSource, isNot(contains('#streaming-content .claw-loader')));
      expect(chatSource, contains("if (event.detail?.type === 'delta')"));
      expect(chatSource, isNot(contains("if (event.detail?.type !== 'delta') return")));
      // Auto-scroll is intent-driven: no call may re-anchor unconditionally.
      expect(chatSource, contains('scrollToBottom(this.element, { force: true })'));
      expect(chatSource, isNot(contains('scrollToBottom(this.element);')));
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
    });

    test('pairing progress bars are independently centered', () {
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(
        appCss,
        contains(
          '.pairing-status-row {\n'
          '  display: flex; flex-direction: column; align-items: center; gap: var(--sp-2); text-align: center;\n'
          '}',
        ),
      );
      expect(appCss, contains('.pairing-status-row .scan-bar { flex: 0 0 auto; width: min(6rem, 30%); }'));
    });

    test('dynamic forms compose canonical labels and workflow action hierarchy', () {
      final settingsSource = File('$baseDir/controllers/dc_settings_controller.js').readAsStringSync();
      final workflowSource = File('$baseDir/controllers/dc_workflows_controller.js').readAsStringSync();

      expect(settingsSource, isNot(contains("className = 'form-label t-label'")));
      expect(settingsSource, contains("className = 'form-label t-caption tracking-caps'"));
      expect(workflowSource, isNot(contains('class="form-label t-label"')));
      expect(workflowSource, contains('class="form-label t-caption tracking-caps"'));
      expect(workflowSource, contains("const controlId = 'workflow-var-' + index"));
      expect(workflowSource, contains('id="\' + controlId + \'" name="wf-var-'));
      expect(workflowSource, contains('for="\' + controlId + \'">'));
      expect(workflowSource, contains("submitBtn.classList.toggle('btn-secondary', target === 'workflow')"));
      expect(workflowSource, contains("submitBtn.classList.toggle('btn-primary', target !== 'workflow')"));
      expect(workflowSource, contains("submitBtn.classList.remove('btn-secondary')"));
      expect(workflowSource, contains("submitBtn.classList.add('btn-primary')"));
    });

    test('sidebar creation action is a quiet full-width command below Chats', () {
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      final iconsCss = File('$baseDir/icons.css').readAsStringSync();
      final sidebarTemplatePath = baseDir.startsWith('lib/')
          ? 'lib/src/templates/sidebar.html'
          : 'packages/dartclaw_server/lib/src/templates/sidebar.html';
      final sidebarSource = File(sidebarTemplatePath).readAsStringSync();
      final sidebarSectionsSource = File('$baseDir/controllers/sidebar_sections.js').readAsStringSync();

      expect(sidebarSource, contains('class="sidebar-body"'));
      expect(sidebarSource, contains('class="sidebar-chat-section"'));
      expect(sidebarSource, contains('type="button" class="btn-new-session"'));
      expect(sidebarSource, contains('class="btn-new-session-icon" data-icon="new-session"'));
      expect(sidebarSource, contains('class="sidebar-chat-divider"'));
      expect(sidebarSource, isNot(contains('sidebar-section-heading')));
      expect(
        RegExp(
          r'\.btn-new-session\s*\{[^}]*width:\s*calc\(100% - \(2 \* var\(--sp-2\)\)\);[^}]*min-height:\s*40px;'
          r'[^}]*border:\s*1px solid transparent;[^}]*background:\s*transparent;',
        ).hasMatch(designSystemCss),
        isTrue,
      );
      expect(designSystemCss, contains('.btn-new-session:hover { background: var(--bg-surface0); }'));
      expect(designSystemCss, contains('.btn-new-session:disabled { cursor: wait; opacity: 0.6; }'));
      expect(designSystemCss, contains('.btn-new-session:focus-visible {'));
      expect(designSystemCss, contains('.btn-new-session { min-height: 48px; }'));
      expect(designSystemCss, contains('.sidebar-body { overflow: hidden; }'));
      expect(designSystemCss, contains('.sidebar-body .session-list { flex: 1; min-height: 0; overflow-y: auto; }'));
      expect(sidebarSectionsSource, contains("sidebar.querySelector('.sidebar-chat-section')"));
      expect(sidebarSectionsSource, contains('workflowSection || chatsSection'));
      expect(iconsCss, contains('[data-icon="server"]::before'));
      expect(iconsCss, contains('[data-icon="chevron-up"]::before'));
    });

    test('system active indicator clears rounded window corners', () {
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(RegExp(r'\.sidebar-system-trigger\s*\{[^}]*position:\s*relative;').hasMatch(designSystemCss), isTrue);
      expect(
        RegExp(
          r'\.sidebar-system-menu:has\(\.sidebar-nav-item\.active\)\s*>\s*\.sidebar-system-trigger\s*\{'
          r'[^}]*border-left-color:',
        ).hasMatch(designSystemCss),
        isFalse,
      );
      expect(
        RegExp(
          r'\.sidebar-system-menu:has\(\.sidebar-nav-item\.active\)\s*>\s*\.sidebar-system-trigger::before\s*\{'
          r'[^}]*top:\s*50%;[^}]*left:\s*var\(--sp-2\);'
          r'[^}]*width:\s*3px;[^}]*height:\s*16px;[^}]*transform:\s*translateY\(-50%\);'
          r'[^}]*border-radius:\s*999px;[^}]*background:\s*var\(--accent\);',
        ).hasMatch(designSystemCss),
        isTrue,
      );
    });

    test('system panel active item uses the notch, not the flush edge', () {
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(
        designSystemCss,
        contains('.sidebar-system-panel .sidebar-nav-item.active { border-left-color: transparent; }'),
      );
      expect(
        RegExp(
          r'\.sidebar-system-panel \.sidebar-nav-item\.active::after\s*\{'
          r'[^}]*top:\s*50%;[^}]*left:\s*var\(--sp-1\);'
          r'[^}]*width:\s*3px;[^}]*height:\s*16px;[^}]*transform:\s*translateY\(-50%\);'
          r'[^}]*border-radius:\s*999px;[^}]*background:\s*var\(--accent\);',
        ).hasMatch(designSystemCss),
        isTrue,
      );
    });

    test('mobile sidebar disclosures share the 48px touch floor', () {
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(appCss, contains('@media (max-width: 768px) {\n  .sidebar-archive-toggle { min-height: 48px; }'));
    });

    test('light theme uses visible Aurora washes without sacrificing muted-text contrast', () {
      final tokensCss = File(tokensCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      final lightTheme = tokensCss.substring(tokensCss.indexOf('[data-theme="light"]'));

      expect(lightTheme, contains('--ambient-a: color-mix(in srgb, #1e66f5 14%, transparent);'));
      expect(lightTheme, contains('--ambient-b: color-mix(in srgb, var(--mauve) 13%, transparent);'));
      expect(lightTheme, contains('--ambient-c: color-mix(in srgb, #179299 12%, transparent);'));
      expect(lightTheme, contains('--ambient-d: color-mix(in srgb, #40a02b 10%, transparent);'));
      expect(lightTheme, contains('--glass-bg: color-mix(in srgb, #ffffff 66%, transparent);'));
      expect(lightTheme, contains('--bg-base:     #e4e7ef;'));
      expect(lightTheme, contains('--bg-ground-edge: color-mix(in oklab, var(--bg-base) 98%, var(--bg-crust));'));
      expect(lightTheme, contains('--fg-sub0:     #565b71;'));
      expect(lightTheme, contains('--fg-overlay:  #50556b;'));
      expect(lightTheme, isNot(contains('--ambient-a: color-mix(in oklab, var(--bg-mantle)')));

      // The coloured portions are spatially disjoint. Pinning their geometry
      // keeps per-wash contrast checks representative of the rendered ground.
      expect(
        designSystemCss,
        contains('radial-gradient(ellipse 70% 58% at 85% -6%, var(--ambient-a), transparent 74%)'),
      );
      expect(
        designSystemCss,
        contains('radial-gradient(ellipse 62% 50% at 42% 40%, var(--ambient-b), transparent 74%)'),
      );
      expect(
        designSystemCss,
        contains('radial-gradient(ellipse 60% 50% at 92% 98%, var(--ambient-c), transparent 74%)'),
      );
      expect(
        designSystemCss,
        contains('radial-gradient(ellipse 44% 38% at 3% -4%, var(--ambient-d), transparent 72%)'),
      );

      // One channel below the rounded 98/2 ground-edge mix is a conservative
      // bound for its unrounded darkest endpoint beneath every wash.
      const ground = '#e3e6ee';
      const mutedTexts = ['#565b71', '#50556b'];
      for (final wash in const [('#1e66f5', 0.14), ('#8839ef', 0.13), ('#179299', 0.12), ('#40a02b', 0.10)]) {
        for (final mutedText in mutedTexts) {
          expect(_contrastRatio(_mixHex(wash.$1, ground, wash.$2), mutedText), greaterThanOrEqualTo(4.5));
        }
      }
    });

    test('app CSS does not shadow canonical message treatments', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      for (final selector in ['msg-user', 'msg-assistant']) {
        final definition = RegExp('^\\.$selector\\s*\\{', multiLine: true);
        expect(definition.allMatches(appCss), isEmpty, reason: selector);
        expect(definition.allMatches(designSystemCss), hasLength(1), reason: selector);
      }
    });

    test('mobile form and composer floors use fixed accessible dimensions', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(designSystemCss, contains('.input-area textarea { min-height: 48px; font-size: 16px; }'));
      expect(designSystemCss, contains('.input-area .btn-send { min-height: 48px; }'));
      expect(designSystemCss, contains('.btn { min-width: 48px; min-height: 48px; }'));
      expect(designSystemCss, contains('.sidebar-nav-item { min-height: 48px; }'));
      expect(designSystemCss, contains('label.form-field--checkbox { min-height: 48px; }'));
      // Height only on the bare rule: a min-width floor stretches narrow inline
      // chips that happen to be buttons. Square targets set their own width.
      expect(appCss, contains('button,\n  summary,\n  [role="button"] {\n    min-height: 48px;\n  }'));
      expect(appCss, contains('.topbar .menu-toggle,\n  .theme-toggle {\n    width: 48px;'));
      // `.btn-icon-sm` is canon's tier now, so canon's own `.btn` floor (asserted
      // above) owns its mobile target — which only reaches the icon buttons
      // because they carry the base class. Assert that half too; either alone
      // passes vacuously.
      final schedulingHtml = File('${baseDir.replaceFirst('/static', '/templates')}/scheduling.html')
          .readAsStringSync();
      expect(RegExp(r'class="btn-icon-sm').hasMatch(schedulingHtml), isFalse);
      expect(RegExp(r'class="btn btn-icon-sm').allMatches(schedulingHtml), hasLength(7));
      // Anchors get no floor from the bare `button` rule, so they are named as
      // one intent-based list. The three class-name lists this replaced each
      // missed the tab and pager anchors, which is how those shipped at 28px.
      expect(appCss, contains(':is(.topbar-back, .card-link, .guard-audit-link, .tabs a.tab, .pager a) {'));
      // The toggle is canon's `.form-toggle` now, and canon carries its mobile
      // floor: the box grows to 48px while the slider stays 36x20 centred.
      expect(designSystemCss, contains('.form-toggle {\n    min-width: 48px;\n    min-height: 48px;\n  }'));
      expect(designSystemCss, contains('.tab { min-height: 48px; }'));
      expect(RegExp(r'^\.toggle-(switch|slider)\b', multiLine: true).hasMatch(appCss), isFalse);
      expect(appCss, contains('.login-input,\n  .login-checkbox {\n    min-height: 48px;'));
      expect(appCss, isNot(contains('.btn-sm.btn-primary {')));
      expect(appCss, isNot(contains('.btn-sm.btn-danger {')));
      expect(RegExp(r'^\.metric-(value|label)\s*\{', multiLine: true).hasMatch(appCss), isFalse);
      expect(appCss, isNot(contains('.input-area textarea:focus {')));
      expect(appCss, isNot(contains('*, *::before, *::after {')));
      // Anchored: app CSS must not re-declare canon's live-dot treatment. The
      // `.shell[data-connection="lost"]` descendant rule is a state gate over
      // canon's animation, not a second definition of it.
      expect(RegExp(r'^\.status-dot--live::before', multiLine: true).hasMatch(appCss), isFalse);
      expect(designSystemCss, contains('.pipeline-step--failed .pipeline-node'));
      expect(appCss, contains('.well-content .form-select {\n    font-size: 16px;'));
      // The dialogs' 48px control floor survives the canon swap keyed on the
      // preserved dialog ids — canon floors no control, so nothing else owns it.
      // Both bind the declaration: the same selector heads also open the base
      // 44px block, so a selector-only check passes with the floor deleted.
      expect(RegExp(r'#new-task-dialog \.form-input,[^}]*min-height: 48px;').hasMatch(appCss), isTrue);
      expect(RegExp(r'#add-project-dialog \.form-select \{\s*\n\s*min-height: 48px;').hasMatch(appCss), isTrue);
    });

    test('design tokens resolve to their declared type and spacing scale', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      final tokensCss = File(tokensCssPath).readAsStringSync();

      expect(tokensCss, contains('--font-sans: system-ui, -apple-system, BlinkMacSystemFont'));
      expect(tokensCss, contains('--text-lg:   1rem;        /* 16px — section headings */'));
      expect(tokensCss, contains('--text-xl:   1.125rem;    /* 18px — page title */'));
      expect(tokensCss, contains('--text-2xl:  1.25rem;     /* 20px — hero/page-level display */'));
      expect(tokensCss, contains('--text-3xl:  1.5rem;      /* 24px — metric values, big numbers */'));
      expect(tokensCss, contains('--leading:       1.5;'));
      expect(tokensCss, contains('--measure:        65ch;'));
      expect(designSystemCss, contains('html {\n  font-family: var(--font-sans);\n  font-size: 16px;'));
      expect(designSystemCss, contains('code, pre, kbd, samp { font-family: var(--font-mono); }'));
      expect(designSystemCss, contains('font-size: var(--text-base);\n  min-height: 100dvh;'));
      expect(designSystemCss, contains('.card-title { font: inherit; }'));
      expect(appCss, contains('grid-template-columns: minmax(0, 1fr);'));
      expect(appCss, contains('font-size: var(--text-base);\n  font-weight: var(--weight-medium);'));
    });

    test('settings use full-width panes and a single-row responsive tab strip', () {
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      final settingsSource = File('$baseDir/controllers/dc_settings_controller.js').readAsStringSync();

      expect(appCss, contains('.settings-grid { display: grid; grid-template-columns: minmax(0, 1fr);'));
      // The strip is canon's single `.tabs` component now; app.css re-implements none of it.
      expect(RegExp(r'\.tabs\s*\{[^}]*overflow-x:\s*auto;').hasMatch(designSystemCss), isTrue);
      expect(RegExp(r'\.tabs\s*\{[^}]*flex-wrap:\s*nowrap;').hasMatch(designSystemCss), isTrue);
      expect(RegExp(r'\.tab\s*\{[^}]*flex:\s*0 0 auto;').hasMatch(designSystemCss), isTrue);
      expect(RegExp(r'\.tabs\s*\{[^}]*grid-template-columns').hasMatch(designSystemCss), isFalse);
      expect(designSystemCss, contains('scrollbar-color: var(--fg-sub0) transparent;'));
      expect(
        RegExp(r'\.tabs::\-webkit-scrollbar-thumb\s*\{[^}]*background:\s*var\(--fg-sub0\);').hasMatch(designSystemCss),
        isTrue,
      );
      expect(
        RegExp(r'\.tabs::after\s*\{[^}]*width:\s*var\(--sp-5\);[^}]*color-mix\(in srgb, var\(--fg\) 24%, transparent\)')
            .hasMatch(designSystemCss),
        isTrue,
      );
      expect(RegExp(r'^\.settings-tabs?\b', multiLine: true).hasMatch(appCss), isFalse);
      expect(appCss, isNot(contains('.restart-required-badge')));
      // Same intent as the retired `aria-current` assertion: the active tab is
      // announced and scrolled into view. `aria-current="page"` announced an
      // in-page panel switch as a navigation, so the state moved to the tab
      // widget's own hooks plus a roving tabindex.
      expect(
        RegExp(
          r"t\.setAttribute\('aria-selected', active \? 'true' : 'false'\);.*?"
          r"t\.setAttribute\('tabindex', active \? '0' : '-1'\);.*?"
          r"t\.scrollIntoView\(\{block: 'nearest', inline: 'center'\}\);",
          dotAll: true,
        ).hasMatch(settingsSource),
        isTrue,
      );
      expect(settingsSource, isNot(contains("'aria-current'")));
      // The click path goes through the dirty guard, never straight to the
      // panel switch — see the dirty-state group below.
      expect(settingsSource, contains('requestSettingsTab(targetId);'));
      expect(settingsSource, contains('activateSettingsTab(initialTab);'));
      // `.tab` is shared vocabulary, so every strip lookup is container-scoped.
      expect(settingsSource, isNot(contains("document.querySelectorAll('.tab')")));
      expect(settingsSource, contains("document.querySelector('[data-settings-tabs]')"));
      // Toggle fields stay out of the dirty diff and the save payload. The
      // container class cannot carry this: `.form-field--inline` also hosts
      // non-toggle inline fields, so the guard keys on the control itself.
      // Three sites, not four: the dirty diff and the save payload now share
      // one traversal in `formChanges`. The exclusion's behaviour is proved in
      // `settings_dirty_state_test.dart`; this only counts the call sites.
      expect(RegExp(r"group\.querySelector\('\.form-toggle'\)").allMatches(settingsSource), hasLength(3));
      expect(RegExp(r"classList\.contains\('form-").hasMatch(settingsSource), isFalse);
      expect(settingsSource, contains('fields[group.dataset.field].mutable'));
      expect(settingsSource, contains('Changes reload without a server restart.'));
      // Same intent as the retired `present.has('restart')` literal: the
      // restart tier is still detected. It no longer selects a warning tint or
      // an alert glyph — the note is unconditional helper copy, so the
      // undiluted --warning token means the actual pending-restart state.
      expect(settingsSource, contains("['live', 'reloadable', 'restart'].filter"));
      expect(settingsSource, isNot(contains('section-note-restart')));
      expect(
        RegExp(r'icon-triangle-alert').allMatches(_jsFunction(settingsSource, 'function updateMutabilitySummaries')),
        isEmpty,
      );
      expect(appCss, isNot(contains('.section-note-restart')));
      expect(settingsSource, isNot(contains('restart-required-badge')));
    });

    test('composer rich input reuses canonical accessible chips', () {
      final chatSource = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(chatSource, contains('<span class="chip">'));
      expect(chatSource, contains('<span class="chip chip--ref">'));
      expect(chatSource, contains('class="chip-remove" aria-label="Remove attachment"'));
      expect(chatSource, contains('class="chip-remove" aria-label="Remove reference"'));
      expect(chatSource, isNot(contains('composer-chip')));
      expect(designSystemCss, contains('.chip-remove { width: 44px; height: 44px; }'));
    });

    test('composer suggestions restore the message affordances', () {
      final chatSource = File('$baseDir/controllers/dc_chat_controller.js').readAsStringSync();
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(chatSource, contains('applySuggestion(event)'));
      expect(appCss, contains('.composer-hints'));
    });

    test('pairing expiry uses the canonical clock icon', () {
      final template = File('$baseDir/../templates/whatsapp_pairing.html').readAsStringSync();

      expect(template, contains('class="pairing-expired-icon"><span class="icon icon-clock" aria-hidden="true">'));
      expect(template, isNot(contains('&#9203;')));
      expect(template, isNot(contains('⏳')));
    });
  });

  group('native dialog eradication', () {
    final controllerSources = Directory('$baseDir/controllers')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.js'))
        .toList();

    // Slices one method/function body out of a controller source, relying on the
    // two-space member indentation every controller uses.
    String bodyOf(String source, String signature) {
      final start = source.indexOf(signature);
      if (start < 0) return '';
      final end = source.indexOf('\n  }\n', start);
      return source.substring(start, end < 0 ? source.length : end);
    }

    test('no controller reaches for a native browser dialog', () {
      // Native boxes cannot be themed, block the event loop, and no screenshot
      // captures them — the whole reason confirmDialog() exists.
      final forbidden = RegExp(r'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\(', multiLine: true);
      final offenders = <String>[];
      for (final file in controllerSources) {
        if (forbidden.hasMatch(file.readAsStringSync())) offenders.add(file.uri.pathSegments.last);
      }
      expect(offenders, isEmpty, reason: 'native dialog call forms found in: ${offenders.join(', ')}');
    });

    test('exactly one confirmation API and one htmx:confirm gate exist', () {
      var definitions = 0;
      var confirmEventMentions = 0;
      for (final file in controllerSources) {
        final source = file.readAsStringSync();
        definitions += 'function confirmDialog('.allMatches(source).length;
        confirmEventMentions += "'htmx:confirm'".allMatches(source).length;
      }
      expect(definitions, 1, reason: 'a second modal confirmation implementation appeared');
      // One addEventListener plus its disconnect() counterpart.
      expect(confirmEventMentions, 2);

      // Independent of how a second API is spelled: only one file may build the
      // confirm frame.
      final emitters = controllerSources
          .where((file) => file.readAsStringSync().contains('dialog dialog--confirm'))
          .map((file) => file.uri.pathSegments.last)
          .toList();
      expect(emitters, ['shared.js']);

      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      expect(shellSource, contains("addEventListener('htmx:confirm', this.handleHtmxConfirm)"));
      expect(shellSource, contains("removeEventListener('htmx:confirm', this.handleHtmxConfirm)"));
      // Without the argument htmx falls back to its own native confirm box.
      expect(shellSource, contains('issueRequest(true)'));
    });

    test('the confirmation frame composes the canonical dialog classes', () {
      final sharedSource = File('$baseDir/controllers/shared.js').readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(sharedSource, contains("'dialog dialog--confirm card card-glass'"));
      expect(sharedSource, contains('showModal()'));
      // Danger is markup, not a second frame — DESIGN.md § Feedback.
      expect(sharedSource, contains("danger ? 'btn btn-danger-fill btn-sm' : 'btn btn-sm'"));
      expect(sharedSource, contains("'icon icon-triangle-alert'"));
      for (final rule in ['.dialog--confirm', '.dialog-header', '.dialog-body', '.dialog-footer', '.dialog-actions']) {
        expect(designSystemCss, contains(rule), reason: '$rule is consumed but not defined in canon');
      }
    });

    test('the scheduled-task delete confirms in-row before it deletes', () {
      final source = File('$baseDir/controllers/dc_scheduling_controller.js').readAsStringSync();

      // One construction serving both scheduling tables, not a forked copy.
      expect("'delete-confirm-bar'".allMatches(source).length, 1);
      expect(source, contains('insertDeleteConfirmRow(button, message, confirmAction, confirmData)'));

      // The first click may only raise the bar; the DELETE belongs to the
      // explicit confirm action, or the row would delete on a single click.
      final firstClick = bodyOf(source, 'deleteScheduledTask(event) {');
      expect(firstClick, isNot(contains('fetch(')));
      expect(firstClick, contains('dataset?.taskTitle'));
      // The title is required, never preferred: an `|| taskId` fallback would put
      // a UUID the operator never read into the confirmation text.
      expect(firstClick, isNot(contains('|| taskId')));
      expect(firstClick, contains('if (!taskId || !taskTitle) return;'));
      // Reading the title is not enough — the bar has to say it, or the row
      // names an id the user never saw.
      expect(firstClick, contains("insertDeleteConfirmRow(button, \"Delete scheduled task '\" + taskTitle + \"'?\""));

      final confirmAction = bodyOf(source, 'executeDeleteScheduledTask(event) {');
      expect(confirmAction, contains("fetch('/api/scheduling/tasks/'"));
      expect(confirmAction, contains("method: 'DELETE'"));

      // A failed delete must put the row back. currentTarget is null after the
      // await, so the restore has to take the captured element, not the event —
      // otherwise the row stays hidden and the task reads as deleted.
      for (final body in [confirmAction, bodyOf(source, 'executeDeleteJob(event) {')]) {
        expect(body, contains('restoreDeleteConfirmRow(button)'));
        expect(body, isNot(contains('cancelDelete(event)')));
      }

      // The row names what the Title column shows, not the opaque id.
      final template = File('$baseDir/../templates/scheduling.html').readAsStringSync();
      expect(template, contains(r'data-task-id=${task.id},data-task-title=${task.title}'));
    });

    test('restart failures surface as toasts, and the guard editor edits as a form', () {
      final shellSource = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      for (final message in ["'Restart failed: '", "'Restart failed'", "'Failed to reach server'"]) {
        expect(shellSource, contains("showToast('error', $message"));
      }

      final settingsSource = File('$baseDir/controllers/dc_settings_controller.js').readAsStringSync();
      // The three legal levels come from a select, as the Add form already does.
      expect(settingsSource, contains("'dialog dialog--md card card-glass'"));
      for (final level in ['no_access', 'read_only', 'no_delete']) {
        expect(settingsSource, contains(level));
      }
      expect(settingsSource, contains('form-select'));
    });

    test('allowlist removals are confirmed before either DELETE fires', () {
      final source = File('$baseDir/controllers/dc_settings_controller.js').readAsStringSync();
      // Bound the slice to the handler itself; several later call sites would
      // otherwise satisfy the assertions below from outside it.
      final start = source.indexOf('Allowlist remove handler');
      final end = source.indexOf('Pairing polling', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final handler = source.substring(start, end);

      // One contiguous string, so the gate's result cannot be severed from the
      // check by shadowing `confirmed` between them.
      final gate = handler.indexOf('var confirmed = await confirmDialog(');
      final cancelReturn = handler.indexOf('if (!confirmed) return;');
      final dmBranch = handler.indexOf("if (listType === 'dm')");
      expect(gate, greaterThan(-1), reason: 'the allowlist removals fire DELETE with no confirmation');
      // Without the early return the dialog is decorative: cancelling still deletes.
      expect(cancelReturn, greaterThan(gate), reason: 'cancelling must abort before either branch');
      expect(cancelReturn, lessThan(dmBranch), reason: 'the confirmation must gate both branches, not one');

      // The group branch does strictly more on success than the DM branch.
      final groupToast = handler.indexOf("showToast('success', 'Group entry removed (restart required)')");
      final banner = handler.indexOf('showChannelRestartBanner()');
      expect(banner, greaterThan(-1), reason: 'the group success path lost its restart banner');
      expect(banner, lessThan(groupToast));
      expect(handler, contains("showToast('success', 'Entry removed')"));
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

    test('shell contains entry motion while page surfaces retain scroll ownership', () {
      final designSystemCss = File(designSystemCssPath).readAsStringSync();
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(designSystemCss, contains('grid-template-columns: var(--sidebar-w) minmax(0, 1fr);'));
      expect(designSystemCss, contains('grid-template-rows: var(--topbar-h) minmax(0, 1fr);'));
      expect(designSystemCss, contains('height: 100dvh;\n  overflow: hidden;'));
      expect(designSystemCss, contains('.shell { grid-template-columns: minmax(0, 1fr); }'));
      expect(designSystemCss, contains('.content-area {\n  min-height: 0;\n  overflow-y: auto;'));
      expect(
        designSystemCss,
        contains('.chat-area {\n  display: flex;\n  flex-direction: column;\n  overflow: hidden;\n  min-height: 0;'),
      );
      expect(
        designSystemCss,
        contains('.messages {\n  flex: 1;\n  display: flex;\n  flex-direction: column;\n  overflow-y: auto;'),
      );
      expect(designSystemCss, contains('@starting-style {\n  .print-in {\n    opacity: 0;\n    translate: 0 6px;'));
      expect(appCss, contains('.page-content { position: relative; min-height: 0; overflow-y: auto;'));
      expect(
        appCss,
        contains(
          '.shell > .shell-main {\n  grid-row: 1 / -1;\n  display: flex;\n  flex-direction: column;\n  min-height: 0;',
        ),
      );
      expect(appCss, contains('.shell-main > #main-content { flex: 1 1 auto; min-height: 0; }'));
      expect(appCss, contains('.pairing-main { overflow-y: auto;'));

      final appShellDeclarations = RegExp(
        r'^\s*\.shell\s*\{([^}]*)\}',
        multiLine: true,
        dotAll: true,
      ).allMatches(appCss).map((match) => match.group(1)!).join('\n');
      expect(
        appShellDeclarations,
        isNot(contains(RegExp(r'overflow(?:-[xy])?\s*:'))),
        reason: 'app.css loads after canon and must not override shell containment',
      );
    });
  });

  group('shell failure, feedback and loading contracts', () {
    test('one body-level listener pair owns every htmx failure', () {
      final shell = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();

      // Two listeners on the same event paint two toasts for one failure, so
      // the archive-local pair was removed rather than deduplicated downstream.
      expect(shell, isNot(contains('bindHtmxRequestErrors')));
      for (final event in ['htmx:responseError', 'htmx:sendError']) {
        expect(
          "addEventListener('$event'".allMatches(shell).length,
          1,
          reason: '$event must be registered exactly once',
        );
        expect(
          "removeEventListener('$event'".allMatches(shell).length,
          1,
          reason: '$event must be torn down in disconnect()',
        );
      }
      expect(shell, contains('readHtmxErrorMessage(event.detail.xhr'));
      // Archive keeps its sidebar restoration and gains no replacement catch.
      expect(shell, contains('if (wasSidebarOpen) this.setSidebarOpen(true);'));
    });

    test('a dropped event stream is announced and stops the freshness animations', () {
      final shell = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();
      final appCss = File(componentsCssPath).readAsStringSync();
      final designSystemCss = File(designSystemCssPath).readAsStringSync();

      expect(shell, contains("this.globalEventSource.onopen = () => this.setConnectionState('live')"));
      expect(shell, contains("setConnectionState('lost')"));
      expect(shell, contains("banner.className = 'banner banner-warning'"));
      expect(shell, contains('connection-lost-banner'));

      expect(appCss, contains('.shell[data-connection="lost"] .status-dot--live::before'));
      expect(appCss, contains('.shell[data-connection="lost"] .scan-bar::after'));
      // The attribute is an additional gate; reduced motion stays independent.
      expect(designSystemCss, contains('prefers-reduced-motion: reduce'));
      expect(appCss, isNot(contains('data-connection="lost"] *')));
    });

    test('a navigation mutation parks its toast and shows it exactly once', () {
      final shared = File('$baseDir/controllers/shared.js').readAsStringSync();
      final shell = File('$baseDir/controllers/dc_shell_controller.js').readAsStringSync();

      expect(shared, contains('export function queueToast('));
      expect(shared, contains('sessionStorage.setItem(TOAST_QUEUE_KEY'));
      // deleteSession navigates away, so it queues instead of showing.
      expect(shell, contains("queueToast('success', 'Chat deleted')"));
      // Read and clear in one pass, or the toast repeats on the next navigation.
      expect(shell, contains('sessionStorage.getItem(TOAST_QUEUE_KEY)'));
      expect(shell, contains('sessionStorage.removeItem(TOAST_QUEUE_KEY)'));
      expect(shell, contains('this.drainQueuedToast()'));
    });

    test('in-flight work has a visible treatment in the shared layer', () {
      final layout = File(
        File('packages/dartclaw_server/lib/src/templates/layout.html').existsSync()
            ? 'packages/dartclaw_server/lib/src/templates/layout.html'
            : 'lib/src/templates/layout.html',
      ).readAsStringSync();
      final appCss = File(componentsCssPath).readAsStringSync();

      // hx-indicator on <body> is inherited by every htmx element, so no
      // per-surface template carries a navigation indicator of its own.
      expect(layout, contains('hx-indicator="#nav-progress"'));
      expect(layout, contains('id="nav-progress" class="scan-bar htmx-indicator"'));
      expect(appCss, contains('#nav-progress'));
      // Overlaid, not in flow: a polled region's content is already on screen,
      // so an in-flow indicator would push it down on every refresh cycle.
      expect(appCss, contains('.poll-skeleton { position: absolute;'));
      expect(appCss, contains('.poll-skeleton.htmx-request { display: block; }'));
      expect(appCss, isNot(contains('.poll-skeleton.htmx-request { display: flex; }')));

      // The audit's free-text Detail column wraps; holding every cell on one
      // line pushed the scroller past its container at 1024px and below.
      expect(appCss, contains('#audit-table-container .table-scroll td:not(:last-child) { white-space: nowrap; }'));
      expect(appCss, isNot(contains('#audit-table-container .table-scroll th, ')));
      // Canon's .data-table th owns the header treatment outright.
      expect(appCss, isNot(contains('#audit-table-container .table-scroll th {')));
    });

    test('task tables fit the shell throughout its constrained desktop range', () {
      final appCss = File(componentsCssPath).readAsStringSync();

      expect(
        appCss,
        contains(
          '@media (max-width: 1156px) {\n'
          '  .task-status-group .data-table { min-width: 100%; }\n'
          '  .task-status-group .task-col-created-by,\n'
          '  .task-status-group .task-col-created,\n'
          '  .task-status-group .task-col-status,\n'
          '  .task-status-group .task-col-tokens {\n'
          '    min-width: 0;\n'
          '  }\n'
          '}',
        ),
      );
      expect(appCss, isNot(contains('.task-status-group .task-col-tokens { display: none; }')));
      expect(
        appCss,
        contains(
          '@media (min-width: 769px) and (max-width: 1156px) {\n'
          '  .task-status-group .data-table :is(th, td) { padding-inline: var(--sp-2); }\n'
          '}',
        ),
      );
      expect(appCss, contains('table-layout: fixed;\n    min-width: 0;'));
    });
  });

  group('identicon behavior', () {
    test('shared utility computes and applies identicons behaviorally', () async {
      final sharedFile = File('$baseDir/controllers/shared.js').absolute;
      await expectNodeHarness(_identiconHarness, [sharedFile.uri.toString()]);
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
      expect(css, contains('.session-item .session-action,\n  .session-item .session-delete {\n    min-height: 48px;'));
      expect(css, contains('.session-item :is(.session-action, .session-delete) {\n    min-width: 48px;'));
    });
  });

  test('dialog backdrop mixes a theme token with transparency', () {
    final appCss = File(componentsCssPath).readAsStringSync();
    final designSystemCss = File(designSystemCssPath).readAsStringSync();

    expect(
      RegExp(
        r'\.dialog::backdrop\s*\{[^}]*background: color-mix\(in srgb, var\(--bg-pit\) 64%, transparent\);',
        dotAll: true,
      ).hasMatch(designSystemCss),
      isTrue,
    );
    expect(RegExp(r'^\.dialog(-|::|\[|\s|,|\{)', multiLine: true).hasMatch(appCss), isFalse);
  });

  // Second layer for the settings dirty state. What the operator observes —
  // the flag, the Save control, the save payload, which forms a tab switch is
  // about to hide — is driven through Node against the real functions in
  // `settings_dirty_state_test.dart`. What that cannot reach is the *call-site
  // wiring*: whether the computation is invoked from the paths that must invoke
  // it, and skipped on the one that must not. Those are asserted here, scoped
  // per function so an assertion cannot be satisfied from a different site.
  group('settings dirty state is wired to the paths that need it', () {
    late String source;

    setUp(() {
      source = File('$baseDir/controllers/dc_settings_controller.js').readAsStringSync();
    });

    test('the dirty computation and the save payload are one traversal', () {
      // Two traversals could disagree about what changed — the form reporting
      // clean while Save still had something to send, or the reverse.
      expect(
        _jsFunction(source, 'function updateFormDirtyState'),
        contains('applyFormDirtyState(form, Object.keys(formChanges(form, settingsInitialConfig)).length > 0);'),
      );
      expect(
        _jsFunction(source, 'function handleFormSave'),
        contains('var changes = formChanges(form, settingsInitialConfig);'),
      );
      // Compact Instructions is a textarea; excluded from the lookup it was
      // never diffed and never saved.
      expect(_jsFunction(source, 'function getFieldInput'), contains("'input, select, textarea'"));
    });

    test('the flag is recomputed on every edit and re-baselined by a Retry', () {
      // Without these two call sites the flag is written once and never again:
      // typing would not arm Save, and a Retry-driven repopulate would leave
      // the form reporting a phantom edit.
      final listeners = _jsFunction(source, 'function attachSettingsListeners');
      expect(RegExp(r'updateFormDirtyState\(form\);').allMatches(listeners), hasLength(2));
      expect(listeners, contains("content.addEventListener('input'"));
      expect(listeners, contains("content.addEventListener('change'"));

      final load = _jsFunction(source, 'function loadSettingsConfig');
      expect(load, contains(".querySelectorAll('.settings-form').forEach(updateFormDirtyState);"));
    });

    test('the operator tab-click path consults dirty state before hiding a card', () {
      expect(_jsFunction(source, 'function handleSettingsTabClick'), contains('requestSettingsTab(targetId);'));

      // Which forms it selects is proved behaviourally in
      // `settings_dirty_state_test.dart`; what matters here is that the click
      // path feeds it the live grid and the live baseline rather than bypassing
      // it, and that a form-less tab is not special-cased at the call site.
      final request = _jsFunction(source, 'function requestSettingsTab');
      expect(
        request,
        contains(
          "const leaving = dirtyFormsLeaving(document.querySelector('.settings-grid'), "
          'tabId, settingsInitialConfig);',
        ),
      );
      expect(request, contains("title: 'Discard unsaved changes?',"));
      expect(request, contains("confirmLabel: 'Discard',"));
      expect(request, contains('danger: true,'));
    });

    test('the init-time activation path does not consult dirty state', () {
      final init = _jsFunction(source, 'function initSettingsForm');

      expect(init, contains('activateSettingsTab(initialTab);'));
      // A confirm here would block page load behind a dialog for a form that
      // has never been edited.
      expect(init, isNot(contains('requestSettingsTab')));
      expect(init, isNot(contains('confirmDialog')));
    });

    test('confirm restores the fields from the baseline and re-clears the flag', () {
      final request = _jsFunction(source, 'function requestSettingsTab');
      final gate = request.indexOf('if (!confirmed) return;');
      final restore = request.indexOf('leaving.forEach(handleFormCancel);');
      final commit = request.lastIndexOf('commitSettingsTab(tabId);');

      expect(gate, greaterThan(-1));
      expect(restore, greaterThan(gate), reason: 'confirm must discard the edit, not silently retain it');
      expect(commit, greaterThan(restore), reason: 'the panel moves only after the discard is applied');

      // Restoring is from the saved baseline, and it re-baselines the form so
      // the same warning cannot fire twice for one discarded edit.
      final cancel = _jsFunction(source, 'function handleFormCancel');
      expect(cancel, contains('getNestedValue(settingsInitialConfig, jsonPath)'));
      expect(cancel, contains('setFieldValue(input, value);'));
      expect(cancel, contains('updateFormDirtyState(form);'));
    });

    test('cancel neither restores the fields nor switches the panel', () {
      final request = _jsFunction(source, 'function requestSettingsTab');
      final gate = request.indexOf('if (!confirmed) return;');

      // Every mutation sits behind the gate, so a dismissed dialog leaves the
      // edit in the field and the strip on the originating tab.
      expect(RegExp('leaving.forEach').allMatches(request.substring(0, gate)), isEmpty);
      expect(RegExp(r'commitSettingsTab\(tabId\);').allMatches(request.substring(gate)), hasLength(1));
      // The synchronous no-dirty path is the only other commit, and it is
      // reached only when nothing would be discarded.
      expect(request.indexOf('if (leaving.length === 0) {'), lessThan(gate));
    });
  });
}

String _mixHex(String foreground, String background, double alpha) {
  final mixed = List<int>.generate(3, (index) {
    final offset = 1 + index * 2;
    final foregroundChannel = int.parse(foreground.substring(offset, offset + 2), radix: 16);
    final backgroundChannel = int.parse(background.substring(offset, offset + 2), radix: 16);
    return (foregroundChannel * alpha + backgroundChannel * (1 - alpha)).round();
  });
  return '#${mixed.map((channel) => channel.toRadixString(16).padLeft(2, '0')).join()}';
}

double _contrastRatio(String first, String second) {
  final luminances = [_relativeLuminance(first), _relativeLuminance(second)]..sort();
  return (luminances.last + 0.05) / (luminances.first + 0.05);
}

double _relativeLuminance(String color) {
  final channels = List<double>.generate(3, (index) {
    final offset = 1 + index * 2;
    final value = int.parse(color.substring(offset, offset + 2), radix: 16) / 255;
    return value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  });
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

/// The body of a named JS function, so an assertion about one call site cannot
/// be satisfied by an unrelated one elsewhere in the file.
///
/// Brace-balanced rather than "up to the next column-0 `}`": a truncated slice
/// would leave every `isNot(contains(...))` assertion below passing vacuously.
String _jsFunction(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) throw StateError('no such function in dc_settings_controller.js: $signature');
  final open = source.indexOf('{', start);
  if (open < 0) throw StateError('no body for: $signature');

  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unterminated function: $signature');
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
const emojiPrefixed = mount('entity-2', '🧪Research');
const punctuationPrefixed = mount('entity-3', '@alpha');
const unicode = mount('entity-4', 'Ångström');
const punctuationOnly = mount('entity-5', '🧪@');
const root = {
  matches: () => false,
  querySelectorAll: () => [named, fallback, emojiPrefixed, punctuationPrefixed, unicode, punctuationOnly],
};
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
if (emojiPrefixed.textContent !== 'Re') throw new Error('emoji leaked into initials');
if (punctuationPrefixed.textContent !== 'al') throw new Error('punctuation leaked into initials');
if (unicode.textContent !== 'Ån') throw new Error('Unicode initials were not preserved');
if (punctuationOnly.textContent !== '?') throw new Error('punctuation-only initials did not fall back');
''';
