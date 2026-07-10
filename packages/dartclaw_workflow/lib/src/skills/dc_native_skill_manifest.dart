import 'dart:io';

import 'package:path/path.dart' as p;

/// Filename of the bundled DC-native skill manifest – the canonical inventory
/// of skills DartClaw ships and provisions. Lives at the root of the bundled
/// `skills/` source tree.
const dcNativeSkillManifestFile = 'dartclaw-native-skills.txt';

/// Names reserved for DartClaw-managed (`dartclaw-*`) skills.
final dcNativeSkillNamePattern = RegExp(r'^dartclaw-[A-Za-z0-9._-]+$');

/// Reads and validates the bundled DC-native skill manifest from [sourceDir].
///
/// Returns the manifest skill names in declaration order. Throws a
/// [FormatException] when the manifest is missing, empty, contains an invalid
/// `dartclaw-*` name, or lists a duplicate – callers map this to their own
/// provisioning failure type.
List<String> readDcNativeSkillManifest(String sourceDir) {
  final manifest = File(p.join(sourceDir, dcNativeSkillManifestFile));
  if (!manifest.existsSync()) {
    throw FormatException('DC-native skills manifest missing at ${manifest.path}');
  }
  return parseDcNativeSkillManifest(manifest.readAsStringSync(), sourceLabel: manifest.path);
}

/// Parses and validates a bundled DC-native skill manifest.
List<String> parseDcNativeSkillManifest(String content, {required String sourceLabel}) {
  final names = <String>[];
  final seen = <String>{};
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!dcNativeSkillNamePattern.hasMatch(line)) {
      throw FormatException('Invalid DC-native skill name "$line" in $sourceLabel');
    }
    if (!seen.add(line)) {
      throw FormatException('Duplicate DC-native skill name "$line" in $sourceLabel');
    }
    names.add(line);
  }
  if (names.isEmpty) {
    throw FormatException('DC-native skills manifest at $sourceLabel is empty');
  }
  return names;
}
