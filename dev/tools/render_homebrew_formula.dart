#!/usr/bin/env dart

// Renders the published Homebrew formula by injecting the four real platform
// SHA256 digests into the canonical template at package/homebrew/dartclaw.rb.
//
// The canonical formula carries placeholder digests (they cannot exist until the
// release binaries are built); this tool replaces each platform's placeholder
// with the digest computed by the release build, then emits the result for the
// CI step that mirrors it into the DartClaw/homebrew-dartclaw tap.
//
// Usage:
//   dart run dev/tools/render_homebrew_formula.dart \
//     --formula package/homebrew/dartclaw.rb \
//     --checksums-dir <dir of *.tar.gz.sha256 release assets> \
//     --version <X.Y.Z> \
//     [--output <path>]   # defaults to stdout
import 'dart:io';

const _targets = ['macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64'];

void main(List<String> args) {
  final opts = _parseArgs(args);
  final formulaPath = _require(opts, 'formula');
  final checksumsDir = _require(opts, 'checksums-dir');
  final version = _require(opts, 'version');

  var formula = File(formulaPath).readAsStringSync();

  if (!formula.contains('version "$version"')) {
    _fail('formula version does not match --version $version (lockstep drift)');
  }

  for (final target in _targets) {
    final digest = _readDigest(checksumsDir, version, target);
    final pattern = RegExp('(url "[^"]*-$target\\.tar\\.gz"\\s*\\n\\s*sha256 ")[0-9a-fA-F]{64}(")');
    final matches = pattern.allMatches(formula).toList();
    if (matches.length != 1) {
      _fail('expected exactly one sha256 slot for $target, found ${matches.length}');
    }
    formula = formula.replaceFirstMapped(pattern, (m) => '${m[1]}$digest${m[2]}');
  }

  final output = opts['output'];
  if (output == null) {
    stdout.write(formula);
  } else {
    File(output).writeAsStringSync(formula);
    stdout.writeln('render-homebrew-formula: wrote $output');
  }
}

String _readDigest(String dir, String version, String target) {
  final file = File('$dir/dartclaw-v$version-$target.tar.gz.sha256');
  if (!file.existsSync()) {
    _fail('missing checksum file: ${file.path}');
  }
  final token = file.readAsStringSync().trim().split(RegExp(r'\s+')).first;
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token)) {
    _fail('invalid sha256 in ${file.path}: "$token"');
  }
  return token.toLowerCase();
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) _fail('unexpected argument: $a');
    final key = a.substring(2);
    if (i + 1 >= args.length) _fail('missing value for --$key');
    out[key] = args[++i];
  }
  return out;
}

String _require(Map<String, String> opts, String key) {
  final value = opts[key];
  if (value == null) _fail('missing required --$key');
  return value;
}

Never _fail(String message) {
  stderr.writeln('render-homebrew-formula: $message');
  exit(1);
}
