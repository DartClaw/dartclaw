import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/reload_trigger_service.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

class _PrintingConfigNotifier extends ConfigNotifier {
  _PrintingConfigNotifier(super.initial);

  @override
  ConfigDelta? reload(DartclawConfig newConfig) {
    final delta = super.reload(newConfig);
    stdout.writeln('DELTA:${delta?.changedKeys.join(",") ?? "none"}');
    stdout.writeln('MAX_PARALLEL:${newConfig.server.maxParallelTurns}');
    return delta;
  }
}

Future<void> main(List<String> args) async {
  try {
    final configPath = args.single;
    final notifier = _PrintingConfigNotifier(DartclawConfig.load(configPath: configPath));
    final service = ReloadTriggerService(
      configPath: configPath,
      notifier: notifier,
      reloadConfig: const ReloadConfig(mode: 'signal'),
      configLoader: () => DartclawConfig.load(configPath: configPath),
    );

    service.start();
    ProcessSignal.sigterm.watch().listen((_) {
      service.dispose();
      exit(0);
    });

    stdout.writeln('READY:$pid');
    await Completer<void>().future;
  } catch (error, stackTrace) {
    stderr.writeln('PROBE_ERROR:$error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}
