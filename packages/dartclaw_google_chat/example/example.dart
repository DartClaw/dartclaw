// ignore_for_file: avoid_print
// Requires GCP project with Chat API enabled and service account credentials.

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';

void main() {
  ensureDartclawGoogleChatRegistered();

  final warnings = <String>[];
  final config = GoogleChatConfig.fromYaml({
    'enabled': true,
    'service_account': '/secrets/google-chat-service-account.json',
    'audience': {'type': 'project-number', 'value': '123456789012'},
    'webhook_path': '/integrations/googlechat',
    'typing_indicator': true,
  }, warnings);

  final credentials = GcpAuthService.resolveCredentialJson(configValue: config.serviceAccount);

  print('Webhook path: ${config.webhookPath}');
  print('Audience mode: ${config.audience?.mode.name}');
  print('Credentials resolved locally: ${credentials != null}');
  if (warnings.isNotEmpty) {
    print('Warnings: $warnings');
  }
  print('Real delivery requires valid Google Chat app credentials and webhook setup.');
}
