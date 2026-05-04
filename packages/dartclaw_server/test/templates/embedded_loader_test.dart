import 'dart:io';

import 'package:dartclaw_server/src/templates/loader.dart' as loader;
import 'package:test/test.dart';

void _writeFilesystemTemplates(Directory dir) {
  for (final name in loader.expectedTemplates) {
    File('${dir.path}/$name.html').writeAsStringSync('<div>$name</div>');
  }
}

void main() {
  group('filesystem template loading', () {
    test('initTemplates succeeds with a complete filesystem template set', () {
      final tmpDir = Directory.systemTemp.createTempSync('dartclaw_embedded_templates_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      _writeFilesystemTemplates(tmpDir);
      loader.resetTemplates();
      try {
        loader.initTemplates(tmpDir.path);

        expect(loader.templateLoader.source('layout'), equals('<div>layout</div>'));
        expect(
          loader.templateLoader.trellis.render(loader.templateLoader.source('layout'), const {}),
          contains('layout'),
        );
      } finally {
        loader.resetTemplates();
      }
    });

    test('initTemplates still fails for a missing path', () {
      final tmpDir = Directory.systemTemp.createTempSync('dartclaw_missing_templates_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      loader.resetTemplates();
      try {
        expect(() => loader.initTemplates(tmpDir.path), throwsA(isA<StateError>()));
      } finally {
        loader.resetTemplates();
      }
    });
  });
}
