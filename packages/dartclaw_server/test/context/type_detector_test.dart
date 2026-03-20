import 'package:dartclaw_server/src/context/type_detector.dart';
import 'package:test/test.dart';

void main() {
  group('TypeDetector', () {
    group('extension-based detection', () {
      test('detects .json as JSON', () {
        expect(TypeDetector.detect('{}', fileHint: 'data.json'), ContentType.json);
      });

      test('detects .yaml as YAML', () {
        expect(TypeDetector.detect('key: value', fileHint: 'config.yaml'), ContentType.yaml);
      });

      test('detects .yml as YAML', () {
        expect(TypeDetector.detect('key: value', fileHint: 'config.yml'), ContentType.yaml);
      });

      test('detects .csv as CSV', () {
        expect(TypeDetector.detect('a,b,c', fileHint: 'data.csv'), ContentType.csv);
      });

      test('detects .tsv as TSV', () {
        expect(TypeDetector.detect('a\tb\tc', fileHint: 'data.tsv'), ContentType.tsv);
      });

      test('detects .dart as Dart', () {
        expect(TypeDetector.detect('class Foo {}', fileHint: 'foo.dart'), ContentType.dart);
      });

      test('detects .ts as TypeScript', () {
        expect(TypeDetector.detect('interface Foo {}', fileHint: 'foo.ts'), ContentType.typescript);
      });

      test('detects .tsx as TypeScript', () {
        expect(TypeDetector.detect('export default function() {}', fileHint: 'foo.tsx'), ContentType.typescript);
      });

      test('detects .js as TypeScript (JS)', () {
        expect(TypeDetector.detect('function foo() {}', fileHint: 'foo.js'), ContentType.typescript);
      });

      test('detects .py as Python', () {
        expect(TypeDetector.detect('def main(): pass', fileHint: 'main.py'), ContentType.python);
      });

      test('detects .go as Go', () {
        expect(TypeDetector.detect('package main', fileHint: 'main.go'), ContentType.go);
      });

      test('handles full path with nested directories', () {
        expect(TypeDetector.detect('{}', fileHint: '/home/user/project/data/config.json'), ContentType.json);
      });

      test('extension takes precedence over content heuristics', () {
        // Content looks like CSV but extension says JSON
        expect(TypeDetector.detect('a,b,c\n1,2,3', fileHint: 'file.json'), ContentType.json);
      });

      test('returns null for unrecognized extension', () {
        // Falls through to heuristics which also fail for plain text
        expect(TypeDetector.detect('Hello world', fileHint: 'readme.md'), isNull);
      });
    });

    group('content heuristic detection', () {
      test('detects JSON object from content', () {
        expect(TypeDetector.detect('{"key": "value"}'), ContentType.json);
      });

      test('detects JSON array from content', () {
        expect(TypeDetector.detect('[1, 2, 3]'), ContentType.json);
      });

      test('detects Dart source from class keyword', () {
        expect(TypeDetector.detect('class Foo {\n  int x = 0;\n}'), ContentType.dart);
      });

      test('detects Dart source from import', () {
        expect(TypeDetector.detect("import 'dart:async';\n\nvoid main() {}"), ContentType.dart);
      });

      test('detects TypeScript from export interface', () {
        expect(TypeDetector.detect('export interface Foo {\n  bar: string;\n}'), ContentType.typescript);
      });

      test('detects Python from def keyword', () {
        expect(TypeDetector.detect('def main():\n    pass\n'), ContentType.python);
      });

      test('detects Python from class keyword', () {
        expect(TypeDetector.detect('class Foo:\n    pass\n'), ContentType.python);
      });

      test('detects Go from package keyword', () {
        expect(TypeDetector.detect('package main\n\nfunc main() {}\n'), ContentType.go);
      });

      test('detects CSV from comma-separated first line', () {
        expect(TypeDetector.detect('name,email,age\nAlice,alice@example.com,30'), ContentType.csv);
      });

      test('detects TSV from tab-separated first line', () {
        expect(TypeDetector.detect('name\temail\tage\nAlice\talice@example.com\t30'), ContentType.tsv);
      });

      test('returns null for unrecognized plain text', () {
        expect(TypeDetector.detect('Hello world, this is just text.'), isNull);
      });

      test('returns null for empty string', () {
        expect(TypeDetector.detect(''), isNull);
      });
    });
  });
}
