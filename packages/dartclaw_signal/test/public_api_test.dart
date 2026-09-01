import 'dart:io';

import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

Future<Process> _unexpectedProcessStart(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) => throw UnimplementedError();

Future<void> _noopDelay(Duration duration) async {}

Future<bool> _healthy() async => true;

void main() {
  test('public library re-exports core types used by Signal APIs', () {
    ProcessFactory processFactory() => _unexpectedProcessStart;
    DelayFactory delay() => _noopDelay;
    HealthProbe healthProbe() => _healthy;

    final manager = SignalCliManager(
      executable: 'signal-cli',
      phoneNumber: '+15551234567',
      processFactory: processFactory(),
      delay: delay(),
      healthProbe: healthProbe(),
    );
    final config = SignalConfig(dmAccess: DmAccessMode.open);

    expect(manager.executable, 'signal-cli');
    expect(config.dmAccess, DmAccessMode.open);
    expect(ChannelType.signal.name, 'signal');
  });
}
