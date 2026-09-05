import 'dart:io';

// Per-package `lib/` LOC ceilings. One recorded number per workspace member
// with a `lib/`. They ratchet down routinely; a raise is a recorded rebaseline
// (milestone close-out or reviewed necessity) with a CHANGELOG note.
//
// The check fails two ways. Growth past the ceiling fails. So does slack: a
// package whose ceiling sits further above its actual size than its band allows
// fails until the ceiling is lowered, so a package that shrinks cannot bank the
// space it freed as future allowance. That is the ratchet ADR-033 asks for,
// checkable from one snapshot rather than from history.
//
// The band is `min(_locHeadroom, ceiling ~/ 4)`, not a flat `_locHeadroom`. A
// flat constant is inert in the shrink direction for anything smaller than
// itself: the client-tier umbrella is 45 lines, so under a flat 400 it could
// shrink to zero and still pass. Proportional below the constant, capped by it
// above, so the ratchet holds at every package size.
//
// Raising a ceiling is a deliberate, reviewable act with a CHANGELOG note.
// Lowering one is routine and belongs in the change that shrank the package.
const _locHeadroom = 1500;

/// How far above [ceiling]'s own package the ceiling may sit before the slack
/// itself fails. Proportional under [_locHeadroom], capped by it above.
int _locBand(int ceiling) {
  final proportional = ceiling ~/ 4;
  return proportional < _locHeadroom ? proportional : _locHeadroom;
}

/// The highest ceiling [loc] may carry — what a slack failure must be lowered to.
int _maxCeilingFor(int loc) {
  var ceiling = loc + _locHeadroom;
  while (ceiling > loc && ceiling - loc > _locBand(ceiling)) {
    ceiling -= 1;
  }
  return ceiling;
}

// Re-baselined 2026-08-22 against the finished 0.25 tree, measured with
// _countDartLoc and no other filter. Each entry is `min(previous ceiling,
// _maxCeilingFor(measured))`: a ceiling never rises, and one that the new band
// no longer permits comes down to what it does.
//
// Eleven of the thirteen are unchanged, because the milestone's `lib/`
// deletions had already landed when these were first recorded and the suite
// reduction that followed touched no `lib/` file. The two that move are the
// two the flat band had left unratcheted:
//   dartclaw         245 -> 60   (measured 45; 245 permitted a shrink to zero)
//   dartclaw_client  669 -> 625  (measured 469)
//
// Subsequent ratchets on 2026-08-23:
//   dartclaw          60 -> 58     (measured 44)
//   dartclaw_runtime  66040 -> 63167 (measured 62767)
//
// Reviewed exception on 2026-08-25:
//   dartclaw_runtime  63167 -> 64225 (measured 63825 after C2 removed 381
//   behavior-preserving lines; the remaining server-rendered web growth was
//   accepted rather than hidden in templates or compressed for the counter)
//
// Subsequent ratchet on 2026-08-25:
//   dartclaw_runtime  64225 -> 64014 (measured 63614)
//   dartclaw_core     25619 -> 25389 (measured 24989) -> 25378 (measured 24978)
//   dartclaw_runtime  64014 -> 63956 (measured 63556)
//
// Reviewed topology rebaseline on 2026-08-26:
//   dartclaw_google_chat 5746 -> 6409 (measured 6009 after absorbing its
//   Space Events and OAuth implementation from dartclaw_runtime)
//   dartclaw_runtime     63956 -> 63614 (measured 63214 after the move)
//   dartclaw_runtime     63614 -> 63603 (measured 63203 after relocating the
//   WhatsApp JID helper to its channel owner)
//
// Subsequent ratchet on 2026-08-27:
//   dartclaw_cli      10852 -> 10847 (measured 10447 after CredentialPreflight
//   moved to dartclaw_runtime, which the runtime's own band already absorbs)
//
// Reviewed necessity, 2026-08-27 (ADR-033; maintainer-accepted):
//   dartclaw_runtime  63603 -> 64058 (measured 63658). The T1 tail's two boot
//   defects and the posture fixes that followed add a net 58 lines to this
//   package. Safe reduction was exhausted first — both new doc blocks trimmed
//   three times, and the `require*` accessors moved out of service_wiring.dart
//   into its result part, which the 1500-line file ceiling forced anyway.
//   Nothing further came out without deleting a fix.
//
// Reviewed margin rebaseline, 2026-09-01 (owner decision, DECISIONS.md § Still
// Current): _locHeadroom 400 -> 1500 and every ceiling re-cut to
// _maxCeilingFor(measured) on the tree that merged 0.24.3. Four packages were
// over their ceiling (core 26240 > 25378, kernel 18420 > 17962, workflow
// 24132 > 24130, cli 11219 > 10847) and the 400 band had a ceiling raise
// every few days; the ratchet keeps its shape, the slack it tolerates is wider.
// Measured: dartclaw 44, acp 2735, bridge 696, cli 11219, client 469,
// core 26240, google_chat 6009, kernel 18420, runtime 63856, signal 1347,
// testing 2988, whatsapp 888, workflow 24132.
//
// Subsequent ratchet on 2026-09-05:
//   dartclaw_core 27740 -> 27705 (measured 26205 after the one-shot HTTP seam
//   moved down to dartclaw_kernel, which the kernel's own band absorbs)
const _libLocCeilings = <String, int>{
  'dartclaw': 58,
  'dartclaw_acp': 3646,
  'dartclaw_bridge': 928,
  'dartclaw_cli': 12719,
  'dartclaw_client': 625,
  'dartclaw_core': 27705,
  'dartclaw_google_chat': 7509,
  'dartclaw_kernel': 19920,
  'dartclaw_runtime': 65356,
  'dartclaw_signal': 1796,
  'dartclaw_testing': 3984,
  'dartclaw_whatsapp': 1184,
  'dartclaw_workflow': 25632,
};
// 2026-08-22: ratcheted 13 -> 12 when storage was absorbed into core, and the
// package count is recorded again here at the tier order's close. The ceiling
// equals the shipped package count, with no spare slot for an unreviewed
// boundary. `dartclaw_bridge` counts as its own package: the combined
// core+bridge target is not decided, so this records the actual state.
const _workspacePackageCeiling = 12;

