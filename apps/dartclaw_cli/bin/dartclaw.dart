import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/runner.dart';

Future<void> main(List<String> args) async {
  try {
    await buildDartclawRunner().run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64); // EX_USAGE
  }
}
