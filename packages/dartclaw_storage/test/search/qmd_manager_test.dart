import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');
ProcessResult _fail([String stderr = 'error']) => ProcessResult(0, 1, '', stderr);

void main() {
  late List<(String, List<String>, String?)> calls;

  setUp(() {
    calls = [];
  });

  Future<ProcessResult> fakeRunner(String exe, List<String> args, {String? workingDirectory}) async {
    calls.add((exe, args, workingDirectory));
    if (args.contains('--version')) return _ok('qmd 2.5.3');
    if (args.contains('update')) return _ok();
    if (args.contains('embed')) return _ok();
    if (args.contains('collection')) {
      return _ok(
        'Collection: memory\n'
        '  Path:     /home/user/.dartclaw/workspace\n'
        '  Pattern:  **/*.md\n'
        '  Include:  yes (default)\n',
      );
    }
    if (args.contains('mcp')) return _ok();
    return _ok();
  }

  group('QmdManager', () {
    test('isAvailable returns true when binary exists', () async {
      final mgr = QmdManager(commandRunner: fakeRunner);
      expect(await mgr.isAvailable(), isTrue);
    });

    test('isAvailable returns false when binary missing', () async {
      final mgr = QmdManager(commandRunner: (exe, args, {workingDirectory}) async => _fail());
      expect(await mgr.isAvailable(), isFalse);
    });

    test('isAvailable returns false when the version probe stalls', () async {
      final stalled = Completer<ProcessResult>().future;
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) => stalled,
        commandTimeoutOverride: const Duration(milliseconds: 10),
      );

      expect(await mgr.isAvailable(), isFalse);
    });

    test('production runner force-kills a process that ignores termination', () async {
      final process = _FakeProcess.running(ignoreFirstKill: true);
      final mgr = QmdManager(
        processStarter: (
          executable,
          arguments, {
          workingDirectory,
          required environment,
          required includeParentEnvironment,
        }) async => process,
        commandTimeoutOverride: const Duration(milliseconds: 1),
        killGracePeriod: Duration.zero,
      );

      expect(await mgr.isAvailable(), isFalse);
      expect(process.killSignals, [
        ProcessSignal.sigterm,
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
      ]);
    });

    test('production runner starts QMD with only the minimal parent environment', () async {
      Map<String, String>? capturedEnvironment;
      bool? capturedIncludeParentEnvironment;
      final mgr = QmdManager(
        processStarter:
            (executable, arguments, {workingDirectory, required environment, required includeParentEnvironment}) async {
              capturedEnvironment = environment;
              capturedIncludeParentEnvironment = includeParentEnvironment;
              return _FakeProcess.completed(stdoutText: 'qmd 2.5.3');
            },
      );

      expect(await mgr.isAvailable(), isTrue);
      expect(capturedIncludeParentEnvironment, isFalse);
      expect(
        capturedEnvironment!.keys,
        everyElement(
          predicate<String>(
            (key) => const {
              'PATH',
              'HOME',
              'LANG',
              'LANGUAGE',
              'LC_ALL',
              'LC_COLLATE',
              'LC_CTYPE',
              'LC_MESSAGES',
              'LC_MONETARY',
              'LC_NUMERIC',
              'LC_TIME',
              'TZ',
              'USER',
              'SHELL',
              'TERM',
              'TMPDIR',
              'TMP',
              'TEMP',
              'SYSTEMROOT',
              'COMSPEC',
              'PATHEXT',
              'LOCALAPPDATA',
              'APPDATA',
              'USERPROFILE',
            }.contains(key.toUpperCase()),
          ),
        ),
      );
      for (final key in ['PATH', 'HOME']) {
        if (Platform.environment[key] case final value?) expect(capturedEnvironment, containsPair(key, value));
      }
    });

    for (final output in ['stdout', 'stderr']) {
      test('production runner terminates QMD when $output exceeds its byte cap', () async {
        final bytes = List<int>.filled(1024 * 1024 + 1, 0x61);
        final process = _FakeProcess.running(
          stdoutBytes: output == 'stdout' ? bytes : const [],
          stderrBytes: output == 'stderr' ? bytes : const [],
        );
        final mgr = QmdManager(
          processStarter: (
            executable,
            arguments, {
            workingDirectory,
            required environment,
            required includeParentEnvironment,
          }) async => process,
        );

        await expectLater(
          mgr.triggerIndex(),
          throwsA(isA<StateError>().having((error) => error.message, 'message', contains('$output exceeded'))),
        );
        expect(process.wasKilled, isTrue);
      });
    }

    for (final version in ['qmd 2.5.3', 'qmd 2.6.0', 'qmd 2.5.3 (a1b2c3d)']) {
      test('isAvailable accepts compatible version output $version', () async {
        final mgr = QmdManager(commandRunner: (exe, args, {workingDirectory}) async => _ok(version));
        expect(await mgr.isAvailable(), isTrue);
      });
    }

    test('isAvailable rejects unrelated successful output', () async {
      final mgr = QmdManager(commandRunner: (exe, args, {workingDirectory}) async => _ok('not qmd'));
      expect(await mgr.isAvailable(), isFalse);
    });

    for (final version in ['qmd 1.1.0', 'qmd 2.5.2', 'qmd 2.5.3-beta.1', 'qmd 3.0.0']) {
      test('isAvailable rejects unsupported version $version', () async {
        final mgr = QmdManager(commandRunner: (exe, args, {workingDirectory}) async => _ok(version));
        expect(await mgr.isAvailable(), isFalse);
      });
    }

    test('triggerIndex runs update then embed', () async {
      final mgr = QmdManager(commandRunner: fakeRunner, workspaceDir: '/tmp');
      await mgr.triggerIndex();

      expect(calls, hasLength(2));
      expect(calls[0].$2, ['--index', 'index', 'update']);
      expect(calls[1].$2, ['--index', 'index', 'embed']);
      // Both use workingDirectory
      expect(calls[0].$3, '/tmp');
      expect(calls[1].$3, '/tmp');
    });

    test('triggerIndex fails when initial update fails', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async =>
            args.contains('update') ? _fail('update failed') : _ok(),
      );

      await expectLater(mgr.triggerIndex(), throwsA(isA<StateError>()));
    });

    test('triggerIndex fails when initial embed fails', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async => args.contains('embed') ? _fail('embed failed') : _ok(),
      );

      await expectLater(mgr.triggerIndex(), throwsA(isA<StateError>()));
    });

    for (final stalledCommand in ['update', 'embed']) {
      test('triggerIndex times out when $stalledCommand stalls', () async {
        final stalled = Completer<ProcessResult>().future;
        final mgr = QmdManager(
          commandRunner: (exe, args, {workingDirectory}) async => args.contains(stalledCommand) ? await stalled : _ok(),
          commandTimeoutOverride: const Duration(milliseconds: 10),
        );

        await expectLater(mgr.triggerIndex(), throwsA(isA<TimeoutException>()));
      });
    }

    test('activate is restart-safe across two starts', () async {
      final mgr = _StartTrackingQmdManager(commandRunner: fakeRunner);

      await mgr.activate();
      await mgr.activate();

      expect(mgr.startCalls, 2);
      expect(calls.map((call) => call.$2), [
        ['--index', 'index', 'collection', 'show', 'memory'],
        ['--index', 'index', 'update'],
        ['--index', 'index', 'embed'],
        ['--index', 'index', 'collection', 'show', 'memory'],
        ['--index', 'index', 'update'],
        ['--index', 'index', 'embed'],
      ]);
    });

    for (final failedCommand in ['update', 'embed']) {
      test('activate does not start after $failedCommand failure', () async {
        final mgr = _StartTrackingQmdManager(
          commandRunner: (exe, args, {workingDirectory}) async {
            if (args.contains('show')) {
              return _ok('Collection: memory\n  Path:     /home/user/.dartclaw/workspace\n  Pattern:  **/*.md\n');
            }
            return args.contains(failedCommand) ? _fail('$failedCommand failed') : _ok();
          },
        );

        await expectLater(mgr.activate(), throwsA(isA<StateError>()));

        expect(mgr.startCalls, 0);
      });
    }

    test('setupCollection adds an absent recursive Markdown collection', () async {
      Future<ProcessResult> runner(String exe, List<String> args, {String? workingDirectory}) async {
        calls.add((exe, args, workingDirectory));
        if (args.contains('show')) return _fail('Collection not found: memory');
        return _ok();
      }

      final mgr = QmdManager(commandRunner: runner);
      await mgr.setupCollection('/home/user/.dartclaw/workspace');

      expect(calls, hasLength(2));
      expect(calls[0].$2, ['--index', 'index', 'collection', 'show', 'memory']);
      expect(calls[1].$2, [
        '--index',
        'index',
        'collection',
        'add',
        '/home/user/.dartclaw/workspace',
        '--name',
        'memory',
        '--mask',
        '**/*.md',
      ]);
    });

    test('setupCollection is restart-safe for production QMD 2.5.3 output', () async {
      final mgr = QmdManager(commandRunner: fakeRunner);

      await mgr.setupCollection('/home/user/.dartclaw/workspace');
      await mgr.setupCollection('/home/user/.dartclaw/workspace');

      expect(calls, hasLength(2));
      expect(calls.map((call) => call.$2), everyElement(['--index', 'index', 'collection', 'show', 'memory']));
    });

    test('setupCollection rejects an existing collection with the wrong corpus', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async =>
            _ok('Collection: memory\n  Path:     /home/user/.dartclaw/workspace\n  Pattern:  *.md\n'),
      );

      await expectLater(
        mgr.setupCollection('/home/user/.dartclaw/workspace'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('pattern **/*.md'))
              .having((e) => e.message, 'recovery command', contains('qmd --index index collection remove memory')),
        ),
      );
    });

    test('setupCollection rejects an existing collection for another workspace', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async =>
            _ok('Collection: memory\n  Path:     /other/workspace\n  Pattern:  **/*.md\n'),
      );

      await expectLater(
        mgr.setupCollection('/home/user/.dartclaw/workspace'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('must use path'))),
      );
    });

    test('setupCollection fails when an absent collection cannot be added', () async {
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) async =>
            args.contains('show') ? _fail('Collection not found: memory') : _fail('denied'),
      );

      await expectLater(
        mgr.setupCollection('/workspace'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('denied'))),
      );
    });

    test('setupCollection times out when collection discovery stalls', () async {
      final stalled = Completer<ProcessResult>().future;
      final mgr = QmdManager(
        commandRunner: (exe, args, {workingDirectory}) => stalled,
        commandTimeoutOverride: const Duration(milliseconds: 10),
      );

      await expectLater(mgr.setupCollection('/workspace'), throwsA(isA<TimeoutException>()));
    });

    test('baseUrl reflects host and port', () {
      final mgr = QmdManager(host: '127.0.0.1', port: 9090);
      expect(mgr.baseUrl, 'http://127.0.0.1:9090');
    });

    test('accepts only literal loopback QMD hosts', () {
      expect(QmdManager(host: 'localhost').host, 'localhost');
      expect(QmdManager(host: '127.42.0.9').host, '127.42.0.9');
      expect(QmdManager(host: '::1').baseUrl, 'http://[::1]:8181');
      expect(QmdManager(host: '[::1]').host, '::1');

      for (final host in ['0.0.0.0', '192.168.1.2', 'localhost.example', '127.0.0.256']) {
        expect(() => QmdManager(host: host), throwsArgumentError, reason: host);
      }
    });

    test('query sends the QMD 2.5.3 REST shape and normalizes results', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Map<String, dynamic>? body;
      server.listen((request) async {
        body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'results': [
              {'file': 'qmd://memory/note.md', 'snippet': '1: matching text', 'score': 0.9},
            ],
          }),
        );
        await request.response.close();
      });
      final mgr = QmdManager(host: InternetAddress.loopbackIPv4.address, port: server.port);

      final results = await mgr.query('matching', depth: 'lex+vec', limit: 4);

      expect(body, {
        'searches': [
          {'type': 'lex', 'query': 'matching'},
          {'type': 'vec', 'query': 'matching'},
        ],
        'limit': 4,
        'rerank': false,
      });
      expect((results.single['text'], results.single['source']), ('1: matching text', 'qmd://memory/note.md'));
    });

    test('query times out when the response body stalls after headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final releaseBody = Completer<void>();
      final bodyStarted = Completer<void>();
      addTearDown(() async {
        if (!releaseBody.isCompleted) releaseBody.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"results":[');
        await request.response.flush();
        bodyStarted.complete();
        await releaseBody.future;
        await request.response.close();
      });
      final mgr = QmdManager(
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
        commandTimeoutOverride: const Duration(milliseconds: 250),
      );

      final query = mgr.query('stalled');
      await bodyStarted.future.timeout(const Duration(seconds: 1));
      await expectLater(query, throwsA(isA<TimeoutException>()));
    });

    test('query rejects an HTTP response body that exceeds its byte cap', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.add(List<int>.filled(1024 * 1024 + 1, 0x20));
        await request.response.close();
      });
      final mgr = QmdManager(host: InternetAddress.loopbackIPv4.address, port: server.port);

      await expectLater(
        mgr.query('oversized'),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('HTTP response body exceeded'))),
      );
    });

    for (final response in [
      ('legacy list fields', '[{"text":"match","source":7}]'),
      ('structured result fields', '{"results":[{"file":"note.md","snippet":"match","category":7}]}'),
    ]) {
      test('query rejects malformed ${response.$1} with FormatException', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write(response.$2);
          await request.response.close();
        });
        final mgr = QmdManager(host: InternetAddress.loopbackIPv4.address, port: server.port);

        await expectLater(mgr.query('malformed'), throwsA(isA<FormatException>()));
      });
    }

    test('start and stop use the QMD 2.5.3 host and lifecycle commands', () async {
      final mgr = _LifecycleQmdManager(commandRunner: fakeRunner);

      await mgr.start();
      await mgr.stop();

      expect(calls, hasLength(2));
      expect(calls[0].$1, 'qmd');
      expect(calls[0].$2, ['--index', 'index', 'mcp', '--http', '--daemon', '--port', '9191', '--host', '127.0.0.2']);
      expect(calls[0].$3, '/workspace');
      expect(calls[1].$1, 'qmd');
      expect(calls[1].$2, ['--index', 'index', 'mcp', 'stop']);
      expect(calls[1].$3, '/workspace');
      expect(mgr.isRunning, isFalse);
    });

    test('start stops the spawned daemon when health never becomes ready', () async {
      final mgr = _NeverHealthyQmdManager(commandRunner: fakeRunner);

      await expectLater(mgr.start(), throwsA(isA<StateError>()));

      expect(calls.map((call) => call.$2), [
        ['--index', 'index', 'mcp', '--http', '--daemon', '--port', '9191', '--host', '127.0.0.2'],
        ['--index', 'index', 'mcp', 'stop'],
      ]);
      expect(mgr.isRunning, isFalse);
    });

    test('start reports failed cleanup after an unsuccessful health check', () async {
      final mgr = _NeverHealthyQmdManager(
        commandRunner: (exe, args, {workingDirectory}) async => args.last == 'stop' ? _fail('stop denied') : _ok(),
      );

      await expectLater(
        mgr.start(),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('cleanup failed: stop denied'))),
      );

      expect(mgr.isRunning, isFalse);
    });

    test('start times out when daemon startup stalls', () async {
      final stalled = Completer<ProcessResult>().future;
      final mgr = _LifecycleQmdManager(
        commandRunner: (exe, args, {workingDirectory}) => stalled,
        commandTimeoutOverride: const Duration(milliseconds: 10),
      );

      await expectLater(mgr.start(), throwsA(isA<TimeoutException>()));
      expect(mgr.isRunning, isFalse);
    });

    test('stop times out when daemon shutdown stalls', () async {
      final stalled = Completer<ProcessResult>().future;
      final mgr = _LifecycleQmdManager(
        commandRunner: (exe, args, {workingDirectory}) async => args.last == 'stop' ? await stalled : _ok(),
        commandTimeoutOverride: const Duration(milliseconds: 10),
      );
      await mgr.start();

      await expectLater(mgr.stop(), throwsA(isA<TimeoutException>()));
      expect(mgr.isRunning, isTrue);
    });
  });
}

