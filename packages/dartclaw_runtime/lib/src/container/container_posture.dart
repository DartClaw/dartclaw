import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'container_manager.dart';

final _log = Logger('ContainerPosture');

/// Settles the container posture once, before anything wires against it.
///
/// An unset `container.enabled` means "isolate if this host can": the probe
/// decides, it never blocks startup, and every later refusal downgrades to
/// advisory mode. A declared posture is carried through untouched, so an
/// explicit `true` keeps its fail-closed refusals and an explicit `false` is
/// never overridden. The runtime the probe answered with is what every
/// subsequent container call uses.
///
/// Re-runs the cross-section execution-policy validation that parsing defers
/// while the posture is unset: `execution: container` under a posture that
/// resolved to disabled is still startup-fatal.
Future<DartclawConfig> resolveContainerPosture(
  DartclawConfig config, {
  PlatformCapabilities? platformCapabilities,
  RunCommand runCommand = Process.run,
}) async {
  final declared = config.container.declaredEnabled;
  final capabilities = platformCapabilities ?? PlatformCapabilities();
  final binary = declared == false || !capabilities.containerIsolationAvailable
      ? null
      : await ContainerManager.detectRuntime(runCommand: runCommand);
  if (declared == null) {
    _log.info(
      binary == null
          ? 'No container runtime detected — starting in advisory mode'
          : 'Container runtime "$binary" detected — isolating agent execution by default',
    );
  }
  final resolved = config.copyWith(
    container: config.container.resolved(enabled: declared ?? binary != null, runtimeBinary: binary),
  );
  validateExecutionPolicySelections(resolved);
  return resolved;
}
