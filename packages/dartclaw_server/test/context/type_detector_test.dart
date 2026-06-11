import 'package:dartclaw_server/src/context/type_detector.dart';
import 'package:test/test.dart';

void main() {
  group('TypeDetector', () {
    group('extension-based detection', () {
      final cases = [
        (name: '.json', content: '{}', fileHint: 'data.json', expected: ContentType.json),
        (name: '.yaml', content: 'key: value', fileHint: 'config.yaml', expected: ContentType.yaml),
        (name: '.yml', content: 'key: value', fileHint: 'config.yml', expected: ContentType.yaml),
        (name: '.csv', content: 'a,b,c', fileHint: 'data.csv', expected: ContentType.csv),
        (name: '.tsv', content: 'a\tb\tc', fileHint: 'data.tsv', expected: ContentType.tsv),
        (name: '.dart', content: 'class Foo {}', fileHint: 'foo.dart', expected: ContentType.dart),
        (name: '.ts', content: 'interface Foo {}', fileHint: 'foo.ts', expected: ContentType.typescript),
        (name: '.tsx', content: 'export default function() {}', fileHint: 'foo.tsx', expected: ContentType.typescript),
        (name: '.js', content: 'function foo() {}', fileHint: 'foo.js', expected: ContentType.typescript),
        (name: '.py', content: 'def main(): pass', fileHint: 'main.py', expected: ContentType.python),
        (name: '.go', content: 'package main', fileHint: 'main.go', expected: ContentType.go),
        (
          name: 'nested path',
          content: '{}',
          fileHint: '/home/user/project/data/config.json',
          expected: ContentType.json,
        ),
        (name: 'extension precedence', content: 'a,b,c\n1,2,3', fileHint: 'file.json', expected: ContentType.json),
        (name: 'unrecognized extension', content: 'Hello world', fileHint: 'readme.md', expected: null),
      ];

      for (final testCase in cases) {
        test('detects ${testCase.name}', () {
          expect(TypeDetector.detect(testCase.content, fileHint: testCase.fileHint), testCase.expected);
        });
      }
    });

    group('content heuristic detection', () {
      final cases = [
        (name: 'JSON object', content: '{"key": "value"}', expected: ContentType.json),
        (name: 'JSON array', content: '[1, 2, 3]', expected: ContentType.json),
        (name: 'Dart class keyword', content: 'class Foo {\n  int x = 0;\n}', expected: ContentType.dart),
        (name: 'Dart import', content: "import 'dart:async';\n\nvoid main() {}", expected: ContentType.dart),
        (
          name: 'TypeScript export interface',
          content: 'export interface Foo {\n  bar: string;\n}',
          expected: ContentType.typescript,
        ),
        (name: 'Python def keyword', content: 'def main():\n    pass\n', expected: ContentType.python),
        (name: 'Python class keyword', content: 'class Foo:\n    pass\n', expected: ContentType.python),
        (name: 'Go package keyword', content: 'package main\n\nfunc main() {}\n', expected: ContentType.go),
        (name: 'CSV first line', content: 'name,email,age\nAlice,alice@example.com,30', expected: ContentType.csv),
        (name: 'TSV first line', content: 'name\temail\tage\nAlice\talice@example.com\t30', expected: ContentType.tsv),
        (name: 'plain text', content: 'Hello world, this is just text.', expected: null),
        (name: 'empty string', content: '', expected: null),
      ];

      for (final testCase in cases) {
        test('detects ${testCase.name}', () {
          expect(TypeDetector.detect(testCase.content), testCase.expected);
        });
      }
    });
  });
}
