import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'search_backend_contract.dart';
import 'search_test_support.dart';

void main() {
  group('LexicalSearchBackend', () {
    late InMemoryFullTextIndex index;

    setUp(() {
      index = InMemoryFullTextIndex();
    });

    searchBackendContractTests(
      name: 'lexical',
      createBackend: () => LexicalSearchBackend(index: index),
      indexContent: (text, source) => index.upsert([memorySearchDocument(text: text, source: source)], userId: 'owner'),
    );
  });
}
