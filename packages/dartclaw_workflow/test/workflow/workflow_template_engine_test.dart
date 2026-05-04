import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

MapContext _mapCtx({required Object item, required int index, required int length}) =>
    MapContext(item: item, index: index, length: length);

WorkflowContext _ctx({Map<String, dynamic>? data, Map<String, String>? variables}) =>
    WorkflowContext(data: data, variables: variables);

void main() {
  late WorkflowTemplateEngine engine;

  setUp(() {
    engine = WorkflowTemplateEngine();
  });

  group('WorkflowTemplateEngine.resolve', () {
    test('resolves variable reference', () {
      final ctx = _ctx(variables: {'NAME': 'Alice'});
      expect(engine.resolve('Hello {{NAME}}!', ctx), 'Hello Alice!');
    });

    test('resolves context reference', () {
      final ctx = _ctx(data: {'result': 'success'});
      expect(engine.resolve('Status: {{context.result}}', ctx), 'Status: success');
    });

    test('resolves multiple references in same template', () {
      final ctx = _ctx(data: {'key': 'world'}, variables: {'GREETING': 'Hello'});
      expect(engine.resolve('{{GREETING}} {{context.key}}!', ctx), 'Hello world!');
    });

    test('template with no references returned unchanged', () {
      final ctx = _ctx();
      expect(engine.resolve('No references here', ctx), 'No references here');
    });

    test('missing variable throws ArgumentError', () {
      final ctx = _ctx();
      expect(() => engine.resolve('{{MISSING}}', ctx), throwsA(isA<ArgumentError>()));
    });

    test('missing context key resolves to empty string', () {
      final ctx = _ctx();
      expect(engine.resolve('{{context.missing}}', ctx), '');
    });

    test('whitespace in braces is trimmed and resolved', () {
      final ctx = _ctx(variables: {'VAR': 'value'});
      expect(engine.resolve('{{ VAR }}', ctx), 'value');
    });

    test('context reference with trimmed whitespace works', () {
      final ctx = _ctx(data: {'k': 'v'});
      expect(engine.resolve('{{ context.k }}', ctx), 'v');
    });
  });

  group('WorkflowTemplateEngine.extractVariableReferences', () {
    test('extracts non-context references', () {
      expect(engine.extractVariableReferences('{{A}} and {{context.x}} and {{B}}'), {'A', 'B'});
    });

    test('returns empty set when no references', () {
      expect(engine.extractVariableReferences('no refs'), isEmpty);
    });

    test('ignores context references', () {
      expect(engine.extractVariableReferences('{{context.key}}'), isEmpty);
    });
  });

  group('WorkflowTemplateEngine.extractContextReferences', () {
    test('extracts context key references without prefix', () {
      expect(engine.extractContextReferences('{{context.result}} and {{context.status}}'), {'result', 'status'});
    });

    test('ignores variable references', () {
      expect(engine.extractContextReferences('{{VAR}}'), isEmpty);
    });

    test('returns empty set when no context refs', () {
      expect(engine.extractContextReferences('hello world'), isEmpty);
    });

    test('strips [map.index] suffix from context key', () {
      expect(engine.extractContextReferences('{{context.items[map.index]}}'), {'items'});
    });

    test('strips [map.index].field suffix from context key', () {
      expect(engine.extractContextReferences('{{context.results[map.index].title}}'), {'results'});
    });

    test('excludes map.* references', () {
      expect(engine.extractContextReferences('{{map.item}} {{map.index}}'), isEmpty);
    });
  });

  group('WorkflowTemplateEngine.resolveWithMap', () {
    group('map.item — Map item', () {
      test('{{map.item}} with Map encodes as JSON', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: {'title': 'foo', 'id': 1}, index: 0, length: 3);
        final result = engine.resolveWithMap('Item: {{map.item}}', ctx, mapCtx);
        expect(result, contains('"title"'));
        expect(result, contains('"foo"'));
      });

      test('{{map.item.field}} returns field value', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: {'title': 'Hello'}, index: 0, length: 1);
        expect(engine.resolveWithMap('{{map.item.title}}', ctx, mapCtx), 'Hello');
      });

      test('{{map.item.field}} with nested map traverses correctly', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(
          item: {
            'meta': {'author': 'Alice'},
          },
          index: 0,
          length: 1,
        );
        expect(engine.resolveWithMap('{{map.item.meta.author}}', ctx, mapCtx), 'Alice');
      });

      test('{{map.item.a.b.c}} traverses three nested levels', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(
          item: {
            'a': {
              'b': {'c': 'deep'},
            },
          },
          index: 0,
          length: 1,
        );
        expect(engine.resolveWithMap('{{map.item.a.b.c}}', ctx, mapCtx), 'deep');
      });

      test('nested traversal resolves at the 10-segment cap', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(
          item: {
            'a': {
              'b': {
                'c': {
                  'd': {
                    'e': {
                      'f': {
                        'g': {
                          'h': {
                            'i': {'j': 'deep'},
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
          index: 0,
          length: 1,
        );
        expect(engine.resolveWithMap('{{map.item.a.b.c.d.e.f.g.h.i.j}}', ctx, mapCtx), 'deep');
      });

      test('array-typed field renders as bullet list', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(
          item: {
            'tags': ['x', 'y', 'z'],
          },
          index: 0,
          length: 1,
        );
        expect(engine.resolveWithMap('{{map.item.tags}}', ctx, mapCtx), '- x\n- y\n- z');
      });

      test('missing field in Map resolves to empty string', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: {'title': 'A'}, index: 0, length: 1);
        expect(engine.resolveWithMap('{{map.item.missing}}', ctx, mapCtx), '');
      });

      test('dot notation exceeding 10 levels throws ArgumentError', () {
        final ctx = _ctx();
        // 11-segment path — one past the cap.
        Map<String, Object?> nest(String key, Object? value) => {key: value};
        Object? item = 'leaf';
        for (final k in const ['k', 'j', 'i', 'h', 'g', 'f', 'e', 'd', 'c', 'b', 'a']) {
          item = nest(k, item);
        }
        final mapCtx = _mapCtx(item: item as Map<String, Object?>, index: 0, length: 1);
        expect(
          () => engine.resolveWithMap('{{map.item.a.b.c.d.e.f.g.h.i.j.k}}', ctx, mapCtx),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('{{map.item.field}} on non-Map item throws ArgumentError', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'scalar', index: 0, length: 1);
        expect(() => engine.resolveWithMap('{{map.item.field}}', ctx, mapCtx), throwsA(isA<ArgumentError>()));
      });
    });

    group('map.item — scalar item', () {
      test('{{map.item}} with String returns string value', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'hello', index: 0, length: 5);
        expect(engine.resolveWithMap('val: {{map.item}}', ctx, mapCtx), 'val: hello');
      });

      test('{{map.item}} with int returns string representation', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 42, index: 0, length: 1);
        expect(engine.resolveWithMap('{{map.item}}', ctx, mapCtx), '42');
      });
    });

    group('map.index and map.length', () {
      test('{{map.index}} returns 0-based index as string', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'x', index: 0, length: 3);
        expect(engine.resolveWithMap('{{map.index}}', ctx, mapCtx), '0');
      });

      test('{{map.index}} returns correct non-zero index', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'x', index: 2, length: 3);
        expect(engine.resolveWithMap('idx={{map.index}}', ctx, mapCtx), 'idx=2');
      });

      test('{{map.length}} returns total collection size', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'x', index: 0, length: 7);
        expect(engine.resolveWithMap('{{map.length}}', ctx, mapCtx), '7');
      });
    });

    group('context.key[map.index] — indexed context lookup', () {
      test('resolves list element at current index', () {
        final ctx = _ctx(
          data: {
            'items': ['a', 'b', 'c'],
          },
        );
        final mapCtx = _mapCtx(item: 'unused', index: 1, length: 3);
        expect(engine.resolveWithMap('{{context.items[map.index]}}', ctx, mapCtx), 'b');
      });

      test('non-list context value resolves to empty string', () {
        final ctx = _ctx(data: {'items': 'not-a-list'});
        final mapCtx = _mapCtx(item: 'unused', index: 0, length: 1);
        expect(engine.resolveWithMap('{{context.items[map.index]}}', ctx, mapCtx), '');
      });

      test('map keyed by current item id resolves matching element', () {
        final ctx = _ctx(
          data: {
            'story_spec': {'S01': 'SPEC_ALPHA', 'S02': 'SPEC_BETA'},
          },
        );
        final mapCtx = _mapCtx(item: {'id': 'S02', 'title': 'Beta'}, index: 1, length: 2);
        expect(engine.resolveWithMap('{{context.story_spec[map.index]}}', ctx, mapCtx), 'SPEC_BETA');
      });

      test('single-key map wrapping a list auto-indexes by map.index', () {
        final ctx = _ctx(
          data: {
            'story_spec': {
              'items': ['SPEC_ALPHA', 'SPEC_BETA'],
            },
          },
        );
        final mapCtx = _mapCtx(item: {'id': 'S02'}, index: 1, length: 2);
        expect(engine.resolveWithMap('{{context.story_spec[map.index]}}', ctx, mapCtx), 'SPEC_BETA');
      });

      test('out-of-bounds index resolves to empty string', () {
        final ctx = _ctx(
          data: {
            'items': ['a'],
          },
        );
        final mapCtx = _mapCtx(item: 'unused', index: 5, length: 1);
        expect(engine.resolveWithMap('{{context.items[map.index]}}', ctx, mapCtx), '');
      });

      test('missing context key resolves to empty string', () {
        final ctx = _ctx();
        final mapCtx = _mapCtx(item: 'unused', index: 0, length: 1);
        expect(engine.resolveWithMap('{{context.missing[map.index]}}', ctx, mapCtx), '');
      });

      test('auto-extracts .text from Map elements', () {
        final ctx = _ctx(
          data: {
            'results': [
              {'text': 'extracted', 'score': 0.9},
              {'text': 'second'},
            ],
          },
        );
        final mapCtx = _mapCtx(item: 'unused', index: 0, length: 2);
        expect(engine.resolveWithMap('{{context.results[map.index]}}', ctx, mapCtx), 'extracted');
      });

      test('explicit dot-access bypasses auto-extraction', () {
        final ctx = _ctx(
          data: {
            'results': [
              {'text': 'ignored', 'score': 0.9},
            ],
          },
        );
        final mapCtx = _mapCtx(item: 'unused', index: 0, length: 1);
        expect(engine.resolveWithMap('{{context.results[map.index].score}}', ctx, mapCtx), '0.9');
      });

      test('explicit dot-access on non-Map element resolves to empty string', () {
        final ctx = _ctx(
          data: {
            'items': ['scalar'],
          },
        );
        final mapCtx = _mapCtx(item: 'unused', index: 0, length: 1);
        expect(engine.resolveWithMap('{{context.items[map.index].field}}', ctx, mapCtx), '');
      });
    });

    group('mixed and backward compat', () {
      test('mixed template with variable, context, map refs all resolved', () {
        final ctx = _ctx(
          data: {
            'labels': ['A', 'B', 'C'],
          },
          variables: {'PREFIX': 'Item'},
        );
        final mapCtx = _mapCtx(item: {'name': 'test'}, index: 1, length: 3);
        final result = engine.resolveWithMap(
          '{{PREFIX}} {{map.index}}/{{map.length}}: {{map.item.name}} ({{context.labels[map.index]}})',
          ctx,
          mapCtx,
        );
        expect(result, 'Item 1/3: test (B)');
      });

      test('null MapContext delegates to resolve() — same behavior', () {
        final ctx = _ctx(variables: {'X': 'hello'});
        expect(engine.resolveWithMap('{{X}}', ctx, null), 'hello');
        expect(engine.resolve('{{X}}', ctx), 'hello');
      });

      test('null MapContext — missing variable still throws', () {
        final ctx = _ctx();
        expect(() => engine.resolveWithMap('{{MISSING}}', ctx, null), throwsA(isA<ArgumentError>()));
      });
    });

    group('author-supplied alias (as:)', () {
      MapContext aliased({required Object item, required int index, required int length, required String alias}) =>
          MapContext(item: item, index: index, length: length, alias: alias);

      test('{{<alias>.item.field}} resolves against the same iteration as {{map.*}}', () {
        final ctx = _ctx();
        final mapCtx = aliased(
          item: {'spec_path': 'docs/s01.md', 'title': 'First'},
          index: 0,
          length: 3,
          alias: 'story',
        );
        expect(engine.resolveWithMap('{{story.item.spec_path}}', ctx, mapCtx), 'docs/s01.md');
        expect(engine.resolveWithMap('{{map.item.spec_path}}', ctx, mapCtx), 'docs/s01.md');
      });

      test('{{<alias>.index}}, {{<alias>.display_index}}, {{<alias>.length}} work alongside map.*', () {
        final ctx = _ctx();
        final mapCtx = aliased(item: {'id': 'a'}, index: 2, length: 5, alias: 'story');
        expect(engine.resolveWithMap('{{story.index}}', ctx, mapCtx), '2');
        expect(engine.resolveWithMap('{{story.display_index}}', ctx, mapCtx), '3');
        expect(engine.resolveWithMap('{{story.length}}', ctx, mapCtx), '5');
      });

      test('{{<alias>.item}} JSON-encodes Map items the same way map.item does', () {
        final ctx = _ctx();
        final mapCtx = aliased(item: {'a': 1}, index: 0, length: 1, alias: 'story');
        expect(engine.resolveWithMap('{{story.item}}', ctx, mapCtx), '{"a":1}');
      });

      test('{{<alias>.item.field}} respects the 10-segment depth cap', () {
        final ctx = _ctx();
        Object? inner = 'leaf';
        for (final k in const ['k', 'j', 'i', 'h', 'g', 'f', 'e', 'd', 'c', 'b', 'a']) {
          inner = {k: inner};
        }
        final mapCtx = aliased(item: inner as Map<String, Object?>, index: 0, length: 1, alias: 'story');
        expect(
          () => engine.resolveWithMap('{{story.item.a.b.c.d.e.f.g.h.i.j.k}}', ctx, mapCtx),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('{{context.key[<alias>.index]}} resolves indexed context against alias', () {
        final ctx = _ctx(
          data: {
            'labels': ['X', 'Y', 'Z'],
          },
        );
        final mapCtx = aliased(item: {'id': 'a'}, index: 1, length: 3, alias: 'story');
        expect(engine.resolveWithMap('{{context.labels[story.index]}}', ctx, mapCtx), 'Y');
      });

      test('{{context.key[<alias>.index]}} with unknown prefix resolves to empty string', () {
        final ctx = _ctx(
          data: {
            'labels': ['X', 'Y', 'Z'],
          },
        );
        final mapCtx = aliased(item: {'id': 'a'}, index: 1, length: 3, alias: 'story');
        expect(engine.resolveWithMap('{{context.labels[other.index]}}', ctx, mapCtx), '');
      });

      test('aliased prompt still lets legacy {{map.*}} work in the same template', () {
        final ctx = _ctx(variables: {'PREFIX': 'Story'});
        final mapCtx = aliased(item: {'title': 'T', 'spec_path': 'p'}, index: 0, length: 2, alias: 'story');
        final result = engine.resolveWithMap(
          '{{PREFIX}} {{story.display_index}}/{{map.length}}: {{story.item.title}} at {{map.item.spec_path}}',
          ctx,
          mapCtx,
        );
        expect(result, 'Story 1/2: T at p');
      });

      test('{{<alias>}} alone (no .field) throws a clear error', () {
        final ctx = _ctx();
        final mapCtx = aliased(item: {'a': 1}, index: 0, length: 1, alias: 'story');
        expect(() => engine.resolveWithMap('{{story}}', ctx, mapCtx), throwsA(isA<ArgumentError>()));
      });

      test('alias does not leak as a variable reference when mapCtx is absent', () {
        // Without a MapContext, `{{story.item}}` has no special meaning — it must
        // fall through to variable resolution and throw like any other undeclared ref.
        final ctx = _ctx();
        expect(() => engine.resolveWithMap('{{story.item}}', ctx, null), throwsA(isA<ArgumentError>()));
      });
    });

    group('alias-aware variable extraction', () {
      test('extractVariableReferences treats declared aliases as non-variables', () {
        final refs = engine.extractVariableReferences(
          'Hello {{NAME}} — story {{story.display_index}}/{{story.length}} at {{story.item.spec_path}}',
          mapAliases: {'story'},
        );
        expect(refs, {'NAME'});
      });

      test('extractVariableReferences without mapAliases keeps alias refs as variables', () {
        final refs = engine.extractVariableReferences('{{NAME}} {{story.item.spec_path}}');
        expect(refs, {'NAME', 'story.item.spec_path'});
      });
    });
  });
}
