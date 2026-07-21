// Regenerate with: cd dev/tools/mascot_favicon && dart pub get && dart run bin/generate.dart
// Source: assets/logo-avatar-512-8bit.png

import 'dart:io';

import 'package:image/image.dart' as image;

void main() {
  final repositoryRoot = _repositoryRoot();
  final source = File('$repositoryRoot/assets/logo-avatar-512-8bit.png');
  final staticDir = Directory('$repositoryRoot/packages/dartclaw_server/lib/src/static')..createSync(recursive: true);
  final decoded = image.decodePng(source.readAsBytesSync());
  if (decoded == null) {
    throw StateError('Could not decode ${source.path}');
  }

  source.copySync('${staticDir.path}/mascot-avatar-512-8bit.png');
  for (final size in [16, 32]) {
    final resized = image.copyResize(decoded, width: size, height: size, interpolation: image.Interpolation.nearest);
    File('${staticDir.path}/mascot-favicon-$size.png').writeAsBytesSync(image.encodePng(resized));
  }
}

String _repositoryRoot() {
  var directory = File(Platform.script.toFilePath()).parent;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() && Directory('${directory.path}/packages').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Repository root not found');
    }
    directory = parent;
  }
}
