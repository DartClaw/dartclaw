#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final options = _parseArgs(args);
  final manifestPath = _require(options, 'manifest');
  final checksumsDir = _require(options, 'checksums-dir');
  final version = _require(options, 'version');

  final manifest = jsonDecode(File(manifestPath).readAsStringSync());
  if (manifest is! Map<String, dynamic>) {
    _fail('manifest root must be a JSON object');
  }
  if (manifest['version'] != version) {
    _fail('manifest version does not match --version $version (lockstep drift)');
  }

  final architecture = manifest['architecture'];
  if (architecture is! Map<String, dynamic> || architecture.length != 1 || !architecture.containsKey('64bit')) {
    _fail('manifest must contain exactly one 64-bit architecture');
  }
  final x64 = architecture['64bit'];
  if (x64 is! Map<String, dynamic>) {
    _fail('manifest architecture.64bit must be a JSON object');
  }
  if (_hashSlotCount(manifest) != 1 || x64['hash'] is! String) {
    _fail('expected exactly one 64-bit hash slot');
  }

  x64['hash'] = _readDigest(checksumsDir, version);
  final rendered = '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
  final output = options['output'];
  if (output == null) {
    stdout.write(rendered);
  } else {
    File(output).writeAsStringSync(rendered);
    stdout.writeln('render-scoop-manifest: wrote $output');
  }
}

String _readDigest(String directory, String version) {
  final archive = 'dartclaw-v$version-windows-x64.zip';
  final file = File('$directory/$archive.sha256');
  if (!file.existsSync()) {
    _fail('missing checksum file: ${file.path}');
  }
  final token = file.readAsStringSync().trim().split(RegExp(r'\s+')).first;
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token)) {
    _fail('invalid sha256 in ${file.path}: "$token"');
  }
  return token.toLowerCase();
}

int _hashSlotCount(Object? value) {
  return switch (value) {
    Map<dynamic, dynamic> map =>
      map.entries.where((entry) => entry.key == 'hash').length +
          map.values.fold(0, (count, child) => count + _hashSlotCount(child)),
    Iterable<dynamic> values => values.fold(0, (count, child) => count + _hashSlotCount(child)),
    _ => 0,
  };
}

Map<String, String> _parseArgs(List<String> args) {
  final options = <String, String>{};
  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (!argument.startsWith('--')) {
      _fail('unexpected argument: $argument');
    }
    final key = argument.substring(2);
    if (index + 1 >= args.length) {
      _fail('missing value for --$key');
    }
    options[key] = args[++index];
  }
  return options;
}

String _require(Map<String, String> options, String key) {
  final value = options[key];
  if (value == null) {
    _fail('missing required --$key');
  }
  return value;
}

Never _fail(String message) {
  stderr.writeln('render-scoop-manifest: $message');
  exit(1);
}
