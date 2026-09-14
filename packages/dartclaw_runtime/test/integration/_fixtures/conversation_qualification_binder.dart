import 'dart:convert';
import 'dart:io';

import 'conversation_qualification_evidence.dart';

void main(List<String> arguments) {
  if (arguments.length != 3) {
    stderr.writeln('usage: conversation_qualification_binder.dart <input.json> <case> <output.json>');
    exitCode = 64;
    return;
  }
  try {
    final evidence = validateQualificationEvidence(File(arguments[0]), arguments[1]);
    verifyCheckoutCandidate(Directory.current, evidence.candidate);
    File(arguments[2])
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(evidence.toJson())}\n', flush: true);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    exitCode = 66;
  }
}
