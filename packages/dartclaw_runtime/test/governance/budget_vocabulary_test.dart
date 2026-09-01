import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The budget vocabulary `dartclaw_runtime` publishes, enumerated rather than
/// negated: a retired outcome type coming back through the barrel, or a second
/// one appearing beside it, has to fail here.
const _publishedBudgetSymbols = {'BudgetEnforcer', 'BudgetEvaluation', 'BudgetOutcome', 'BudgetStatus'};

final _exportShow = RegExp(r"^export '([^']+)'(?:\s+show\s+([^;]+))?;", multiLine: true);
final _enumDeclaration = RegExp(r'^\s*enum\s+(Budget\w*)\b', multiLine: true);

void main() {
  test('governance_exports.dart publishes exactly the surviving budget symbols', () async {
    final root = await _packageRoot();
    final source = File('$root/lib/src/governance/governance_exports.dart').readAsStringSync();

    final exported = <String>{};
    for (final match in _exportShow.allMatches(source)) {
      if (!match.group(1)!.startsWith('budget_')) continue;
      final shown = match.group(2);
      expect(shown, isNotNull, reason: '${match.group(1)} must name its symbols');
      exported.addAll(shown!.split(',').map((symbol) => symbol.trim()));
    }

    expect(exported, {..._publishedBudgetSymbols, 'BudgetExhaustedException'});
  });

  test('no production library declares a second budget outcome enum', () async {
    final root = await _packageRoot();
    final declarations = <String, String>{};

    for (final file in Directory('$root/lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in _enumDeclaration.allMatches(file.readAsStringSync())) {
        declarations[match.group(1)!] = file.path.substring(root.length + 1);
      }
    }

    expect(declarations.keys.toSet(), {'BudgetOutcome'}, reason: 'declared in: $declarations');
  });
}

Future<String> _packageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  if (library == null) {
    throw StateError('Could not resolve dartclaw_runtime package root');
  }
  return File.fromUri(library).parent.parent.path;
}