class _StartTrackingQmdManager extends QmdManager {
  new({required super.commandRunner}) : super(workspaceDir: '/home/user/.dartclaw/workspace');

  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
  }
}

class _LifecycleQmdManager extends QmdManager {
  new({required super.commandRunner, super.commandTimeoutOverride})
    : super(host: '127.0.0.2', port: 9191, workspaceDir: '/workspace', healthRetryDelay: Duration.zero);

  @override
  Future<bool> healthCheck() async => true;
}

class _NeverHealthyQmdManager extends QmdManager {
  new({required super.commandRunner})
    : super(host: '127.0.0.2', port: 9191, workspaceDir: '/workspace', healthRetryDelay: Duration.zero);

  @override
  Future<bool> healthCheck() async => false;
}

final class _FakeProcess implements Process {
  final Future<int> _exitCode;
  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  final Completer<int>? _exitCompleter;
  final bool _ignoreFirstKill;

  new completed({String stdoutText = '', String stderrText = '', int exitCode = 0})
    : _exitCode = Future.value(exitCode),
      _stdout = Stream.value(utf8.encode(stdoutText)),
      _stderr = Stream.value(utf8.encode(stderrText)),
      _exitCompleter = null,
      _ignoreFirstKill = false;

  new running({List<int> stdoutBytes = const [], List<int> stderrBytes = const [], bool ignoreFirstKill = false})
    : _exitCompleter = Completer<int>(),
      _exitCode = Future.value(0),
      _stdout = Stream.value(stdoutBytes),
      _stderr = Stream.value(stderrBytes),
      _ignoreFirstKill = ignoreFirstKill;

  bool wasKilled = false;
  final killSignals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => _exitCompleter?.future ?? _exitCode;

  @override
  int get pid => 123;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  IOSink get stdin => throw UnsupportedError('stdin is not used by QmdManager');

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    killSignals.add(signal);
    if (_ignoreFirstKill && killSignals.length == 1) return true;
    if (_exitCompleter case final completer? when !completer.isCompleted) completer.complete(-1);
    return true;
  }
}
