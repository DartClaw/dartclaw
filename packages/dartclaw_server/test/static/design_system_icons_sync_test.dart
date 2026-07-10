import 'dart:io';

import 'package:test/test.dart';

/// Guards against silent drift between the served icon stylesheet and its
/// design-system source of truth.
///
/// `dev/design-system/icons.css` is declared the SoT for the icon system in
/// `dev/design-system/DESIGN.md`, but the file actually served to browsers is
/// `packages/dartclaw_server/lib/src/static/icons.css`. When icons are added to
/// the served copy without back-porting them, the design-system reference goes
/// stale. This test fails if any icon the served file ships is absent from the
/// doc copy, naming the offenders so the fix is mechanical.
void main() {
  // Resolve paths for both run modes: workspace root (aggregate `dart test
  // packages/dartclaw_server`) and package root (`dart test` inside the pkg).
  final fromWorkspaceRoot = File('packages/dartclaw_server/lib/src/static/icons.css').existsSync();
  final servedPath = fromWorkspaceRoot
      ? 'packages/dartclaw_server/lib/src/static/icons.css'
      : 'lib/src/static/icons.css';
  final docPath = fromWorkspaceRoot ? 'dev/design-system/icons.css' : '../../dev/design-system/icons.css';

  Set<String> extract(String css, RegExp pattern) => pattern.allMatches(css).map((match) => match.group(1)!).toSet();

  group('design-system icons.css sync', () {
    test('every served icon is present in the design-system source of truth', () {
      final doc = File(docPath);
      expect(
        doc.existsSync(),
        isTrue,
        reason: 'design-system SoT icons.css missing at $docPath — see dev/design-system/DESIGN.md § Icons',
      );

      final servedCss = File(servedPath).readAsStringSync();
      final docCss = doc.readAsStringSync();

      // `--icon-*` custom properties (definitions carry a trailing colon;
      // `var(--icon-*)` usages do not, so they are not matched).
      final defs = RegExp(r'--icon-([a-z0-9-]+)\s*:');
      // `.icon-*` inline class mappings.
      final classes = RegExp(r'\.icon-([a-z0-9-]+)\s*\{');
      // `[data-icon="*"]` semantic attribute mappings.
      final dataIcons = RegExp(r'\[data-icon="([a-z0-9-]+)"\]');

      for (final (label, pattern) in [
        ('--icon-* definitions', defs),
        ('.icon-* class mappings', classes),
        ('[data-icon="…"] mappings', dataIcons),
      ]) {
        final missing = extract(servedCss, pattern).difference(extract(docCss, pattern)).toList()..sort();
        expect(
          missing,
          isEmpty,
          reason:
              'served icons.css defines $label absent from the design-system copy: ${missing.join(', ')}. '
              'Reconcile $docPath (and DESIGN.md § Icons) with $servedPath.',
        );
      }
    });
  });
}
