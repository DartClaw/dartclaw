import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('media_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  group('extractMediaDirectives', () {
    test('no directives returns text unchanged', () {
      final result = extractMediaDirectives('hello world', workspaceDir: tmpDir.path);
      expect(result.cleanedText, 'hello world');
      expect(result.mediaPaths, isEmpty);
    });

    test('single directive extracted', () {
      final file = File(p.join(tmpDir.path, 'image.png'));
      file.writeAsStringSync('fake image');

      final text = 'Here is an image:\nMEDIA:image.png\nDone.';
      final result = extractMediaDirectives(text, workspaceDir: tmpDir.path);

      expect(result.mediaPaths, hasLength(1));
      expect(result.mediaPaths.first, file.path);
      expect(result.cleanedText, isNot(contains('MEDIA:')));
      expect(result.cleanedText, contains('Here is an image:'));
      expect(result.cleanedText, contains('Done.'));
    });

    test('multiple directives extracted', () {
      File(p.join(tmpDir.path, 'a.png')).writeAsStringSync('a');
      File(p.join(tmpDir.path, 'b.png')).writeAsStringSync('b');

      final text = 'MEDIA:a.png\ntext\nMEDIA:b.png';
      final result = extractMediaDirectives(text, workspaceDir: tmpDir.path);

      expect(result.mediaPaths, hasLength(2));
      expect(result.cleanedText, 'text');
    });

    test('non-existent file skipped', () {
      final text = 'MEDIA:nonexistent.png\nrest';
      final result = extractMediaDirectives(text, workspaceDir: tmpDir.path);

      expect(result.mediaPaths, isEmpty);
      expect(result.cleanedText, 'rest');
    });

    test('absolute path resolved', () {
      final file = File(p.join(tmpDir.path, 'abs.png'));
      file.writeAsStringSync('data');

      final text = 'MEDIA:${file.path}';
      final result = extractMediaDirectives(text, workspaceDir: '/other');

      expect(result.mediaPaths, [file.path]);
    });
  });
}
