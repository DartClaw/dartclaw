import 'dart:convert';

import 'package:dartclaw_runtime/src/task/workflow_turn_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowTurnExtractor', () {
    const extractor = WorkflowTurnExtractor();

    test('returns the full tagged payload', () {
      final result = extractor.parse(
        _context({'a': 1, 'b': 'two', 'c': true, 'd': <Object?>[]}),
        requiredKeys: const ['a', 'b', 'c', 'd'],
      );

      expect(result, {'a': 1, 'b': 'two', 'c': true, 'd': <Object?>[]});
    });

    test('returns a partial payload when at least one required key is populated', () {
      final result = extractor.parse(_context({'a': 1, 'c': 'present'}), requiredKeys: const ['a', 'b', 'c', 'd']);

      expect(result, {'a': 1, 'c': 'present'});
    });

    test('returns nothing when no required key is populated, so the caller can read the whole reply', () {
      final result = extractor.parse(_context({'a': '', 'b': <Object?>[]}), requiredKeys: const ['a', 'b']);

      expect(result, isEmpty);
    });

    test('a later block wins over an earlier one for the same key', () {
      final result = extractor.parse(
        [
          _context({'a': 'first'}),
          _context({'a': 'second', 'b': 'only-second'}),
        ].join('\n'),
        requiredKeys: const ['a'],
      );

      expect(result, {'a': 'second', 'b': 'only-second'});
    });

    test('malformed tag does not throw and returns an empty payload', () {
      expect(extractor.parse('<workflow-context>{"a":1}'), isEmpty);
    });

    test('absent tag returns an empty payload', () {
      expect(extractor.parse('plain assistant response'), isEmpty);
    });

    test('the surviving members are exactly the inbox parse and its emptiness predicate', () {
      // The workflow-schema statics, the tool-line sniffing and the
      // partial-payload verdict left with the workflow engine's inline channel.
      // This class parses one thing for one consumer.
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue(''), isFalse);
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue('x'), isTrue);
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue(const <Object?>[]), isFalse);
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue(const <String, Object?>{}), isFalse);
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue(null), isFalse);
      expect(WorkflowTurnExtractor.isNonEmptyPayloadValue(0), isTrue);
    });

    test('a tool-output line is ordinary text, not a payload source', () {
      final stdout = jsonEncode({
        'type': 'tool_call_output',
        'output': jsonEncode({'path': 'docs/spec.md'}),
      });

      expect(extractor.parse(stdout, requiredKeys: const ['path']), isEmpty);
    });
  });
}

String _context(Map<String, Object?> payload) => '<workflow-context>${jsonEncode(payload)}</workflow-context>';
