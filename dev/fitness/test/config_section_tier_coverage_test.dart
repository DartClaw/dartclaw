// Fitness function: every DartclawConfig section declares a ConfigNotifier reload tier.
//
// How to resolve a failure:
//   Add the section to ConfigNotifier's tier table, choosing `reloadable` only
//   when a registered Reconfigurable genuinely applies its changes. A section
//   that cannot be compared at all gets `<section>  # <rationale>` in
//   config_section_tier_coverage.txt.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _configRoot = 'packages/dartclaw_kernel/lib/src/dartclaw_config.dart';
const _notifier = 'packages/dartclaw_kernel/lib/src/config_notifier.dart';

const _sectionFieldStart = '// --- Composed section fields ---';
const _sectionFieldEnd = '// --- Derived path getters ---';

final _fieldPattern = RegExp(r'^\s*final\s+.+\s+([a-z]\w*);\s*$');
final _tierPattern = RegExp(r"^\s*'(\w+)':\s*\(tier: ConfigReloadTier\.(\w+),");

Set<String> _composedSections(String repoRoot) {
  final lines = File('$repoRoot/$_configRoot').readAsLinesSync();
  final start = lines.indexWhere((line) => line.trim() == _sectionFieldStart);
  final end = lines.indexWhere((line) => line.trim() == _sectionFieldEnd);
  if (start < 0 || end <= start) {
    fail('$_configRoot no longer delimits its composed section fields with "$_sectionFieldStart"');
  }
  return {
    for (final line in lines.sublist(start + 1, end))
      if (_fieldPattern.firstMatch(line) case final match?) match.group(1)!,
  };
}

/// Every tier declaration in source order, so a section declared twice is
/// visible instead of collapsing onto one map key.
List<({String section, String tier})> _declaredTiers(String repoRoot) => [
  for (final line in File('$repoRoot/$_notifier').readAsLinesSync())
    if (_tierPattern.firstMatch(line) case final match?) (section: match.group(1)!, tier: match.group(2)!),
];

void main() {
  late String repoRoot;
  late Allowlist allowlist;
  late Set<String> sections;
  late List<({String section, String tier})> tiers;
  late Set<String> declared;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'config_section_tier_coverage.txt');
    sections = _composedSections(repoRoot);
    tiers = _declaredTiers(repoRoot);
    declared = {for (final entry in tiers) entry.section};
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'config_section_tier_coverage.txt'), entryFormat: '<section>');
  });

  test('the source scan finds both sides of the comparison', () {
    // A silently-empty scan would make every assertion below vacuously true.
    expect(sections, isNotEmpty, reason: 'no composed section fields parsed from $_configRoot');
    expect(tiers, isNotEmpty, reason: 'no tier table entries parsed from $_notifier');
  });

  test('every DartclawConfig section declares a reload tier', () {
    final missing = sections.where((section) => !declared.contains(section) && !allowlist.containsKey(section));
    if (missing.isNotEmpty) {
      fail(
        'Sections composed on DartclawConfig with no declared reload tier:\n'
        '  ${missing.join('\n  ')}\n'
        'Declare each in ConfigNotifier\'s tier table, or allowlist it with a rationale. '
        'See $fitnessReadmePath.',
      );
    }
  });

  test('no section is declared twice', () {
    final duplicates = declared.where((section) => tiers.where((e) => e.section == section).length > 1);
    expect(duplicates, isEmpty, reason: 'sections declared more than once in the tier table');
  });

  test('every declared tier and allowlist entry names a real section', () {
    final unknown = [
      ...declared.where((section) => !sections.contains(section)).map((s) => '$s (tier table)'),
      // rawKeys, not keys: this scan reports, it does not decide a waiver, and
      // a consulting read here would mark every entry live and make the
      // staleness assertion in tearDownAll unreachable.
      ...allowlist.rawKeys.where((section) => !sections.contains(section)).map((s) => '$s (allowlist)'),
    ];
    if (unknown.isNotEmpty) {
      fail(
        'Declared sections that no longer exist on DartclawConfig:\n'
        '  ${unknown.join('\n  ')}\n'
        'Remove the stale entry. See $fitnessReadmePath.',
      );
    }
  });

  test('every declared tier is a ConfigReloadTier value', () {
    final bad = tiers.where((entry) => entry.tier != 'reloadable' && entry.tier != 'restart');
    expect(bad, isEmpty, reason: 'unknown ConfigReloadTier values: ${bad.map((e) => '${e.section}: ${e.tier}')}');
  });
}
