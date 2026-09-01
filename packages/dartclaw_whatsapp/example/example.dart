// Requires GOWA (Go WhatsApp) binary installed and configured.

import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

void main() {
  final warnings = <String>[];
  final config = WhatsAppConfig.fromYaml({
    'enabled': true,
    'gowa_host': '127.0.0.1',
    'gowa_port': 3000,
    'group_access': 'allowlist',
    'group_allowlist': ['123456789@g.us'],
  }, warnings);

  final formatted = formatResponse(
    'Status update sent from the example package.',
    model: 'Claude',
    agentName: 'DartClaw',
    maxChunkSize: config.maxChunkSize,
  );

  print('WhatsApp enabled: ${config.enabled}');
  print('Response chunks prepared: ${formatted.length}');
  if (warnings.isNotEmpty) {
    print('Warnings: $warnings');
  }
  print('Real delivery requires a running GOWA sidecar and a paired WhatsApp account.');
}
