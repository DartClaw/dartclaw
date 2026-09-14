@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/server.dart'
    show ServerCoreDeps, ServerObservabilityDeps, ServerTaskDeps, ServerTurnDeps, ServerWebDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowStep, WorkflowVariable;
import 'package:dartclaw_workflow/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request, Response;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import '../api/workflow_test_support.dart';
import '../execution_coordinator_test_support.dart';

const _chromeCandidates = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
];

String _resolveChrome() {
  final configured = Platform.environment['CHROME_BIN'];
  if (configured != null && configured.trim().isNotEmpty) {
    if (File(configured).existsSync()) return configured;
    fail('CHROME_BIN does not identify an installed browser: $configured');
  }
  for (final candidate in _chromeCandidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  fail(
    'Chrome or Chromium is required for this explicit browser proof. '
    'Set CHROME_BIN to its executable path.',
  );
}

Future<String> _runtimeAssetDir(String child) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  if (uri == null) throw StateError('Could not resolve package:dartclaw_runtime.');
  return p.join(File.fromUri(uri).parent.path, 'src', child);
}

Future<void> _eventually(
  FutureOr<bool> Function() predicate, {
  String? reason,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(reason ?? 'Condition did not become true within $timeout');
}

final class _CdpPage {
  new(this._socket) {
    _subscription = _socket.listen(_handleMessage);
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<String> exceptions = [];
  final List<String> consoleErrors = [];
  final List<String> requestedUrls = [];
  final List<String> failedUrls = [];
  final List<String> finishedUrls = [];
  final Map<String, String> _requestsById = {};
  int _nextId = 0;

  void _handleMessage(dynamic raw) {
    final message = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = message['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error != null) {
        completer.completeError(StateError('CDP error: $error'));
      } else {
        completer.complete((message['result'] as Map?)?.cast<String, dynamic>() ?? const {});
      }
      return;
    }
    if (message['method'] == 'Runtime.exceptionThrown') {
      final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      exceptions.add(jsonEncode(params));
    } else if (message['method'] == 'Network.requestWillBeSent') {
      final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      final request = (params['request'] as Map?)?.cast<String, dynamic>();
      final url = request?['url'];
      if (url is String) {
        requestedUrls.add(url);
        final requestId = params['requestId'];
        if (requestId is String) _requestsById[requestId] = url;
      }
    } else if (message['method'] == 'Network.loadingFailed') {
      final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      final requestId = params['requestId'];
      if (requestId is String) failedUrls.add(_requestsById[requestId] ?? requestId);
    } else if (message['method'] == 'Network.loadingFinished') {
      final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      final requestId = params['requestId'];
      if (requestId is String) finishedUrls.add(_requestsById[requestId] ?? requestId);
    } else if (message['method'] == 'Runtime.consoleAPICalled') {
      final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (params['type'] == 'error') consoleErrors.add(jsonEncode(params));
    }
  }

  Future<Map<String, dynamic>> send(String method, [Map<String, Object?> params = const {}]) {
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return completer.future.timeout(const Duration(seconds: 10));
  }

  Future<Object?> evaluate(String expression) async {
    final response = await send('Runtime.evaluate', {
      'expression': expression,
      'awaitPromise': true,
      'returnByValue': true,
    });
    if (response['exceptionDetails'] != null) {
      throw StateError('Browser evaluation failed: ${response['exceptionDetails']}');
    }
    return ((response['result'] as Map?)?['value']);
  }

  Future<void> navigate(String url) async {
    await send('Page.navigate', {'url': url});
    await _eventually(
      () async => await evaluate('document.readyState') == 'complete',
      reason: 'Page did not finish loading: $url',
    );
  }

  Future<void> waitFor(String expression, {String? reason, Duration timeout = const Duration(seconds: 10)}) {
    return _eventually(
      () async => await evaluate('Boolean($expression)') == true,
      reason: reason ?? 'Browser condition did not become true: $expression',
      timeout: timeout,
    );
  }

  Future<void> setViewport(int width, int height) async {
    await send('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'deviceScaleFactor': 1,
      'mobile': width <= 768,
    });
  }

  Future<void> screenshot(File destination) async {
    final result = await send('Page.captureScreenshot', {'format': 'png', 'captureBeyondViewport': false});
    await destination.writeAsBytes(base64Decode(result['data'] as String));
  }

  int requestCount(String path) => requestedUrls.where((url) => Uri.parse(url).path == path).length;

  List<String> takeConsoleErrors() {
    final errors = List<String>.of(consoleErrors);
    consoleErrors.clear();
    return errors;
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

final class _Chrome {
  new _(this.process, this.profile, this.page);

  final Process process;
  final Directory profile;
  final _CdpPage page;

  static Future<_Chrome> launch() async {
    final chromePath = _resolveChrome();
    final profile = Directory.systemTemp.createTempSync('dartclaw_htmx4_chrome_');
    final process = await Process.start(chromePath, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      'about:blank',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    await _eventually(portFile.existsSync, reason: 'Chrome did not expose DevToolsActivePort');
    final lines = await portFile.readAsLines();
    final port = int.parse(lines.first);
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
      final response = await request.close();
      final targets = jsonDecode(await utf8.decodeStream(response)) as List<dynamic>;
      final target = targets.cast<Map<String, dynamic>>().firstWhere((item) => item['type'] == 'page');
      final socket = await WebSocket.connect(target['webSocketDebuggerUrl'] as String);
      final page = _CdpPage(socket);
      await page.send('Page.enable');
      await page.send('Runtime.enable');
      await page.send('Network.enable');
      return _Chrome._(process, profile, page);
    } catch (_) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
      if (profile.existsSync()) profile.deleteSync(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await page.close();
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (profile.existsSync()) profile.deleteSync(recursive: true);
  }
}

void main() {
  late String staticDir;
  late String templatesDir;

  setUpAll(() async {
    staticDir = await _runtimeAssetDir('static');
    templatesDir = await _runtimeAssetDir('templates');
    initTemplates(templatesDir);
  });
  tearDownAll(resetTemplates);

  test('shipped HTMX 4 UI completes critical browser journeys', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_htmx4_server_');
    final sessions = SessionService(baseDir: tempDir.path);
    final messages = MessageService(baseDir: tempDir.path);
    final worker = FakeAgentHarness();
    final eventBus = EventBus();
    final taskBackend = await openPreparedTaskBackend();
    final taskService = TaskService(SqliteTaskRepository(taskBackend), eventBus: eventBus);
    final worktreeManager = WorktreeManager(
      dataDir: tempDir.path,
      projectDir: tempDir.path,
      processRunner: RecordingGitRunner().run,
    );
    final taskFileGuard = TaskFileGuard();
    final gitGateway = FakeGitGateway()..initWorktree(tempDir.path);
    final mergeExecutor = MergeExecutor(projectDir: tempDir.path, gitPort: gitGateway);
    final definition = WorkflowDefinition(
      name: 'browser-proof',
      description: 'Browser proof workflow',
      variables: const {'FEATURE': WorkflowVariable(required: true, description: 'Feature to verify')},
      steps: const [
        WorkflowStep(id: 'verify', name: 'Verify', prompts: ['Verify it']),
      ],
    );
    final definitions = InMemoryDefinitionSource([definition]);
    final workflows =
        FakeWorkflowService(backend: taskBackend, taskService: taskService, eventBus: eventBus, dataDir: tempDir.path)
          ..validateRequiredVars = true
          ..startResult = WorkflowRun(
            id: 'browser-run',
            definitionName: definition.name,
            status: WorkflowRunStatus.running,
            startedAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
            definitionJson: definition.toJson(),
          )
          ..getResult = WorkflowRun(
            id: 'browser-run',
            definitionName: definition.name,
            status: WorkflowRunStatus.running,
            startedAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
            definitionJson: definition.toJson(),
          );
    final configDataDir = p.join(tempDir.path, 'config-data');
    Directory(configDataDir).createSync(recursive: true);
    final configPath = p.join(tempDir.path, 'dartclaw.yaml');
    File(configPath).writeAsStringSync('''
port: 8181
host: 127.0.0.1
agent:
  provider: claude
  model: opus
  effort: high
''');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: configDataDir),
      container: const ContainerConfig(enabled: true),
      governance: const GovernanceConfig(
        turnLimits: TurnLimitsConfig(stallTimeout: Duration(milliseconds: 500), stallAction: TurnProgressAction.ignore),
      ),
    );
    final configWriter = ConfigWriter(configPath: configPath);
    final sseBroadcast = SseBroadcast();
    final resetService = SessionResetService(sessions: sessions, messages: messages, resetHour: -1);
    final turns = composeServerTurns(
      sessions: sessions,
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
      resetService: resetService,
      eventBus: eventBus,
      config: config,
    );
    final runnerObserver = RunnerObserver(
      executions: coordinatorForRunners([
        TurnRunner(
          turnLimits: config.governance.turnLimits,
          harness: worker,
          messages: messages,
          behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
        ),
      ]),
      eventBus: eventBus,
    );
    final server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: worker,
        staticDir: staticDir,
        gatewayToken: 'browser-proof-token',
        tokenService: TokenService(token: 'browser-proof-token'),
        resetService: resetService,
        dataDir: configDataDir,
        config: config,
        runtimeConfig: RuntimeConfig(heartbeatEnabled: false, gitSyncEnabled: false),
        configWriter: configWriter,
        restartService: RestartService(turns: turns, exit: (_) {}),
      ),
      turn: ServerTurnDeps(turns: turns),
      tasks: ServerTaskDeps(
        taskService: taskService,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        mergeExecutor: mergeExecutor,
        runnerObserver: runnerObserver,
        eventBus: eventBus,
      ),
      observability: ServerObservabilityDeps(eventBus: eventBus, sseBroadcast: sseBroadcast),
      web: ServerWebDeps(workflowService: workflows, workflowDefinitionSource: definitions),
    );
    var rejectStreamRequests = false;
    var rejectNextHistoryRestore = false;
    final httpServer = await shelf_io.serve(
      (Request request) async {
        if (rejectStreamRequests && request.url.path.contains('/stream')) {
          return Response(503, body: 'Injected stream refusal');
        }
        if (rejectNextHistoryRestore && request.headers['hx-history-restore-request'] == 'true') {
          rejectNextHistoryRestore = false;
          return Response(503, body: 'Injected history refusal');
        }
        return server.handler(request);
      },
      InternetAddress.loopbackIPv4,
      0,
    );
    final baseUrl = 'http://${httpServer.address.address}:${httpServer.port}';
    final session = await sessions.createSession();
    for (var index = 1; index <= 220; index++) {
      await messages.insertMessage(
        sessionId: session.id,
        role: index.isOdd ? 'user' : 'assistant',
        content: 'Browser history message $index',
      );
    }

    final chrome = await _Chrome.launch();
    final page = chrome.page;
    final publicRoot = Directory(staticDir).parent.parent.parent.parent.parent;
    final artifactDir = Directory(
      Platform.environment['DARTCLAW_HTMX4_ARTIFACT_DIR'] ?? p.join(publicRoot.path, '.agent_temp', 'htmx4-browser'),
    );
    await artifactDir.create(recursive: true);

    try {
      await page.setViewport(1280, 900);
      await page.navigate('$baseUrl/sessions/${session.id}');
      await page.waitFor("location.pathname === '/login' && document.querySelector('#token-input')");
      expect(await page.evaluate("document.querySelector('#main-content') === null"), isTrue);
      await page.evaluate('''(() => {
        document.querySelector('#token-input').value = 'browser-proof-token';
        document.querySelector('.login-form').requestSubmit();
      })()''');
      await page.waitFor("window.htmx && window.htmx.version === '4.0.0' && document.querySelector('#chat-form')");
      expect(await page.evaluate("document.querySelectorAll('#messages .msg').length"), 200);
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final paginationPath = '/sessions/${session.id}/messages-html';
      final paginationRequests = page.requestCount(paginationPath);
      await page.evaluate('''(() => {
        const messages = document.querySelector('#messages');
        messages.scrollTop = 0;
        window.__paginationAnchor = messages.querySelector('.msg');
        window.__paginationAnchorTop = window.__paginationAnchor.getBoundingClientRect().top;
        document.querySelector('[data-load-earlier]').click();
      })()''');
      await _eventually(
        () => page.requestCount(paginationPath) > paginationRequests,
        reason: 'The Load earlier control did not issue its real pagination request',
      );
      await page.waitFor(
        "document.querySelectorAll('#messages .msg').length === 220 && document.querySelector('[data-load-earlier]').hidden",
        reason: 'Pagination did not prepend the earlier messages and consume its cursor',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await page.evaluate('window.__paginationAnchor.isConnected'), isTrue);
      final paginationAnchorDelta = await page.evaluate(
        'window.__paginationAnchor.getBoundingClientRect().top - window.__paginationAnchorTop',
      ) as num;
      expect(
        paginationAnchorDelta.abs(),
        lessThan(8),
        reason: 'Prepending history moved the previously visible transcript anchor',
      );
      await page.evaluate("document.querySelector('[data-load-earlier]').click()");
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await page.evaluate("document.querySelectorAll('#messages .msg').length"), 220);

      final sendPath = '/api/sessions/${session.id}/send';
      final sendsBeforePreflight = page.requestCount(sendPath);
      await page.evaluate('''(() => {
        const chat = document.querySelector('[data-controller~="dc-chat"]');
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(chat, 'dc-chat');
        controller.attachments = [{id: 'uploading-proof', filename: 'proof.txt', state: 'uploading'}];
        document.querySelector('#message-input').value = 'local preflight input';
        document.querySelector('#message-input').dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await page.waitFor(
        "document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('still running')",
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(page.requestCount(sendPath), sendsBeforePreflight);
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'local preflight input');
      expect(await page.evaluate("document.querySelector('.banner-error') === null"), isTrue);
      await page.evaluate('''(() => {
        const chat = document.querySelector('[data-controller~="dc-chat"]');
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(chat, 'dc-chat');
        controller.attachments = [{id: 'failed-proof', filename: 'failed.txt', state: 'failed'}];
        controller.syncRichInputs();
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await page.waitFor(
        "document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('upload failed')",
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(page.requestCount(sendPath), sendsBeforePreflight);
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'local preflight input');
      expect(await page.evaluate("document.querySelector('.banner-error') === null"), isTrue);
      await page.evaluate('''(() => {
        const chat = document.querySelector('[data-controller~="dc-chat"]');
        window.dartclaw.stimulus.getControllerForElementAndIdentifier(chat, 'dc-chat').attachments = [];
      })()''');

      await page.evaluate('''(() => {
        window.__historyRestores = 0;
        document.addEventListener('htmx:before:history:restore', () => window.__historyRestores++);
        const form = document.querySelector('#chat-form');
        form.setAttribute('hx-post', '/api/sessions/not-a-session/send');
        htmx.process(form);
        document.querySelector('#message-input').value = 'preserve rejected text';
        document.querySelector('[name="attachments"]').value = '[{"id":"attachment-proof"}]';
        document.querySelector('[name="references"]').value = '[{"path":"reference-proof"}]';
        document.querySelector('#message-input').dispatchEvent(new Event('input', {bubbles: true}));
        form.requestSubmit();
      })()''');
      await page.waitFor(
        "!document.querySelector('#message-input').disabled && document.querySelector('.banner-error')",
      );
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'preserve rejected text');
      expect(await page.evaluate("document.querySelector('[name=attachments]').value"), contains('attachment-proof'));
      expect(await page.evaluate("document.querySelector('[name=references]').value"), contains('reference-proof'));
      expect(await page.evaluate("document.querySelectorAll('#messages .msg').length"), 220);
      expect(await page.evaluate("document.body.classList.contains('streaming')"), isFalse);
      expect(
        await page.evaluate("document.querySelector('#chat-form').classList.contains('composer--streaming')"),
        isFalse,
      );

      await page.evaluate('''(() => {
        const form = document.querySelector('#chat-form');
        form.setAttribute('hx-post', '/api/sessions/${session.id}/send');
        htmx.process(form);
        const chat = document.querySelector('[data-controller~="dc-chat"]');
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(chat, 'dc-chat');
        controller.attachments = [];
        controller.uploadAttachment(new File(['browser attachment'], 'browser-proof.txt', {type: 'text/plain'}));
        document.querySelector('[name="references"]').value = '[]';
        const input = document.querySelector('#message-input');
        input.value = 'stream the browser proof';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#messages').scrollTop = 0;
        window.__htmxDefaultTimeout = htmx.config.defaultTimeout;
        window.__sseConnections = 0;
        document.body.addEventListener('htmx:sse:after:connection', () => window.__sseConnections++);
        htmx.config.defaultTimeout = 1000;
      })()''');
      await page.waitFor(
        "document.querySelector('[name=attachments]').value.includes('browser-proof.txt') && !document.querySelector('[data-dc-chat-target=contextTray]').textContent.includes('uploading')",
        reason: 'The real attachment route did not produce a ready rich input',
      );
      await page.evaluate("document.querySelector('#chat-form').requestSubmit()");
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      expect(jsonEncode(worker.lastMessages), contains('browser-proof.txt'));
      await page.waitFor(
        "document.querySelector('#streaming-msg') && document.querySelector('#message-input').disabled",
      );
      await page.waitFor('window.__sseConnections > 0', reason: 'The real SSE response was never accepted');
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      worker.emit(DeltaEvent('Live browser delta <script id="unsafe-stream-node">throw 1</script>'));
      await page.waitFor("document.querySelector('#streaming-content')?.textContent.includes('Live browser delta')");
      expect(
        await page.evaluate(
          "document.querySelector('#messages').scrollHeight - document.querySelector('#messages').clientHeight - document.querySelector('#messages').scrollTop > 50",
        ),
        isTrue,
        reason: 'A streamed delta forced a scrolled-up transcript to the bottom',
      );
      worker.emit(ToolUseEvent(toolName: 'read', toolId: 'browser-tool', input: const {'path': 'proof.txt'}));
      await page.waitFor("document.querySelector('#tool-container')?.textContent.includes('read')");
      worker.emit(ToolResultEvent(toolId: 'browser-tool', output: 'tool browser result', isError: false));
      await page.waitFor(
        "document.querySelector('#tool-browsertool')?.classList.contains('success')",
        reason: 'The named tool-result event did not update its existing tool card',
      );
      expect(await page.evaluate("document.querySelectorAll('#tool-browsertool').length"), 1);
      await page.evaluate('document.fonts.ready');
      await page.evaluate('''(() => {
        const messages = document.querySelector('#messages');
        messages.scrollTo({top: messages.scrollHeight, behavior: 'instant'});
        window.scrollTo(0, 0);
      })()''');
      await page.waitFor('''(() => {
        const messages = document.querySelector('#messages');
        const bounds = messages.getBoundingClientRect();
        return ['#streaming-content', '#tool-browsertool'].every((selector) => {
          const nodeBounds = document.querySelector(selector)?.getBoundingClientRect();
          return nodeBounds && nodeBounds.top >= bounds.top && nodeBounds.bottom <= bounds.bottom;
        }) && window.scrollY === 0;
      })()''');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-stream-tool-desktop.png')));
      worker.completeSuccess();
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('#message-input').disabled",
      );
      await page.waitFor("!document.querySelector('#streaming-msg')");
      expect(await page.evaluate("document.querySelectorAll('#unsafe-stream-node').length"), 0);
      expect(
        await page.evaluate(
          "document.querySelector('[data-dc-chat-target=recovery]').textContent.includes('could not connect')",
        ),
        isFalse,
      );
      expect(
        page.exceptions,
        isEmpty,
        reason: 'Named SSE close raised an uncaught browser exception: ${page.exceptions.join('\n')}',
      );
      await page.evaluate('htmx.config.defaultTimeout = window.__htmxDefaultTimeout');

      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'preserve cancellation input';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.querySelector('#streaming-msg') && document.querySelector('#message-input').disabled",
      );
      worker.emit(DeltaEvent('Partial cancellation output'));
      await page.waitFor(
        "document.querySelector('#streaming-content')?.textContent.includes('Partial cancellation output')",
      );
      final cancellationReloadsBeforeCompletion = page.requestCount('/sessions/${session.id}/messages-html');
      await page.waitFor(
        "document.querySelector('#send-btn.btn-stop:not(:disabled)')",
        reason: 'A stalled provider turn never exposed its authoritative Stop action',
      );
      await page.evaluate("document.querySelector('#send-btn').click()");
      await page.waitFor(
        "!document.body.classList.contains('streaming') && document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('Turn stopped')",
        reason: 'The real Stop route did not reach its recoverable terminal state',
      );
      await page.waitFor("!document.querySelector('#streaming-msg')");
      await _eventually(
        () => page.requestCount('/sessions/${session.id}/messages-html') > cancellationReloadsBeforeCompletion,
        reason: 'The cancelled turn did not refresh its persisted transcript',
      );
      expect(worker.cancelCalled, isTrue);
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'preserve cancellation input');
      expect(
        await page.evaluate("document.querySelector('#messages').textContent"),
        allOf(contains('preserve cancellation input'), isNot(contains('Partial cancellation output'))),
        reason: 'Cancellation did not reconcile the live partial with the authoritative server transcript',
      );

      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'preserve failed input';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.querySelector('#streaming-msg') && document.querySelector('#message-input').disabled",
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      worker.emit(DeltaEvent('Partial failure output'));
      await page.waitFor(
        "document.querySelector('#streaming-content')?.textContent.includes('Partial failure output')",
      );
      final errorReloadsBeforeCompletion = page.requestCount('/sessions/${session.id}/messages-html');
      worker.completeError(StateError('Browser proof failure'));
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('[data-dc-chat-target=recovery]').hidden",
        reason: 'Failed stream did not reach its recoverable terminal state',
      );
      await _eventually(
        () => page.requestCount('/sessions/${session.id}/messages-html') > errorReloadsBeforeCompletion,
        reason: 'The terminal error did not refresh its persisted transcript',
      );
      await page.waitFor("!document.querySelector('#streaming-msg')");
      expect(
        await page.evaluate("document.querySelector('#messages').textContent"),
        contains('Partial failure output'),
      );
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'preserve failed input');
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-stream-error-desktop.png')));

      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'preserve provider error input';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.querySelector('#streaming-msg') && document.querySelector('#message-input').disabled",
      );
      final providerErrorReloadsBeforeCompletion = page.requestCount('/sessions/${session.id}/messages-html');
      worker.completeSuccess(const TurnResult(stopReason: 'error', error: 'Browser provider error'));
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('[data-dc-chat-target=recovery]').hidden",
        reason: 'Provider error did not reach its recoverable terminal state',
      );
      await _eventually(
        () => page.requestCount('/sessions/${session.id}/messages-html') > providerErrorReloadsBeforeCompletion,
        reason: 'The provider error did not refresh its persisted transcript',
      );
      await page.waitFor("!document.querySelector('#streaming-msg')");
      expect(
        await page.evaluate("document.querySelector('#messages').textContent"),
        contains('Browser provider error'),
      );
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'preserve provider error input');

      final failedUrlsBeforeBlockedStream = page.failedUrls.length;
      final sendsBeforeBlockedStream = page.requestCount(sendPath);
      expect(page.consoleErrors, isEmpty);
      await page.send('Network.setBlockedURLs', {
        'urls': ['$baseUrl/api/sessions/${session.id}/stream*'],
      });
      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'preserve network-refused stream input';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await _eventually(
        () => page.failedUrls.skip(failedUrlsBeforeBlockedStream).any((url) => Uri.parse(url).path.endsWith('/stream')),
        reason: 'Chrome did not block the initial SSE request',
      );
      await page.waitFor(
        "document.body.classList.contains('streaming') && document.querySelector('#message-input').disabled && document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('Waiting for the active turn')",
        reason: 'A network-refused initial SSE request did not retain authoritative turn observation',
      );
      await _eventually(() => page.consoleErrors.isNotEmpty, reason: 'HTMX did not report the blocked stream fetch');
      final blockedStreamConsoleErrors = page.takeConsoleErrors();
      expect(blockedStreamConsoleErrors, hasLength(1));
      expect(
        blockedStreamConsoleErrors.single,
        allOf(contains('htmx:error: Failed to fetch'), contains('streaming-msg')),
      );
      await page.send('Network.setBlockedURLs', {'urls': <String>[]});
      expect(
        page.failedUrls.any((url) => Uri.parse(url).path.endsWith('/stream')),
        isTrue,
        reason: 'Chrome did not record the blocked initial SSE request as a transport failure',
      );
      expect(
        await page.evaluate("document.querySelector('#message-input').value"),
        'preserve network-refused stream input',
      );
      expect(await page.evaluate("document.querySelectorAll('#streaming-msg').length"), 0);
      await page.evaluate("document.querySelector('#chat-form').requestSubmit()");
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        page.requestCount(sendPath),
        sendsBeforeBlockedStream + 1,
        reason: 'A disconnected stream admitted a second send before its turn reached terminal state',
      );
      worker.completeSuccess(const TurnResult(stopReason: 'error', error: 'Injected network refusal'));
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('#message-input').disabled && document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('Turn failed')",
        reason: 'The network-refused stream did not reconcile its terminal server state',
      );
      await page.waitFor("document.querySelector('#messages').textContent.includes('Injected network refusal')");
      expect(
        await page.evaluate("document.querySelector('#message-input').value"),
        'preserve network-refused stream input',
      );

      final networkRetryReloads = page.requestCount('/sessions/${session.id}/messages-html');
      await page.evaluate("document.querySelector('#chat-form').requestSubmit()");
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor("document.querySelectorAll('#streaming-msg').length === 1");
      worker.emit(DeltaEvent('Successful retry after network-refused stream'));
      await page.waitFor(
        "document.querySelector('#streaming-content')?.textContent.includes('Successful retry after network-refused stream')",
      );
      worker.completeSuccess();
      await _eventually(
        () => page.requestCount('/sessions/${session.id}/messages-html') > networkRetryReloads,
        reason: 'The successful network-refusal retry did not refresh persisted messages',
      );
      await page.waitFor("!document.body.classList.contains('streaming') && !document.querySelector('#streaming-msg')");

      rejectStreamRequests = true;
      final sendsBeforeRejectedStream = page.requestCount(sendPath);
      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'preserve refused stream input';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.body.classList.contains('streaming') && document.querySelector('#message-input').disabled && document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('Waiting for the active turn')",
        reason: 'Rejected initial SSE request did not retain authoritative turn observation',
      );
      expect(await page.evaluate("document.querySelector('#message-input').value"), 'preserve refused stream input');
      expect(await page.evaluate("document.querySelectorAll('#streaming-msg').length"), 0);
      await page.evaluate("document.querySelector('#chat-form').requestSubmit()");
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        page.requestCount(sendPath),
        sendsBeforeRejectedStream + 1,
        reason: 'An HTTP-refused stream admitted a second send before its turn reached terminal state',
      );
      await page.waitFor(
        "document.querySelector('#send-btn.btn-stop:not(:disabled)')",
        reason: 'The disconnected stream stopped observing when its turn became cancellable',
      );
      await page.evaluate("document.querySelector('#send-btn').click()");
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('#message-input').disabled && document.querySelector('[data-dc-chat-target=recovery]')?.textContent.includes('Turn stopped')",
        reason: 'Stop did not reconcile the disconnected stream with the authoritative cancelled transcript',
      );
      await page.waitFor("document.querySelector('#messages').textContent.includes('preserve refused stream input')");
      rejectStreamRequests = false;
      await page.evaluate("document.querySelector('#chat-form').requestSubmit()");
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.querySelectorAll('#streaming-msg').length === 1 && document.body.classList.contains('streaming')",
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await page.evaluate("document.body.classList.contains('streaming')"), isTrue);
      worker.emit(DeltaEvent('Successful retry after refused stream'));
      await page.waitFor(
        "document.querySelector('#streaming-content')?.textContent.includes('Successful retry after refused stream')",
      );
      worker.completeSuccess();
      await page.waitFor(
        "!document.body.classList.contains('streaming') && !document.querySelector('#message-input').disabled",
      );
      await page.waitFor(
        "!document.querySelector('#streaming-msg') && document.querySelector('#messages').textContent.includes('Successful retry after refused stream')",
      );
      expect(
        await page.evaluate("document.querySelector('[data-dc-chat-target=recovery]').hidden"),
        isTrue,
        reason: 'A successful retry retained the initial-stream recovery state',
      );
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-chat-desktop.png')));

      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/health-dashboard\"]').click()");
      await page.waitFor("location.pathname === '/health-dashboard' && document.querySelector('#health-live')");
      final healthRequests = page.requestCount('/health-dashboard');
      await page.evaluate('''(() => {
        window.__nativeSetInterval = window.setInterval;
        window.setInterval = (callback, delay) => window.__nativeSetInterval(callback, Math.min(delay, 75));
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(
          document.querySelector('#health-live'),
          'dc-health',
        );
        controller.stopPolling();
        controller.startPolling();
      })()''');
      await _eventually(
        () => page.requestCount('/health-dashboard') >= healthRequests + 2,
        reason: 'The accelerated shipped health controller did not complete two connected polls',
      );
      await page.send('Network.setBlockedURLs', {
        'urls': ['$baseUrl/health-dashboard*'],
      });
      await page.evaluate('''(() => {
        window.setInterval = window.__nativeSetInterval;
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(
          document.querySelector('#health-live'),
          'dc-health',
        );
        controller.stopPolling();
        window.__htmxNetworkErrors = 0;
        document.body.addEventListener('htmx:error', (event) => {
          window.__htmxNetworkErrors++;
          window.__lastHtmxNetworkError = event.detail?.error?.message || '';
        });
        htmx.trigger('#health-live', 'refresh');
      })()''');
      await page.waitFor(
        "window.__htmxNetworkErrors > 0 && document.querySelector('#toast-container .toast-error')?.textContent.length > 0",
        reason: 'The failed network request did not surface through the global HTMX error path',
      );
      await _eventually(() => page.consoleErrors.isNotEmpty, reason: 'HTMX did not report the blocked health fetch');
      final blockedHealthConsoleErrors = page.takeConsoleErrors();
      expect(blockedHealthConsoleErrors, hasLength(1));
      expect(
        blockedHealthConsoleErrors.single,
        allOf(contains('htmx:error: Failed to fetch'), contains('health-live')),
      );
      expect(page.failedUrls.any((url) => Uri.parse(url).path == '/health-dashboard'), isTrue);
      expect(await page.evaluate("document.querySelector('#health-live').isConnected"), isTrue);
      await page.send('Network.setBlockedURLs', {'urls': <String>[]});
      await page.evaluate('''(() => {
        const controller = window.dartclaw.stimulus.getControllerForElementAndIdentifier(
          document.querySelector('#health-live'),
          'dc-health',
        );
        window.setInterval = (callback, delay) => window.__nativeSetInterval(callback, Math.min(delay, 75));
        controller.startPolling();
        window.setInterval = window.__nativeSetInterval;
      })()''');
      await page.waitFor(
        "document.querySelector('#health-live') && !document.querySelector('#health-live').classList.contains('htmx-swapping')",
      );
      await page.evaluate('history.back()');
      await page.waitFor("location.pathname === '/sessions/${session.id}' && window.__historyRestores > 0");
      await page.waitFor(
        "document.querySelector('#messages') && Math.abs(document.querySelector('#messages').scrollHeight - document.querySelector('#messages').clientHeight - document.querySelector('#messages').scrollTop) < 8",
        reason: 'History restore did not reapply the transcript bottom position',
      );
      expect(await page.evaluate("document.querySelectorAll('#main-content').length"), 1);
      expect(await page.evaluate('document.activeElement.id'), 'main-content');
      expect(await page.evaluate("document.querySelector('.topbar').textContent.includes('Health')"), isFalse);
      expect(
        await page.evaluate(
          '''document.querySelector('.session-item a[href="/sessions/${session.id}"]').closest('.session-item').classList.contains('active')''',
        ),
        isTrue,
      );
      final acceleratedHealthRequestsAfterLeaving = page.requestCount('/health-dashboard');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        page.requestCount('/health-dashboard'),
        acceleratedHealthRequestsAfterLeaving,
        reason: 'The detached accelerated health controller kept polling after navigation',
      );

      await page.evaluate('history.forward()');
      await page.waitFor("location.pathname === '/health-dashboard' && document.querySelector('#health-live')");
      expect(await page.evaluate("document.querySelectorAll('#main-content').length"), 1);
      expect(await page.evaluate("document.querySelector('.topbar').textContent.includes('Health')"), isTrue);
      expect(
        await page.evaluate(
          '''document.querySelector('.sidebar-nav-item[href="/health-dashboard"]').classList.contains('active')''',
        ),
        isTrue,
      );
      expect(await page.evaluate('document.activeElement.id'), 'main-content');
      await page.evaluate('history.back()');
      await page.waitFor("location.pathname === '/sessions/${session.id}' && document.querySelector('#chat-form')");

      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/health-dashboard\"]').click()");
      await page.waitFor("location.pathname === '/health-dashboard' && document.querySelector('#health-live')");
      await page.evaluate("document.querySelector('.session-item a[href=\"/sessions/${session.id}\"]').click()");
      await page.waitFor("location.pathname === '/sessions/${session.id}' && document.querySelector('#messages')");
      final restoreEventsBeforeFailure = await page.evaluate('window.__historyRestores') as int;
      rejectNextHistoryRestore = true;
      await page.evaluate('history.back()');
      await page.waitFor(
        "location.pathname === '/health-dashboard' && document.querySelector('#messages') && window.__historyRestores > $restoreEventsBeforeFailure",
      );
      await page.waitFor(
        "document.querySelector('#toast-container .toast-error')?.textContent.length > 0",
        reason: 'The rejected history refetch did not reach the global response-error path',
      );
      final messagesPath = '/sessions/${session.id}/messages-html';
      final messagesRequestsBeforeRecovery = page.requestCount(messagesPath);
      await page.evaluate('''(() => {
        const messages = document.querySelector('#messages');
        messages.scrollTop = 0;
        window.__ordinaryMessageSwap = {before: messages.scrollTop, after: null, finally: false, historyHeader: null};
        document.body.addEventListener('htmx:after:swap', (event) => {
          if (event.detail?.ctx?.sourceElement === messages) {
            window.__ordinaryMessageSwap.after = messages.scrollTop;
            window.__ordinaryMessageSwap.historyHeader =
              event.detail.ctx.request?.headers?.['HX-History-Restore-Request'] || null;
          }
        });
        document.body.addEventListener('htmx:finally:request', (event) => {
          if (event.detail?.ctx?.sourceElement === messages) window.__ordinaryMessageSwap.finally = true;
        });
        htmx.ajax('GET', '$messagesPath', {target: '#messages', swap: 'innerHTML', source: messages});
      })()''');
      await _eventually(
        () => page.requestCount(messagesPath) > messagesRequestsBeforeRecovery,
        reason: 'The ordinary post-history message swap did not run',
      );
      await page.waitFor('window.__ordinaryMessageSwap.after !== null && window.__ordinaryMessageSwap.finally');
      expect(await page.evaluate('window.__ordinaryMessageSwap.historyHeader'), isNull);
      final ordinarySwapScroll = await page.evaluate('''(() => ({
        before: window.__ordinaryMessageSwap.before,
        after: window.__ordinaryMessageSwap.after,
        maximum: document.querySelector('#messages').scrollHeight - document.querySelector('#messages').clientHeight,
      }))()''') as Map;
      expect(ordinarySwapScroll['after'], lessThan((ordinarySwapScroll['before'] as num) + 100));
      expect(
        ordinarySwapScroll['after'],
        lessThan((ordinarySwapScroll['maximum'] as num) - 50),
        reason: 'A failed history restore forced the next ordinary swap to the transcript bottom',
      );
      await page.evaluate('''(() => {
        window.__successfulHistoryForward = {after: false, finally: false};
        document.body.addEventListener('htmx:after:swap', (event) => {
          const ctx = event.detail?.ctx;
          if (ctx?.request?.headers?.['HX-History-Restore-Request'] === 'true' &&
              ctx.request.action.startsWith('/sessions/${session.id}')) {
            window.__successfulHistoryForward.after = true;
          }
        });
        document.body.addEventListener('htmx:finally:request', (event) => {
          const ctx = event.detail?.ctx;
          if (ctx?.request?.headers?.['HX-History-Restore-Request'] === 'true' &&
              ctx.request.action.startsWith('/sessions/${session.id}')) {
            window.__successfulHistoryForward.finally = true;
          }
        });
        history.forward();
      })()''');
      await page.waitFor(
        "location.pathname === '/sessions/${session.id}' && document.querySelector('#messages') && window.__successfulHistoryForward.after && window.__successfulHistoryForward.finally",
      );

      await page.evaluate('''(() => {
        const input = document.querySelector('#message-input');
        input.value = 'navigate during active stream';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        document.querySelector('#chat-form').requestSubmit();
      })()''');
      await worker.turnInvoked.timeout(const Duration(seconds: 10));
      await page.waitFor(
        "document.querySelector('#streaming-msg') && document.querySelector('#message-input').disabled",
      );
      worker.emit(DeltaEvent('Delta before navigation teardown'));
      await page.waitFor(
        "document.querySelector('#streaming-content')?.textContent.includes('Delta before navigation teardown')",
      );
      final activeStreamUrl = page.requestedUrls.lastWhere(
        (url) => Uri.parse(url).path == '/api/sessions/${session.id}/stream',
      );
      final statusPath = '/api/sessions/${session.id}/turn-status';
      await page.evaluate('''(() => {
        window.__navigationSseCloses = [];
        document.querySelector('#streaming-msg').addEventListener('htmx:sse:close', (event) => {
          window.__navigationSseCloses.push({
              reason: event.detail?.reason || null,
              url: event.detail?.connection?.url || null,
          });
        });
      })()''');
      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/settings\"]').click()");
      await page.waitFor("location.pathname === '/settings' && document.querySelector('#main-content')");
      await page.waitFor(
        "window.__navigationSseCloses.some((entry) => ['cleanup', 'removed', 'ended'].includes(entry.reason) && entry.url.includes('/api/sessions/${session.id}/stream'))",
        reason: 'Removing the active chat page did not close its hx-sse connection',
      );
      await _eventually(
        () => page.failedUrls.contains(activeStreamUrl) || page.finishedUrls.contains(activeStreamUrl),
        reason: 'Chrome did not finish the exact SSE transport removed with the chat page',
      );
      expect(await page.evaluate("document.body.classList.contains('streaming')"), isFalse);
      final statusRequestsAfterNavigation = page.requestCount(statusPath);
      await Future<void>.delayed(const Duration(milliseconds: 2700));
      expect(
        page.requestCount(statusPath),
        statusRequestsAfterNavigation,
        reason: 'The detached chat controller kept polling turn status after navigation',
      );
      worker.completeSuccess();
      expect(await page.evaluate("document.querySelectorAll('#main-content').length"), 1);
      expect(await page.evaluate("document.title.includes('Settings')"), isTrue);
      expect(
        await page.evaluate(
          "document.querySelector('.sidebar-nav-item[href=\"/settings\"]').classList.contains('active')",
        ),
        isTrue,
      );
      await page.evaluate("document.querySelector('.tab[href=\"#server\"]').click()");
      await page.waitFor(
        "document.querySelector('.tab[href=\"#server\"]').getAttribute('aria-selected') === 'true' && !document.querySelector('[data-field=port]').closest('[data-tab]').hidden",
        reason: 'The real Server settings tab did not expose the port form',
      );
      final settingsRequests = page.requestCount('/settings');
      await page.evaluate('''(() => {
        const port = document.querySelector('[data-field="port"] input');
        port.removeAttribute('min');
        port.value = '0';
        port.dispatchEvent(new Event('input', {bubbles: true}));
        port.closest('form').requestSubmit();
      })()''');
      await page.waitFor(
        "document.querySelector('[data-field=port] input')?.getAttribute('aria-invalid') === 'true'",
        reason: 'The real Settings form did not render its invalid port response',
      );
      expect(page.requestCount('/settings'), settingsRequests + 1);
      expect(
        await page.evaluate("document.querySelector('[data-field=port] .form-error').textContent"),
        contains('between'),
      );

      await page.evaluate('''(() => {
        window.__settingsLifecycle = [];
        for (const type of ['htmx:after:swap', 'htmx:finally:request']) {
          document.addEventListener(type, (event) => {
            const request = event.detail?.ctx?.request;
            if (request?.method === 'POST' && new URL(request.action, location.href).pathname === '/settings') {
              window.__settingsLifecycle.push({
                type,
                restartVisible: !document.querySelector('#restart-banner')?.hidden,
              });
            }
          });
        }
        const port = document.querySelector('[data-field="port"] input');
        port.value = '8182';
        port.dispatchEvent(new Event('input', {bubbles: true}));
        port.closest('form').requestSubmit();
      })()''');
      await page.waitFor(
        "document.querySelector('[data-field=port] .settings-field-status')?.textContent.includes('restart') || document.querySelector('[data-field=port]')?.textContent.includes('restart required')",
        reason: 'The valid Settings save did not return its restart field status',
      );
      await page.waitFor(
        "document.querySelector('#restart-banner') && !document.querySelector('#restart-banner').hidden && document.querySelector('#restart-banner-fields').textContent.includes('port')",
        reason: 'The settings response did not reconcile its OOB restart banner',
      );
      await page.waitFor(
        "window.__settingsLifecycle.some((entry) => entry.type === 'htmx:finally:request')",
        reason: 'The valid Settings request did not reach request finalization',
      );
      expect(page.requestCount('/settings'), settingsRequests + 2);
      final settingsLifecycle = await page.evaluate('window.__settingsLifecycle') as List;
      expect(
        settingsLifecycle.any(
              (entry) => (entry as Map)['type'] == 'htmx:after:swap' && entry['restartVisible'] == true,
            ) &&
            (settingsLifecycle.last as Map)['type'] == 'htmx:finally:request' &&
            (settingsLifecycle.last as Map)['restartVisible'] == true,
        isTrue,
        reason:
            'The restart OOB region was not ready by the settings swap completion lifecycle: ${jsonEncode(settingsLifecycle)}',
      );
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-settings-desktop.png')));

      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/tasks\"]').click()");
      await page.waitFor("location.pathname === '/tasks' && document.querySelector('#tasks-content')");
      await page.evaluate('''(() => {
        const filter = document.querySelector('#task-status-filter');
        filter.value = 'queued';
        filter.dispatchEvent(new Event('change', {bubbles: true}));
      })()''');
      await page.waitFor("location.search.includes('status=queued') && document.querySelector('#tasks-content')");
      await page.evaluate("htmx.ajax('GET', '/tasks/new', {target: '#new-task-dialog-host', swap: 'innerHTML'})");
      await page.waitFor("document.querySelector('#new-task-panel')");
      await page.evaluate("document.querySelector('#new-task-panel').requestSubmit()");
      await page.waitFor("document.querySelector('#new-task-panel .form-error')?.textContent.length > 0");
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-task-invalid-desktop.png')));
      await page.evaluate('''(() => {
        document.querySelector('#task-title').value = 'Browser-created task';
        document.querySelector('#task-description').value = 'Created through the real HTMX task form';
        document.querySelector('#new-task-panel').requestSubmit();
      })()''');
      await page.waitFor("location.pathname.startsWith('/tasks/') && document.querySelector('#main-content')");
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-task-created-desktop.png')));

      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/workflows\"]').click()");
      await page.waitFor("location.pathname === '/workflows' && document.querySelector('[data-workflow-launch-form]')");
      await page.evaluate("document.querySelector('.workflow-launch-panel').open = true");
      await page.evaluate("document.querySelector('[data-workflow-launch-form]').requestSubmit()");
      await page.waitFor("document.querySelector('[data-workflow-launch-form] .form-error-text')");
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-workflow-invalid-desktop.png')));
      await page.evaluate('''(() => {
        document.querySelector('[name="var_FEATURE"]').value = 'HTMX 4';
        document.querySelector('[data-workflow-launch-form]').requestSubmit();
      })()''');
      await page.waitFor("location.pathname === '/workflows/browser-run' && document.querySelector('#main-content')");
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-workflow-run-desktop.png')));

      await page.evaluate("document.querySelector('.sidebar-nav-item[href=\"/settings\"]').click()");
      await page.waitFor("location.pathname === '/settings' && document.querySelector('#main-content')");

      await page.setViewport(375, 812);
      await page.evaluate('location.reload()');
      await page.waitFor("document.readyState === 'complete' && location.pathname === '/settings'");
      await page.evaluate('document.fonts.ready');
      await page.evaluate("document.querySelector('.menu-toggle').click()");
      await page.waitFor(
        "document.querySelector('#sidebar').classList.contains('open') && document.querySelector('.shell-main').hasAttribute('inert')",
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-settings-mobile.png')));
      await page.evaluate("document.querySelector('.session-item a[href=\"/sessions/${session.id}\"]').click()");
      await page.waitFor("location.pathname === '/sessions/${session.id}' && document.querySelector('#chat-form')");
      expect(await page.evaluate("document.querySelector('#sidebar').classList.contains('open')"), isFalse);
      expect(await page.evaluate("document.querySelector('.shell-main').hasAttribute('inert')"), isFalse);
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-chat-mobile.png')));

      final resetPath = '/api/sessions/${session.id}/reset';
      final beforeCancel = page.requestCount(resetPath);
      await page.evaluate("document.querySelector('.btn-reset').click()");
      await page.waitFor("document.querySelector('dialog[open]')");
      await page.evaluate('document.fonts.ready');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await page.screenshot(File(p.join(artifactDir.path, 'htmx4-reset-confirm-mobile.png')));
      await page.evaluate(
        "[...document.querySelectorAll('dialog button')].find((button) => button.textContent === 'Cancel').click()",
      );
      await page.waitFor("!document.querySelector('dialog')");
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(page.requestCount(resetPath), beforeCancel, reason: 'Cancel must drop the pending HTMX request');

      await page.evaluate("document.querySelector('.btn-reset').click()");
      await page.waitFor("document.querySelector('dialog[open]')");
      await page.evaluate(
        "[...document.querySelectorAll('dialog button')].find((button) => button.textContent === 'Confirm').click()",
      );
      await _eventually(
        () => page.requestCount(resetPath) == beforeCancel + 1,
        reason: 'Confirm did not issue exactly one reset request',
      );
      await page.waitFor(
        "document.readyState === 'complete' && document.querySelectorAll('#messages .msg').length === 0",
      );
      expect(page.requestCount(resetPath), beforeCancel + 1);
      expect(page.exceptions, isEmpty, reason: 'Uncaught browser exceptions: ${page.exceptions.join('\n')}');
      expect(page.consoleErrors, isEmpty, reason: 'Browser console errors: ${page.consoleErrors.join('\n')}');

      final embeddedTemp = Directory.systemTemp.createTempSync('dartclaw_htmx4_embedded_');
      final embeddedSessions = SessionService(baseDir: embeddedTemp.path);
      final embeddedMessages = MessageService(baseDir: embeddedTemp.path);
      final embeddedWorker = FakeAgentHarness();
      final embeddedTurns = composeServerTurns(
        sessions: embeddedSessions,
        messages: embeddedMessages,
        worker: embeddedWorker,
        behavior: BehaviorFileService(workspaceDir: p.join(embeddedTemp.path, 'workspace')),
      );
      final embeddedServer = composeServer(
        core: ServerCoreDeps(
          sessions: embeddedSessions,
          messages: embeddedMessages,
          worker: embeddedWorker,
          assetSource: AssetSource.embedded,
          authEnabled: false,
        ),
        turn: ServerTurnDeps(turns: embeddedTurns),
      );
      final embeddedHttp = await shelf_io.serve(embeddedServer.handler, InternetAddress.loopbackIPv4, 0);
      try {
        await page.navigate('http://${embeddedHttp.address.address}:${embeddedHttp.port}/settings');
        await page.waitFor("window.htmx?.version === '4.0.0' && document.querySelector('#main-content')");
        expect(
          await page.evaluate(
            '''[...document.scripts].every((script) => !script.src || new URL(script.src).origin === location.origin)''',
          ),
          isTrue,
          reason: 'Embedded delivery loaded a script from outside DartClaw',
        );
        expect(page.exceptions, isEmpty, reason: 'Embedded assets raised a browser exception');
        expect(page.consoleErrors, isEmpty, reason: 'Embedded assets raised a console error');
      } finally {
        await embeddedHttp.close(force: true);
        await embeddedServer.shutdown();
        if (embeddedTemp.existsSync()) embeddedTemp.deleteSync(recursive: true);
      }
    } finally {
      await chrome.close();
      await httpServer.close(force: true);
      await server.shutdown();
      await workflows.dispose();
      await taskService.dispose();
      await taskBackend.close();
      await eventBus.dispose();
      resetService.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
