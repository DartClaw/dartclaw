import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/reload_trigger_service.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:fake_async/fake_async.dart';
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
      test('start() registers no subscriptions', () {
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'off'),
          configLoader: loader,
        );
        svc.start();
        expect(loaderCallCount, 0);
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

      test('configLoader exception is caught — ConfigNotifier.reload not called', () async {
        var threw = false;
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: () {
            threw = true;
            throw const FormatException('malformed YAML');
          },
        );

        await svc.doReload();

        expect(threw, true);
        expect(notifier.reloadCalls, isEmpty);
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
      test('start() completes without error on POSIX platforms', () {
        final svc = ReloadTriggerService(
          configPath: '/tmp/dartclaw.yaml',
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'signal'),
          configLoader: loader,
        );
        expect(() => svc.start(), returnsNormally);
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

      test('file-watch event on config filename triggers reload after debounce', () async {
        final svc = ReloadTriggerService(
          configPath: configFile.path,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
        );
        svc.start();

        configFile.writeAsStringSync('# updated\n');

        // Wait beyond debounce period.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(loaderCallCount, greaterThanOrEqualTo(1));
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

      test('file-watch setup failure logs warning and does not throw', () {
        const badPath = '/nonexistent_dartclaw_test_dir_12345/dartclaw.yaml';
        final svc = ReloadTriggerService(
          configPath: badPath,
          notifier: notifier,
          reloadConfig: const ReloadConfig(mode: 'auto', debounceMs: 100),
          configLoader: loader,
        );
        expect(() => svc.start(), returnsNormally);
        svc.dispose();
      });
    });

    group('debounce coalescing via fake_async', () {
      test('5 events within debounce window produce exactly 1 reload', () {
        fakeAsync((clock) {
          final svc = _DebounceTestService(
            debounceMs: 500,
            configLoader: loader,
          );

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
          final svc = _DebounceTestService(
            debounceMs: 500,
            configLoader: loader,
          );

          svc.simulateFileEvent();
          clock.elapse(const Duration(milliseconds: 100));

          svc.dispose();

          clock.elapse(const Duration(milliseconds: 500));

          expect(loaderCallCount, 0);
        });
      });

      test('two separate event bursts produce 2 reloads', () {
        fakeAsync((clock) {
          final svc = _DebounceTestService(
            debounceMs: 200,
            configLoader: loader,
          );

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
