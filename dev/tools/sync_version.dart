#!/usr/bin/env dart

// Syncs packages/dartclaw_server/lib/src/version.dart from pubspec.yaml.
// Optional first argument: repo root (defaults to walking up from the script).
import 'dart:io';

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : _repoRoot();
  final pubspec = File('$root/packages/dartclaw_server/pubspec.yaml');
  final out = File('$root/packages/dartclaw_server/lib/src/version.dart');
  String? version;
  for (final l in pubspec.readAsLinesSync()) {
    final m = RegExp(r'^version:\s*(.+)$').firstMatch(l.trim());
    if (m != null) {
      version = m.group(1)!.trim();
      break;
    }
  }
  if (version == null) {
    stderr.writeln('sync-version: version: not found');
    exit(1);
  }
  final content = "const dartclawVersion = '$version';\n";
  if (!out.existsSync() || out.readAsStringSync() != content) {
    out.writeAsStringSync(content);
    stdout.writeln('sync-version: wrote $version → ${out.path}');
  }
}

String _repoRoot() {
  var dir = File(Platform.script.toFilePath()).parent;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('sync-version: repo root not found');
      exit(1);
    }
    dir = parent;
  }
}
