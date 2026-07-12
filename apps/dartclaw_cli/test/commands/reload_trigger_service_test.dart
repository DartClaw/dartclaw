import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/reload_trigger_service.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// Simple test double for ConfigNotifier that tracks reload() calls.
class _TrackingConfigNotifier extends ConfigNotifier {
  final List<DartclawConfig> reloadCalls = [];

  _TrackingConfigNotifier(super.initial);

  @override
  ConfigDelta? reload(DartclawConfig newConfig) {
    reloadCalls.add(newConfig);
    return super.reload(newConfig);
  }
}

DartclawConfig _defaultConfig() => DartclawConfig.load();

void main() {
  group('ReloadTriggerService', () {
    late _TrackingConfigNotifier notifier;
    late DartclawConfig config;
    late DartclawConfig newConfig;
    late int loaderCallCount;
    late DartclawConfig Function() loader;

    setUp(() {
      config = _defaultConfig();
      newConfig = _defaultConfig();
      notifier = _TrackingConfigNotifier(config);
      loaderCallCount = 0;
      loader = () {
        loaderCallCount++;
        return newConfig;
      };
    });

    group('mode: off', () {
      test('start() registers no subscriptions or unsupported-capability warning', () async {
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        addTearDown(logSub.cancel);
        var signalWatchCalls = 0;
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'off'),
          configLoader: loader,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
          sigusr1Watch: () {
            signalWatchCalls++;
            return const Stream.empty();
          },
        );
        svc.start();
        await Future<void>.delayed(Duration.zero);
        expect(loaderCallCount, 0);
        expect(signalWatchCalls, 0);
        expect(records.where((record) => record.error is UnsupportedCapabilityError), isEmpty);
        svc.dispose();
      });

      test('dispose() is idempotent when nothing was started', () {
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'off'),
          configLoader: loader,
        );
        svc.dispose();
        svc.dispose();
      });
    });

    group('doReload() — core reload path', () {
      test('calls configLoader and ConfigNotifier.reload() on success', () async {
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: loader,
        );

        await svc.doReload();

        expect(loaderCallCount, 1);
        expect(notifier.reloadCalls, hasLength(1));
      });

      test('invalid reload keeps active config and logs the failure', () async {
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        addTearDown(logSub.cancel);
        final activeConfig = notifier.current;
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: () => throw const FormatException('malformed YAML'),
        );

        await expectLater(svc.doReload(), completes);

        expect(notifier.current, same(activeConfig));
        expect(notifier.reloadCalls, isEmpty);
        expect(records.map((record) => record.message), contains(contains('config reload failed')));
      });

      test('doReload logs info when no reloadable changes detected', () async {
        // Config is same as current — no changes.
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: () => config, // returns the same config
        );

        // Should complete without error even when delta is null.
        await svc.doReload();

        expect(notifier.reloadCalls, hasLength(1));
      });
    });

    group('mode: signal', () {
      test('unsupported signal reload reports the structured capability error', () async {
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        addTearDown(logSub.cancel);
        var signalWatchCalls = 0;
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: loader,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
          sigusr1Watch: () {
            signalWatchCalls++;
            return const Stream.empty();
          },
        );

        svc.start();
        await Future<void>.delayed(Duration.zero);

        expect(signalWatchCalls, 0);
        final error = records.map((record) => record.error).whereType<UnsupportedCapabilityError>().single;
        expect(error.capability, contains('signal-based config reload'));
        expect(error.attemptedContext, contains('signal'));
        expect(error.remediation, allOf(contains('auto'), contains('file-watch')));
        svc.dispose();
      });

      test('available POSIX signals register the SIGUSR1 subscription', () {
        var signalWatchCalls = 0;
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: loader,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
          sigusr1Watch: () {
            signalWatchCalls++;
            return const Stream.empty();
          },
        );
        expect(() => svc.start(), returnsNormally);
        expect(signalWatchCalls, 1);
        svc.dispose();
      });
    });

    group('mode: auto — file-watch integration', () {
      late Directory tempDir;
      late File configFile;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('reload_trigger_test_');
        configFile = File('${tempDir.path}/dartclaw.yaml');
        // Do NOT write configFile here — each test writes as needed to avoid
        // spurious filesystem events that arrive after watch() starts.
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('Windows file-watch applies an atomic config change without restart', () async {
        configFile.writeAsStringSync('# initial\n');
        newConfig = config.copyWith(server: const ServerConfig(maxParallelTurns: 7));
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        addTearDown(logSub.cancel);
        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        );
        svc.start();

        final tempFile = File('${tempDir.path}/dartclaw.yaml.tmp');
        tempFile.writeAsStringSync('# updated\n');
        tempFile.renameSync(configFile.path);

        // Wait beyond debounce period.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(loaderCallCount, greaterThanOrEqualTo(1));
        expect(notifier.current.server.maxParallelTurns, 7);
        expect(records.map((record) => record.message), contains(contains('changed sections: server.*')));
        svc.dispose();
      });

      test('events for unrelated files in parent directory are ignored', () async {
        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
        );
        svc.start();

        // Write to a different file — must not trigger a reload.
        File('${tempDir.path}/other.yaml').writeAsStringSync('# other\n');

        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(loaderCallCount, 0);
        svc.dispose();
      });

      test('rapid successive saves coalesce into single reload', () async {
        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 200),
          configLoader: loader,
        );
        svc.start();

        // 5 rapid writes within debounce window.
        for (var i = 0; i < 5; i++) {
          configFile.writeAsStringSync('# update $i\n');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Wait for debounce to settle.
        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(loaderCallCount, 1);
        svc.dispose();
      });

      test('atomic-save rename to config filename triggers reload after debounce', () async {
        configFile.writeAsStringSync('# initial\n');

        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
        );
        svc.start();

        final tempFile = File('${tempDir.path}/dartclaw.yaml.tmp');
        tempFile.writeAsStringSync('# renamed update\n');
        tempFile.renameSync(configFile.path);

        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(loaderCallCount, 1);
        svc.dispose();
      });

      test('dispose() during pending debounce cancels timer — no reload fires', () async {
        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 300),
          configLoader: loader,
        );
        svc.start();

        configFile.writeAsStringSync('# updated\n');
        // Dispose before debounce fires.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        svc.dispose();

        await Future<void>.delayed(const Duration(milliseconds: 500));

        expect(loaderCallCount, 0);
      });

      test('Windows file-watch setup failure reports that reload remains unavailable', () async {
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        addTearDown(logSub.cancel);
        const badPath = '/nonexistent_dartclaw_test_dir_12345/dartclaw.yaml';
        final svc = ReloadTriggerService(
          configPath: badPath,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
          fileWatch: (_) => Stream.error(const FileSystemException('not found')),
        );
        expect(() => svc.start(), returnsNormally);
        await Future<void>.delayed(Duration.zero);
        expect(records.map((record) => record.message), contains(contains('config reload remains unavailable')));
        expect(records.map((record) => record.message).join('\n'), isNot(contains('SIGUSR1-only')));
        svc.dispose();
      });
    });

    group('debounce coalescing via fake_async', () {
      test('5 events within debounce window produce exactly 1 reload', () {
        fakeAsync((clock) {
          final svc = _DebounceTestService(debounceMs: 500, configLoader: loader);

          for (var i = 0; i < 5; i++) {
            svc.simulateFileEvent();
            clock.elapse(const Duration(milliseconds: 50));
          }

          expect(loaderCallCount, 0); // debounce not yet elapsed

          clock.elapse(const Duration(milliseconds: 500));

          expect(loaderCallCount, 1);
          svc.dispose();
        });
      });

      test('dispose during pending debounce cancels reload', () {
        fakeAsync((clock) {
          final svc = _DebounceTestService(debounceMs: 500, configLoader: loader);

          svc.simulateFileEvent();
          clock.elapse(const Duration(milliseconds: 100));

          svc.dispose();

          clock.elapse(const Duration(milliseconds: 500));

          expect(loaderCallCount, 0);
        });
      });

      test('two separate event bursts produce 2 reloads', () {
        fakeAsync((clock) {
          final svc = _DebounceTestService(debounceMs: 200, configLoader: loader);

          // First burst.
          svc.simulateFileEvent();
          svc.simulateFileEvent();
          clock.elapse(const Duration(milliseconds: 300));
          expect(loaderCallCount, 1);

          // Second burst.
          svc.simulateFileEvent();
          clock.elapse(const Duration(milliseconds: 300));
          expect(loaderCallCount, 2);

          svc.dispose();
        });
      });
    });
  });
}

/// Test-only shim that isolates the debounce Timer pattern from real I/O,
/// allowing fake_async to control time precisely.
class _DebounceTestService {
  final int debounceMs;
  final DartclawConfig Function() configLoader;
  Timer? _timer;

  _DebounceTestService({required this.debounceMs, required this.configLoader});

  void simulateFileEvent() {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: debounceMs), () {
      configLoader();
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
