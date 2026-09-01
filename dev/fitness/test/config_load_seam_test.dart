// Fitness function: one production config-load seam.
//
// What this enforces:
//   Production code under packages/<X>/lib/ and apps/<X>/lib/ must not call
//   `DartclawConfig.load(...)` directly. The only allowed site is the canonical
//   `loadDartclawConfig` seam in dartclaw_runtime.
//
// Why:
//   Channel sections (`channels.google_chat`, `.signal`, `.whatsapp`) are parsed
//   outside `dartclaw_kernel` — the three channel packages depend on it, so a
//   switch there would invert ADR-034. `load()` therefore cannot prime them, and
//   a config obtained straight from `load()` carries none of their parse
//   warnings: they vanish from `config.warnings` (so `status`/`serve`/`cleanup`/
//   `rebuild-index` stop printing them) and from `reloadBlockingWarnings` (so an
//   unparseable channel section stops blocking a hot reload). `loadDartclawConfig`
//   loads and primes; nothing else may load.
//
// How to resolve a failure:
//   Call `loadDartclawConfig(...)` from `package:dartclaw_runtime/dartclaw_runtime.dart`
//   — its parameters are identical to `DartclawConfig.load`'s. If the file
//   genuinely is a new canonical loader, add an entry to
//   `allowlist/config_load_seam.txt` with format
//   `<relative-path>  # <rationale>`.

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

void main() {
  late Allowlist allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'config_load_seam.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'config_load_seam.txt'), entryFormat: '<relative-path>');
  });

  test('DartclawConfig.load is only called from the canonical config-load seam', () {
    final violations = <String>[];
    final directLoadPattern = RegExp(r'DartclawConfig\.load\s*\(');

    for (final file in productionDartFiles(repoRoot)) {
      final relativePath = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (directLoadPattern.hasMatch(lines[i])) {
          // Consulted only on a real call site, so an entry for a file that no
          // longer calls `load` reads as stale instead of silent.
          if (allowlist.containsKey(relativePath)) continue;
          violations.add(
            '$relativePath:${i + 1}: direct DartclawConfig.load call — '
            'route it through loadDartclawConfig from package:dartclaw_runtime so channel '
            'sections are primed (see $fitnessReadmePath)',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Config-load seam violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
