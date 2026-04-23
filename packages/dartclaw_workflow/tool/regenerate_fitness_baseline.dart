import 'dart:convert';
import 'dart:io';

import '../test/fitness_support.dart';

void main() {
  final repoRoot = resolveRepoRoot();
  final snapshot = collectFitnessSnapshot(repoRoot);
  final baseline = snapshot.toBaseline(generatedAt: DateTime.now().toUtc().toIso8601String());
  final file = File(baselinePath(repoRoot));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(baseline.toJson())}\n');
  stdout.writeln('Wrote ${file.path}');
}
