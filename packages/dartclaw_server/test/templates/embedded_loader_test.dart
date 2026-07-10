import 'dart:io';

import 'package:dartclaw_server/src/templates/loader.dart' as loader;
import 'package:test/test.dart';

void _writeFilesystemTemplates(Directory dir) {
  for (final name in loader.expectedTemplates) {
    File('${dir.path}/$name.html').writeAsStringSync('<div>$name</div>');
  }
}

void main() {
  group('embedded template loading', () {
    Map<String, String> completeMap() => {
      for (final name in loader.expectedTemplates) 'templates/$name.html': '<div>$name</div>',
    };

    test('renders without a templates directory', () {
      loader.resetTemplates();
      try {
        loader.initEmbeddedTemplates(assets: completeMap());

        expect(loader.templateLoader.source('layout'), '<div>layout</div>');
        expect(
          loader.templateLoader.trellis.render(loader.templateLoader.source('layout'), const {}),
          contains('layout'),
        );
      } finally {
        loader.resetTemplates();
      }
    });

    test('fails startup when an expected embedded template is missing', () {
      final assets = completeMap()..remove('templates/layout.html');
      loader.resetTemplates();
      try {
        expect(
          () => loader.initEmbeddedTemplates(assets: assets),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('layout.html'))),
        );
      } finally {
        loader.resetTemplates();
      }
    });
  });

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