final class _CheckResult {
  final String name;
  final bool passed;
  final String detail;

  const new({required this.name, required this.passed, required this.detail});
}

Future<void> main() async {
  final scriptPath = File.fromUri(Platform.script).resolveSymbolicLinksSync();
  final repoRoot = File(scriptPath).parent.parent.parent.path;
  final results = <_CheckResult>[
    _checkCoreBarrelDoesNotLaunderKernel(repoRoot),
    _checkClaudeProviderOptionOwnership(repoRoot),
    ..._checkLibLocCeilings(repoRoot),
    _checkWorkspacePackageCount(repoRoot),
  ];

  var failures = 0;
  for (final result in results) {
    final status = result.passed ? 'PASS' : 'FAIL';
    stdout.writeln('$status ${result.name}: ${result.detail}');
    if (!result.passed) {
      failures += 1;
    }
  }

  stdout.writeln();
  if (failures == 0) {
    stdout.writeln('PASS summary: ${results.length}/${results.length} checks passed.');
    exitCode = 0;
    return;
  }

  stdout.writeln('FAIL summary: $failures/${results.length} checks failed.');
  exitCode = 1;
}

// Dependency direction itself is governed by the declared tier order in
// dev/package_tiers.txt (dev/fitness/test/dependency_direction_test.dart). This
// keeps only the rule that is about a barrel's shape rather than an edge.
_CheckResult _checkCoreBarrelDoesNotLaunderKernel(String repoRoot) {
  // Targeted show-clause re-exports (migration bridges) are fine; an unbounded
  // full-barrel re-export would make every kernel symbol look core-owned.
  final coreBarrel = File('$repoRoot/packages/dartclaw_core/lib/dartclaw_core.dart');
  final launders =
      coreBarrel.existsSync() &&
      RegExp(
        r'''^\s*export\s+['"]package:dartclaw_kernel/dartclaw_kernel\.dart['"]''',
        multiLine: true,
      ).hasMatch(coreBarrel.readAsStringSync());

  return _CheckResult(
    name: 'L1 core barrel does not launder the kernel',
    passed: !launders,
    detail: launders
        ? 'packages/dartclaw_core/lib/dartclaw_core.dart re-exports the whole kernel barrel.'
        : 'dartclaw_core advertises its own surface; kernel symbols are imported from the kernel.',
  );
}

_CheckResult _checkClaudeProviderOptionOwnership(String repoRoot) {
  final violations = <String>[];
  final allowed = {
    'packages/dartclaw_kernel/lib/src/claude_provider_options.dart',
    'packages/dartclaw_kernel/lib/src/config_parser.dart',
  };

  for (final root in ['apps', 'packages']) {
    final dir = Directory('$repoRoot/$root');
    if (!dir.existsSync()) {
      continue;
    }

    for (final file in dir.listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }

      final relativePath = _relativePath(file.path, repoRoot);
      if (allowed.contains(relativePath) || relativePath.contains('/test/')) {
        continue;
      }

      final content = file.readAsStringSync();
      if (RegExp(r'''\[['"]inherit_user_settings['"]\]''').hasMatch(content)) {
        violations.add(relativePath);
      }
    }
  }

  return _CheckResult(
    name: 'L1 Claude provider option ownership',
    passed: violations.isEmpty,
    detail: violations.isEmpty
        ? 'Production inherit_user_settings lookups are centralized in dartclaw_kernel.'
        : 'Found raw inherit_user_settings lookup(s) outside dartclaw_kernel policy helper: ${violations.join(', ')}',
  );
}

