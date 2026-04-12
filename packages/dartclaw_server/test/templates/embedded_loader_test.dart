import 'dart:io';

import 'package:dartclaw_server/src/templates/loader.dart' as loader;
import 'package:test/test.dart';

Map<String, String> _embeddedTemplates() {
  return {for (final name in loader.expectedTemplates) name: '<div>$name</div>'};
}

void main() {
  group('embedded template loading', () {
    test('initTemplates succeeds with a complete embedded template map', () {
      final tmpDir = Directory.systemTemp.createTempSync('dartclaw_embedded_templates_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      loader.resetTemplates();
      try {
        loader.initTemplates(tmpDir.path, embeddedSources: _embeddedTemplates());

        expect(loader.templateLoader.source('layout'), equals('<div>layout</div>'));
        expect(
          loader.templateLoader.trellis.render(loader.templateLoader.source('layout'), const {}),
          contains('layout'),
        );
      } finally {
        loader.resetTemplates();
      }
    });

    test('initTemplates without embedded sources still fails for a missing path', () {
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
