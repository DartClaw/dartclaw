import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ReloadTriggerService');

/// Manages live-reload trigger mechanisms for [ConfigNotifier].
///
/// Supports two modes (controlled by [ReloadConfig.mode]):
/// - `'signal'` (default): SIGUSR1 only.
/// - `'auto'`: SIGUSR1 + file-watch on parent directory of config file.
/// - `'off'`: no triggers registered.
///
/// File-watch uses parent directory watching (not direct file watching) to
/// handle atomic writes (temp + rename) correctly on macOS kqueue.
///
/// Debounce coalesces rapid file-system events into a single reload call.
class ReloadTriggerService {
  final String _configPath;
  final ConfigNotifier _notifier;
  final ReloadConfig _reloadConfig;
  final DartclawConfig Function() _configLoader;

  StreamSubscription<ProcessSignal>? _sigusr1Sub;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _debounceTimer;

  ReloadTriggerService({
    required String configPath,
    required ConfigNotifier notifier,
    required ReloadConfig reloadConfig,
    DartclawConfig Function()? configLoader,
  })  : _configPath = configPath,
        _notifier = notifier,
        _reloadConfig = reloadConfig,
        _configLoader = configLoader ?? (() => DartclawConfig.load(configPath: configPath));

  /// Registers SIGUSR1 handler (POSIX-only) and optionally sets up file-watch.
  ///
  /// Safe to call on Windows — SIGUSR1 registration is skipped.
  /// File-watch setup failures are caught and logged; server continues with
  /// SIGUSR1-only mode.
  void start() {
    if (_reloadConfig.mode == 'off') return;

    if (!Platform.isWindows) {
      _sigusr1Sub = ProcessSignal.sigusr1.watch().listen((_) {
        _log.info('ReloadTriggerService: SIGUSR1 received — triggering config reload');
        unawaited(_doReload());
      });
    }

    if (_reloadConfig.mode == 'auto') {
      _startFileWatch();
    }
  }

  void _startFileWatch() {
    final parentDir = p.dirname(p.absolute(_configPath));
    final configFilename = p.basename(_configPath);

    try {
      _watchSub = Directory(parentDir)
          .watch(events: FileSystemEvent.create | FileSystemEvent.modify)
          .listen((event) {
        if (p.basename(event.path) != configFilename) return;
        _log.info('ReloadTriggerService: config file change detected — debouncing');
        _debounceTimer?.cancel();
        _debounceTimer = Timer(Duration(milliseconds: _reloadConfig.debounceMs), () {
          _log.info('ReloadTriggerService: debounce elapsed — triggering config reload');
          unawaited(_doReload());
        });
      });
    } on FileSystemException catch (e) {
      _log.warning(
        'ReloadTriggerService: file-watch setup failed for $parentDir — '
        'falling back to SIGUSR1-only mode ($e)',
      );
    }
  }

  /// Performs a config reload cycle. Exposed for testing.
  @visibleForTesting
  Future<void> doReload() => _doReload();

  Future<void> _doReload() async {
    DartclawConfig newConfig;
    try {
      newConfig = _configLoader();
    } catch (e) {
      _log.warning('ReloadTriggerService: config reload failed — keeping existing config ($e)');
      return;
    }

    final delta = _notifier.reload(newConfig);
    if (delta == null) {
      _log.info('ReloadTriggerService: reload complete — no reloadable changes detected');
    } else {
      _log.info(
        'ReloadTriggerService: reload applied — changed sections: '
        '${delta.changedKeys.join(', ')}',
      );
    }
  }

  /// Cancels all subscriptions and pending debounce timer. Idempotent.
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _sigusr1Sub?.cancel();
    _sigusr1Sub = null;
    _watchSub?.cancel();
    _watchSub = null;
  }
}
