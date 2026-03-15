// ignore_for_file: avoid_print
// Requires GOWA (Go WhatsApp) binary installed and configured.

import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

void main() {
  ensureDartclawWhatsappRegistered();

  final warnings = <String>[];
  final config = WhatsAppConfig.fromYaml({
    'enabled': true,
    'gowa_host': '127.0.0.1',
    'gowa_port': 3000,
    'group_access': 'allowlist',
    'group_allowlist': ['123456789@g.us'],
    'task_trigger': {'enabled': true, 'prefix': 'task:'},
  }, warnings);

  final formatted = formatResponse(
    'MEDIA:docs/mockup.png\nStatus update sent from the example package.',
    model: 'Claude',
    agentName: 'DartClaw',
    maxChunkSize: config.maxChunkSize,
    workspaceDir: '.',
  );

  print('WhatsApp enabled: ${config.enabled}');
  print('Response chunks prepared: ${formatted.length}');
  if (warnings.isNotEmpty) {
    print('Warnings: $warnings');
  }
  print('Real delivery requires a running GOWA sidecar and a paired WhatsApp account.');
}
