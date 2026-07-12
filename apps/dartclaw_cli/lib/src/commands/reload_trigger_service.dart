import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart'
    show ConfigNotifier, DartclawConfig, PlatformCapabilities, ReloadConfig, UnsupportedCapabilityError;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ReloadTriggerService');

/// Manages live-reload trigger mechanisms for [ConfigNotifier].
///
/// Supports two modes (controlled by [ReloadConfig.mode]):
/// - `'signal'` (default): POSIX-only SIGUSR1.
/// - `'auto'`: cross-platform file-watch, plus SIGUSR1 where available.
/// - `'off'`: no triggers registered.
///
/// File-watch uses parent directory watching (not direct file watching) to
/// handle atomic writes (temp + rename) correctly. The rename surfaces as a
/// create/modify event on macOS kqueue but as a move event on Linux inotify,
/// so all three event types are watched.
///
/// Debounce coalesces rapid file-system events into a single reload call.
class ReloadTriggerService {
  final String _configPath;
  final ConfigNotifier _notifier;
  final ReloadConfig _reloadConfig;
  final DartclawConfig Function() _configLoader;
  final PlatformCapabilities _platformCapabilities;
  final Stream<ProcessSignal> Function() _sigusr1Watch;
  final Stream<FileSystemEvent> Function(String path) _fileWatch;

  StreamSubscription<ProcessSignal>? _sigusr1Sub;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _debounceTimer;

  ReloadTriggerService({
    required String configPath,
    required ConfigNotifier notifier,
    required ReloadConfig reloadConfig,
    DartclawConfig Function()? configLoader,
    PlatformCapabilities? platformCapabilities,
    Stream<ProcessSignal> Function()? sigusr1Watch,
    Stream<FileSystemEvent> Function(String path)? fileWatch,
  }) : _configPath = configPath,
       _notifier = notifier,
       _reloadConfig = reloadConfig,
       _configLoader = configLoader ?? (() => DartclawConfig.load(configPath: configPath)),
       _platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _sigusr1Watch = sigusr1Watch ?? (() => ProcessSignal.sigusr1.watch()),
       _fileWatch =
           fileWatch ??
           ((path) =>
               Directory(path).watch(events: FileSystemEvent.create | FileSystemEvent.modify | FileSystemEvent.move));

  /// Registers SIGUSR1 handler (POSIX-only) and optionally sets up file-watch.
  ///
  /// Signal mode is POSIX-only. File-watch (`auto`) works on every platform,
  /// including Windows. File-watch setup failures are caught and logged.
  void start() {
    if (_reloadConfig.mode == 'off') return;

    if (_platformCapabilities.posixSignalsAvailable) {
      _sigusr1Sub = _sigusr1Watch().listen((_) {
        _log.info('ReloadTriggerService: SIGUSR1 received — triggering config reload');
        unawaited(_doReload());
      });
    } else if (_reloadConfig.mode == 'signal') {
      const error = UnsupportedCapabilityError(
        capability: 'signal-based config reload',
        attemptedContext: 'gateway.reload.mode: signal on a platform without POSIX signals',
        remediation: 'Set gateway.reload.mode to "auto" to use cross-platform file-watch reload.',
      );
      _log.warning(error.toString(), error);
    }

    if (_reloadConfig.mode == 'auto') {
      _startFileWatch();
    }
  }

  void _startFileWatch() {
    final parentDir = p.dirname(p.absolute(_configPath));
    final configFilename = p.basename(_configPath);

    try {
      _watchSub = _fileWatch(parentDir).listen((event) {
        // Atomic saves (write temp + rename over target) surface as a move on
        // Linux inotify, where the destination — not the source path — carries
        // the config filename.
        final changedName = event is FileSystemMoveEvent && event.destination != null
            ? p.basename(event.destination!)
            : p.basename(event.path);
        if (changedName != configFilename) return;
        _log.info('ReloadTriggerService: config file change detected — debouncing');
        _debounceTimer?.cancel();
        _debounceTimer = Timer(Duration(milliseconds: _reloadConfig.debounceMs), () {
          _log.info('ReloadTriggerService: debounce elapsed — triggering config reload');
          unawaited(_doReload());
        });
      }, onError: (Object error, StackTrace stackTrace) => _logFileWatchFailure(parentDir, error, stackTrace));
    } on FileSystemException catch (e, st) {
      _logFileWatchFailure(parentDir, e, st);
    }
  }

  void _logFileWatchFailure(String parentDir, Object error, StackTrace stackTrace) {
    final fallback = _platformCapabilities.posixSignalsAvailable
        ? 'falling back to SIGUSR1-only mode'
        : 'config reload remains unavailable';
    _log.warning(
      'ReloadTriggerService: file-watch setup failed for $parentDir — $fallback ($error)',
      error,
      stackTrace,
    );
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
