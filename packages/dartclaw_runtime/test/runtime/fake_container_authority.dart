import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ContainerAuthorityLease;
import 'package:dartclaw_core/dartclaw_core.dart';

/// A [ContainerAuthorityLease] over [FakeContainerExecutor], shared by the
/// harness-wiring suites that fake a container authority grant.
class FakeContainerAuthorityLease implements ContainerAuthorityLease {
  new({String? mcpBridgeUrl, Map<String, String> pathMapping = const {}})
    : container = FakeContainerExecutor(mcpBridgeUrl: mcpBridgeUrl, pathMapping: pathMapping);

  @override
  final ContainerExecutor container;

  @override
  Future<void> release() async {}
}

/// A [ContainerExecutor] double that never spawns; `pathMapping` supplies the
/// host-to-container path translation a test needs, defaulting to none.
class FakeContainerExecutor implements ContainerExecutor {
  new({this.mcpBridgeUrl, this.pathMapping = const {}});

  @override
  final String profileId = 'workspace';

  @override
  final String workingDir = '/project';

  @override
  final bool hasProjectMount = true;

  @override
  final String generatedStateDir = '/tmp/dartclaw-fake-authority';

  @override
  final String providerBridgeUrl = 'http://127.0.0.1:8080';

  @override
  final String? mcpBridgeUrl;

  final Map<String, String> pathMapping;

  @override
  Future<void> start() async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) =>
      throw UnimplementedError('The fake authority never spawns');

  @override
  String? containerPathForHostPath(String hostPath) => pathMapping[hostPath];
}
