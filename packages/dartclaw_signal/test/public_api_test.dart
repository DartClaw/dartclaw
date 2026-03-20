import 'dart:io';

import 'package:dartclaw_signal/dartclaw_signal.dart';
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
    final config = SignalConfig(dmAccess: DmAccessMode.open, taskTrigger: const TaskTriggerConfig(enabled: true));

    expect(manager.executable, 'signal-cli');
    expect(config.taskTrigger.enabled, isTrue);
    expect(ChannelType.signal.name, 'signal');
  });
}
