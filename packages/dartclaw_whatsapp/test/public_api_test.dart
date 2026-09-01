import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
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
  test('public library enumerates the surviving package exports', () async {
    final libraryUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_whatsapp/dartclaw_whatsapp.dart'));
    final source = await File.fromUri(libraryUri!).readAsString();

    expect(
      source,
      allOf(
        contains("export 'package:dartclaw_core/dartclaw_core.dart'"),
        contains("export 'src/gowa_manager.dart'"),
        contains("export 'src/response_formatter.dart'"),
        contains("export 'src/whatsapp_channel.dart'"),
        contains("export 'src/whatsapp_config.dart'"),
      ),
    );
    expect(RegExp(r'^export ', multiLine: true).allMatches(source), hasLength(5));
  });

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
    final config = WhatsAppConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open);
    final gating = MentionGating(requireMention: false, mentionPatterns: const [], ownJid: 'wa:bot');

    expect(manager.executable, 'gowa');
    expect(config.dmAccess, DmAccessMode.open);
    expect(gating.requireMention, isFalse);
    expect(ChannelType.whatsapp.name, 'whatsapp');
  });
}
