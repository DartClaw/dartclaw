import 'dart:io';

import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
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
  test('public library re-exports core types used by WhatsApp APIs', () {
    ProcessFactory processFactory() => _unexpectedProcessStart;
    DelayFactory delay() => _noopDelay;
    HealthProbe healthProbe() => _healthy;

    final manager = GowaManager(
      executable: 'gowa',
      processFactory: processFactory(),
      delay: delay(),
      healthProbe: healthProbe(),
    );
    final config = WhatsAppConfig(
      dmAccess: DmAccessMode.open,
      groupAccess: GroupAccessMode.open,
      retryPolicy: const RetryPolicy(),
      taskTrigger: const TaskTriggerConfig(enabled: true),
    );
    final gating = MentionGating(requireMention: false, mentionPatterns: const [], ownJid: 'wa:bot');

    expect(manager.executable, 'gowa');
    expect(config.taskTrigger.enabled, isTrue);
    expect(gating.requireMention, isFalse);
    expect(ChannelType.whatsapp.name, 'whatsapp');
  });
}
