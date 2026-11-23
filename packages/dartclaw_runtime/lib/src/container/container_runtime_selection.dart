import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'container_manager.dart';

/// Selects the container runtime an enabled config runs on.
///
/// Whether containers are used is the config's answer alone (ADR-064): a
/// config that does not enable them, or a platform with no container
/// isolation, is returned unchanged without running any process. An enabled
/// config carries the first runtime in [ContainerManager.runtimeBinaries] that
/// answers; when none does it is returned unchanged, still enabled, so
/// container wiring refuses startup naming the runtime it looked for.
Future<DartclawConfig> selectContainerRuntime(
  DartclawConfig config, {
  PlatformCapabilities? platformCapabilities,
  RunCommand runCommand = Process.run,
}) async {
  final capabilities = platformCapabilities ?? PlatformCapabilities();
  if (!config.container.enabled || !capabilities.containerIsolationAvailable) return config;
  final binary = await ContainerManager.detectRuntime(runCommand: runCommand);
  if (binary == null) return config;
  return config.copyWith(container: config.container.withRuntimeBinary(binary));
}