List<_CheckResult> _checkLibLocCeilings(String repoRoot) {
  final results = <_CheckResult>[];
  final measured = <String>{};
  for (final member in _workspaceMembers(repoRoot)) {
    final libDir = Directory('${member.path}${Platform.pathSeparator}lib');
    if (!libDir.existsSync()) continue;
    measured.add(member.name);
    final ceiling = _libLocCeilings[member.name];
    if (ceiling == null) {
      results.add(
        _CheckResult(
          name: 'L2 ${member.name} LOC ceiling',
          passed: false,
          detail: 'No ceiling recorded for ${member.name}; add one to _libLocCeilings in dev/tools/arch_check.dart.',
        ),
      );
      continue;
    }
    final loc = _countDartLoc(libDir);
    final path = '${_relativePath(member.path, repoRoot)}/lib';
    if (loc > ceiling) {
      results.add(
        _CheckResult(
          name: 'L2 ${member.name} LOC ceiling',
          passed: false,
          detail: '$loc lines in $path exceeds the ceiling of $ceiling.',
        ),
      );
    } else if (ceiling - loc > _locBand(ceiling)) {
      results.add(
        _CheckResult(
          name: 'L2 ${member.name} LOC ceiling',
          passed: false,
          detail:
              '$loc lines in $path leaves ${ceiling - loc} lines of slack under the ceiling of $ceiling '
              '(band ${_locBand(ceiling)}); lower the ceiling to ${_maxCeilingFor(loc)}.',
        ),
      );
    } else {
      results.add(
        _CheckResult(
          name: 'L2 ${member.name} LOC ceiling',
          passed: true,
          detail: '$loc lines in $path (ceiling <= $ceiling, band ${_locBand(ceiling)}).',
        ),
      );
    }
  }

  final orphaned = _libLocCeilings.keys.where((name) => !measured.contains(name)).toList()..sort();
  if (orphaned.isNotEmpty) {
    results.add(
      _CheckResult(
        name: 'L2 LOC ceiling coverage',
        passed: false,
        detail: 'Recorded ceilings for packages with no lib/: ${orphaned.join(', ')}.',
      ),
    );
  }
  return results;
}

// Generated Dart is not source: the embedded-asset libraries are base64 payloads
// whose line count tracks asset bytes (~19K lines at the 0.25 close), so counting
// them would report asset churn as a code delta.
int _countDartLoc(Directory directory) {
  var loc = 0;
  for (final file in directory.listSync(recursive: true)) {
    final normalizedPath = file.path.replaceAll('\\', '/');
    if (file is! File || !normalizedPath.endsWith('.dart') || normalizedPath.contains('/lib/src/generated/')) {
      continue;
    }
    loc += file.readAsLinesSync().length;
  }
  return loc;
}

_CheckResult _checkWorkspacePackageCount(String repoRoot) {
  final packageCount = _packageMembers(repoRoot).length;
  return _CheckResult(
    name: 'L2 workspace package count',
    passed: packageCount <= _workspacePackageCeiling,
    detail: '$packageCount packages under packages/ (threshold <= $_workspacePackageCeiling).',
  );
}

List<_WorkspaceMember> _workspaceMembers(String repoRoot) {
  return [
    ..._packageMembers(repoRoot),
    ...Directory('$repoRoot/apps')
        .listSync()
        .whereType<Directory>()
        .map((dir) => _WorkspaceMember(name: _basename(dir.path), path: dir.path)),
  ];
}

List<_WorkspaceMember> _packageMembers(String repoRoot) {
  return Directory('$repoRoot/packages')
      .listSync()
      .whereType<Directory>()
      .map((dir) => _WorkspaceMember(name: _basename(dir.path), path: dir.path))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.split('/').where((segment) => segment.isNotEmpty).last;
}

String _relativePath(String path, String repoRoot) {
  final normalizedPath = path.replaceAll('\\', '/');
  final normalizedRoot = repoRoot.replaceAll('\\', '/');
  if (normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

final class _WorkspaceMember {
  final String name;
  final String path;

  const new({required this.name, required this.path});
}
