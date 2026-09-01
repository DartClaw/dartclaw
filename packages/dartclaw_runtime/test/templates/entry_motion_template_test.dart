import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('every main content swap root uses print-in', () async {
    final templatesDir = Directory(await resolveTemplatesDir());
    final templates = templatesDir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.html'))
        .where((file) => file.readAsStringSync().contains('id="main-content"'))
        .toList();

    expect(templates, hasLength(18));
    for (final template in templates) {
      final main = RegExp(r'<main[^>]*id="main-content"[^>]*>').firstMatch(template.readAsStringSync())?.group(0);
      expect(main, isNotNull, reason: template.path);
      expect(main, contains('print-in'), reason: template.path);
    }
  });
}
