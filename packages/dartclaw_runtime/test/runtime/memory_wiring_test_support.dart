import 'dart:io';

import 'package:path/path.dart' as p;

File seedInvalidCurrentMemory(String workspaceDir, {String lineEnding = '\n'}) {
  return File(p.join(workspaceDir, 'MEMORY.md'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('# DartClaw Canonical Memory${lineEnding}invalid current metadata$lineEnding');
}
