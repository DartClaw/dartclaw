// ignore_for_file: avoid_print
// Requires signal-cli installed and configured with a registered phone number.

import 'package:dartclaw_signal/dartclaw_signal.dart';

void main() {
  ensureDartclawSignalRegistered();

  final warnings = <String>[];
  final config = SignalConfig.fromYaml({
    'enabled': true,
    'phone_number': '+46700000000',
    'host': '127.0.0.1',
    'port': 8080,
    'dm_access': 'allowlist',
    'group_access': 'disabled',
  }, warnings);

  final senderMap = SignalSenderMap(filePath: 'build/signal-sender-map.json');

  print('Signal enabled: ${config.enabled}');
  print('Signal daemon endpoint: ${config.host}:${config.port}');
  print('Sender map path: ${senderMap.filePath}');
  if (warnings.isNotEmpty) {
    print('Warnings: $warnings');
  }
  print('Real delivery requires signal-cli running in daemon mode with a linked account.');
}
