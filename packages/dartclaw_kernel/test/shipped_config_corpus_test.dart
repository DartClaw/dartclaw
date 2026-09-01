import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Every configuration this repository ships must survive the load sweep.
///
/// The cheapest detector the accept-set has: a path a working config uses and
/// the registry does not describe is a registry gap, and it is fixed by
/// registering the field — never by tolerating the path.
void main() {
  group('shipped config corpus', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('every shipped configuration sweeps clean and loads', () async {
      ensureGitHubWebhookConfigRegistered();
      final configs = await _shippedConfigs();
      expect(configs, hasLength(greaterThanOrEqualTo(9)), reason: 'shipped configs: ${configs.map((f) => f.path)}');

      for (final file in configs) {
        // Assert the sweep verdict, not the absence of a warning: a refusal
        // throws rather than warning, so a warnings assertion could not fail.
        final sweep = DartclawConfig.sweepConfigPathsForTesting(
          (loadYaml(file.readAsStringSync()) as Map).cast<Object?, Object?>(),
          extensionKeys: DartclawConfig.registeredExtensionKeysForTesting(),
        );
        expect(sweep.unaccepted, isEmpty, reason: file.path);

        expect(
          () => DartclawConfig.load(
            configPath: file.path,
            fileReader: (path) => path == file.path ? file.readAsStringSync() : null,
            env: const {'HOME': '/home/user'},
          ),
          returnsNormally,
          reason: file.path,
        );
      }
    });

    test('the gate fails on a shipped file carrying an undescribed key', () async {
      // Proves the sweep, not the discovery: a file placed in either shipped
      // location goes through exactly the load above.
      final sample = (await _shippedConfigs()).first;
      final poisoned = '${sample.readAsStringSync()}\nnot_a_real_section:\n  x: 1\n';
      expect(
        () => DartclawConfig.load(
          configPath: sample.path,
          fileReader: (path) => path == sample.path ? poisoned : null,
          env: const {'HOME': '/home/user'},
        ),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains("'not_a_real_section'"))),
      );
    });
  });
}

/// The shipped corpus, discovered rather than listed, so a new shipped config
/// joins this gate without an edit here.
Future<List<File>> _shippedConfigs() async {
  final libUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_kernel/dartclaw_kernel.dart'));
  final root = p.normalize(p.join(p.dirname(libUri!.toFilePath()), '..', '..', '..'));

  return [
    ...Directory(p.join(root, 'examples')).listSync().whereType<File>().where((f) => f.path.endsWith('.yaml')),
    ...Directory(p.join(root, 'dev', 'testing', 'profiles'))
        .listSync()
        .whereType<Directory>()
        .map((dir) => File(p.join(dir.path, 'data', 'dartclaw.yaml')))
        .where((file) => file.existsSync()),
    // The checked-in instance config the workflow runner loads.
    File(p.join(root, '.dartclaw', 'dartclaw.yaml')),
  ].where((file) => file.existsSync()).toList()..sort((a, b) => a.path.compareTo(b.path));
}
