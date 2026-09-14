@Tags(['integration', 'slow'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/container/container_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../integration/container_integration_support.dart';

void main() {
  test('production retained-container owner closes stdin and observes attached root removal', () async {
    if (!await dockerAvailable()) throw StateError('Docker is required for the retained-stdin lifetime probe');
    final checkout = await repoRoot();
    await ensureAgentImage(checkout);
    final root = Directory.systemTemp.createTempSync('temporary_container_eof_');
    final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
    final name = 'dartclaw-temporary-eof-${DateTime.now().microsecondsSinceEpoch}';
    final manager = ContainerManager(
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: name,
      ownerLabel: ContainerManager.ownerLabel(root.path),
      profileId: 'workspace',
      workspaceMounts: ['${workspace.path}:/project:rw'],
      generatedStateDir: p.join(root.path, 'containers', name),
      volatileGeneratedState: true,
      buildContextDir: checkout,
    );
    try {
      await manager.start();
      final inspect = await Process.run('docker', ['inspect', name]);
      expect(inspect.exitCode, 0, reason: '${inspect.stderr}');
      final row = (jsonDecode(inspect.stdout as String) as List).single as Map<String, dynamic>;
      final config = row['Config'] as Map<String, dynamic>;
      final host = row['HostConfig'] as Map<String, dynamic>;
      expect(config['AttachStdin'], isTrue);
      expect(config['OpenStdin'], isTrue);
      expect(config['StdinOnce'], isTrue);
      expect(config['Tty'], isFalse);
      expect(config['Cmd'], ['cat']);
      expect(host['AutoRemove'], isTrue);
      final evidenceDir = Platform.environment['DARTCLAW_TEMPORARY_EOF_EVIDENCE'];
      if (evidenceDir != null) {
        final output = Directory(evidenceDir)..createSync(recursive: true);
        File(p.join(output.path, 'container-before-eof.json')).writeAsStringSync(inspect.stdout as String);
      }

      await manager.stop();

      final absent = await Process.run('docker', ['inspect', name]);
      expect(absent.exitCode, isNot(0), reason: 'container survived retained stdin EOF');
      expect((absent.stderr as String).toLowerCase(), anyOf(contains('no such object'), contains('no such container')));
      if (evidenceDir != null) {
        File(p.join(evidenceDir, 'container-after-eof.txt')).writeAsStringSync(absent.stderr as String);
      }
    } finally {
      await Process.run('docker', ['rm', '-f', name]);
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });
}
