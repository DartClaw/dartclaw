import 'dart:convert';

import 'package:dartclaw_server/src/task/workflow_turn_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('WorkflowTurnExtractor', () {
    test('returns full payload from workflow-context envelope', () {
      final result = WorkflowTurnExtractor().parse(
        _context({'a': 1, 'b': 'two', 'c': true, 'd': []}),
        requiredKeys: const ['a', 'b', 'c', 'd'],
      );

      expect(result.inlinePayload, {'a': 1, 'b': 'two', 'c': true, 'd': []});
      expect(result.isPartial, isFalse);
      expect(result.missingKeys, isEmpty);
      expect(result.toolCallOutputs, isEmpty);
    });

    test('accepts partial payload with populated declared keys', () {
      final result = WorkflowTurnExtractor().parse(
        _context({'a': 1, 'c': 'present'}),
        requiredKeys: const ['a', 'b', 'c', 'd'],
      );

      expect(result.inlinePayload, {'a': 1, 'c': 'present'});
      expect(result.isPartial, isTrue);
      expect(result.missingKeys, ['b', 'd']);
      expect(result.logEntries.single, contains('Missing: [b, d]'));
    });

    test('malformed tag does not throw and returns an empty payload', () {
      final result = WorkflowTurnExtractor().parse('<workflow-context>{"a":1}');

      expect(result.inlinePayload, isEmpty);
      expect(result.isPartial, isFalse);
      expect(result.missingKeys, isEmpty);
    });

    test('absent envelope returns an empty payload', () {
      final result = WorkflowTurnExtractor().parse('plain assistant response');

      expect(result.inlinePayload, isEmpty);
      expect(result.toolCallOutputs, isEmpty);
    });

    test('merges tool-call output and inline payload with inline precedence', () {
      final toolOutput = jsonEncode({'a': 'tool', 'b': 'tool-only'});
      final stdout = [
        '<workflow-tool-output>$toolOutput</workflow-tool-output>',
        _context({'a': 'inline', 'c': 'inline-only'}),
      ].join('\n');

      final result = WorkflowTurnExtractor().parse(stdout, requiredKeys: const ['a', 'b', 'c']);

      expect(result.inlinePayload, {'a': 'inline', 'b': 'tool-only', 'c': 'inline-only'});
      expect(result.toolCallOutputs, [toolOutput]);
      expect(result.isPartial, isFalse);
    });

    test('reads JSONL tool-call output envelopes', () {
      final output = _context({'path': 'docs/spec.md'});
      final stdout = jsonEncode({'type': 'tool_call_output', 'output': output});

      final result = WorkflowTurnExtractor().parse(stdout, requiredKeys: const ['path']);

      expect(result.inlinePayload, {'path': 'docs/spec.md'});
      expect(result.toolCallOutputs, [output]);
    });
  });
}

String _context(Map<String, Object?> payload) => '<workflow-context>${jsonEncode(payload)}</workflow-context>';
