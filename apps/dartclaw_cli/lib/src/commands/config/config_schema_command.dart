import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ConfigMeta;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show WriteLine, dartclawVersion;

class ConfigSchemaCommand extends Command<void> {
  final WriteLine _writeLine;

  new({WriteLine? writeLine}) : _writeLine = writeLine ?? stdout.writeln {
    argParser.addOption('out', valueHelp: 'path', help: 'Write the schema to a file, overwriting it if it exists');
  }

  @override
  String get name => 'schema';

  @override
  String get description => 'Print the config JSON Schema for this version (no server required)';

  @override
  void run() {
    final source = ConfigMeta.jsonSchemaSource(version: dartclawVersion);
    final path = argResults!['out'] as String?;
    if (path != null) {
      File(path).writeAsStringSync(source);
    } else {
      _writeLine(source.substring(0, source.length - 1));
    }
  }
}
