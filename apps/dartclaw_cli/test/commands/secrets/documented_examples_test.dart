import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// A guide file, located by walking up from the test's CWD so the scan works
/// whichever directory the runner was launched from.
String _guide(String name) {
  final relative = p.join('docs', 'guide', name);
  for (var current = Directory.current.absolute; ; current = current.parent) {
    final candidate = File(p.join(current.path, relative));
    if (candidate.existsSync()) return candidate.readAsStringSync();
    if (current.path == current.parent.path) {
      throw StateError('Could not locate $relative from ${Directory.current.path}');
    }
  }
}

/// The first fenced ```yaml block containing [marker].
String _yamlBlock(String document, String marker) {
  final blocks = RegExp(r'```yaml\n(.*?)```', dotAll: true).allMatches(document).map((m) => m.group(1)!);
  return blocks.firstWhere(
    (block) => block.contains(marker),
    orElse: () => fail('no ```yaml block containing "$marker"'),
  );
}

void main() {
  tearDown(DartclawConfig.clearStoredCredentialProvider);

  // The documented example is only useful if it parses; a `credential:` key the
  // parser rejects would read as working config.
  test('the deployment guide\'s search-provider credential example loads and resolves', () {
    final yaml = _yamlBlock(_guide('deployment.md'), 'credential: brave-search');
    expect(loadYaml(yaml), isA<Map<Object?, Object?>>(), reason: 'the documented block is valid YAML');

    DartclawConfig.registerStoredCredentialProvider(
      (_) => const {'brave-search': CredentialEntry(apiKey: 'stored-value')},
    );
    final config = DartclawConfig.load(
      fileReader: (path) => path == '/home/user/.dartclaw/dartclaw.yaml' ? yaml : null,
      env: const {'HOME': '/home/user'},
    );

    expect(config.warnings, isEmpty);
    expect(config.search.providers['brave']?.enabled, isTrue);
    expect(config.search.providers['brave']?.apiKey, 'stored-value');
  });

  test('the configuration guide documents both search-provider credential keys and their exclusion', () {
    final guide = _guide('configuration.md');
    expect(guide, contains('search.providers'));
    expect(guide, contains('Declaring both warns and **skips the provider**'));
  });

  test('the security guide states what the store does not do', () {
    final guide = _guide('security.md');
    expect(guide, contains('Named Credential Storage'));
    expect(guide, contains('No encryption at rest'));
    expect(guide, contains('No OS keychain integration'));
  });

  test('the CLI reference documents all four subcommands', () {
    final guide = _guide('cli-reference.md');
    for (final subcommand in ['`secrets set`', '`secrets list`', '`secrets rm`', '`secrets audit`']) {
      expect(guide, contains(subcommand));
    }
  });
}
