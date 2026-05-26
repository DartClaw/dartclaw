import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/path_safety_policy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('path safety policy', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('path_safety_policy_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('rejects argument-unsafe path grammar', () {
      for (final path in ['docs/my plan.md', 'docs/../s01.md', 'docs/--flag/s01.md', 'docs/s01-"bad".md']) {
        expect(
          () => validateArgumentSafePath(path, fieldName: 'spec_path', rawPath: path),
          throwsFormatException,
          reason: path,
        );
      }
    });

    test('normalizes contained absolute paths and rejects symlink escapes', () {
      final contained = File(p.join(tempDir.path, 'docs/spec.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Spec\n');
      expect(
        safeProjectRelativePath(contained.path, tempDir.path, fieldName: 'Produced artifact path'),
        'docs/spec.md',
      );

      final outside = Directory.systemTemp.createTempSync('path_safety_policy_outside_');
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      Link(p.join(tempDir.path, 'linked-out')).createSync(outside.path);

      expect(
        () => safeProjectRelativePath('linked-out/secret.md', tempDir.path, fieldName: 'Produced artifact path'),
        throwsFormatException,
      );
    });

    test('applies caller-supplied basename policy', () {
      expect(
        safeWorkspaceRelativePath(
          'docs/specs/fis/s01-story.md',
          activeWorkspaceRoot: tempDir.path,
          fieldName: 'spec_path',
          basenameMatcher: isFisMarkdownPath,
          typeDescription: 'an sNN-style markdown FIS path',
        ),
        'docs/specs/fis/s01-story.md',
      );
      expect(
        () => safeWorkspaceRelativePath(
          'docs/specs/fis/story.md',
          activeWorkspaceRoot: tempDir.path,
          fieldName: 'spec_path',
          basenameMatcher: isFisMarkdownPath,
          typeDescription: 'an sNN-style markdown FIS path',
        ),
        throwsFormatException,
      );
    });
  });
}
