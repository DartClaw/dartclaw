import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('MediaExtractor');

/// Result of extracting MEDIA directives from agent output.
class MediaExtraction {
  final String cleanedText;
  final List<String> mediaPaths;

  const MediaExtraction({required this.cleanedText, required this.mediaPaths});
}

final _mediaPattern = RegExp(r'^MEDIA:(.+)$', multiLine: true);

/// Extract `MEDIA:<path>` directives from agent output.
///
/// Resolves relative paths against [workspaceDir]. Validates file existence;
/// non-existent files are skipped with a warning.
MediaExtraction extractMediaDirectives(String text, {required String workspaceDir}) {
  final matches = _mediaPattern.allMatches(text).toList();
  if (matches.isEmpty) return MediaExtraction(cleanedText: text, mediaPaths: []);

  final mediaPaths = <String>[];
  var cleaned = text;

  for (final match in matches.reversed) {
    final rawPath = match.group(1)!.trim();
    final resolved = p.isAbsolute(rawPath) ? rawPath : p.join(workspaceDir, rawPath);

    if (File(resolved).existsSync()) {
      mediaPaths.insert(0, resolved);
    } else {
      _log.warning('MEDIA directive references non-existent file: $resolved — skipping');
    }

    cleaned = cleaned.replaceRange(match.start, match.end, '');
  }

  // Clean up extra blank lines left by removed directives
  cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return MediaExtraction(cleanedText: cleaned, mediaPaths: mediaPaths);
}
