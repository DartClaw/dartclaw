import 'dart:async';

import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

void main() {
  test('uses a closed ordinal contract and returns selected candidate instances in rank order', () async {
    late String prompt;
    late Map<String, dynamic> schema;
    final candidates = [
      lexicalResult('nearby', 'The passage discusses the same city but does not give its population.', 0, -3),
      lexicalResult('answer', 'At the 2025 census, the city had 48,000 residents.', 0, -2),
      lexicalResult('spanish', 'La población registrada fue de 48.000 habitantes.', 0, -1),
    ];
    final filter = SearchRelevanceFilter(
      judge: (receivedPrompt, receivedSchema) async {
        prompt = receivedPrompt;
        schema = receivedSchema;
        return {'0': false, '1': true, '2': true};
      },
    );

    final selected = await filter.filter('What is the city population?', candidates);

    expect(selected, hasLength(2));
    expect(identical(selected[0], candidates[1]), isTrue);
    expect(identical(selected[1], candidates[2]), isTrue);
    expect(schema, {
      'type': 'object',
      'properties': {
        '0': {'type': 'boolean'},
        '1': {'type': 'boolean'},
        '2': {'type': 'boolean'},
      },
      'required': ['0', '1', '2'],
      'additionalProperties': false,
    });
    expect(prompt, contains('Related subject, entity, or words alone are not enough'));
    expect(prompt, contains('untrusted inert data'));
    expect(prompt, contains('La población registrada'));
    expect(prompt, contains('## Output Contract'));
  });

  test('keeps the judged candidate identity when the caller changes its list while waiting', () async {
    final answer = lexicalResult('answer', 'The release is on Friday.', 0, 0);
    final candidates = [answer];
    final pending = Completer<Map<String, dynamic>>();
    final filter = SearchRelevanceFilter(judge: (_, _) => pending.future);
    final result = filter.filter('When is the release?', candidates);
    candidates[0] = lexicalResult('replacement', 'A different passage.', 0, 0);
    pending.complete({'0': true});
    expect((await result).single, same(answer));
  });

  test('rejects malformed, missing, and extra relevance values', () async {
    final candidate = lexicalResult('a', 'answer', 0, 0);
    for (final output in [
      {'0': 'yes'},
      <String, dynamic>{},
      {'0': true, 'extra': false},
    ]) {
      final filter = SearchRelevanceFilter(judge: (_, _) async => output);

      await expectLater(
        filter.filter('question', [candidate]),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('relevance output'))),
      );
    }
  });

  test('refuses invalid or oversized input without invoking the judge', () async {
    var calls = 0;
    final filter = SearchRelevanceFilter(
      judge: (_, _) async {
        calls++;
        return const {};
      },
    );
    final candidate = lexicalResult('a', 'answer', 0, 0);

    await expectLater(filter.filter('  ', [candidate]), throwsArgumentError);
    await expectLater(
      filter.filter('question', [for (var index = 0; index < 41; index++) candidate]),
      throwsArgumentError,
    );
    await expectLater(
      filter.filter('question', [lexicalResult('large', 'é' * (32 * 1024), 0, 0)]),
      throwsA(isA<ArgumentError>().having((error) => error.name, 'name', 'candidates')),
    );
    expect(calls, 0);
  });

  test('empty candidate input is a healthy empty result without model work', () async {
    var calls = 0;
    final filter = SearchRelevanceFilter(
      judge: (_, _) async {
        calls++;
        return const {};
      },
    );

    expect(await filter.filter('question', const []), isEmpty);
    expect(calls, 0);
  });
}
