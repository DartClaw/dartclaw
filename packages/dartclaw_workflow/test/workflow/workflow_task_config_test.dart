import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowTaskConfig;
import 'package:test/test.dart';

void main() {
  group('WorkflowTaskConfig.readFollowUpPrompts', () {
    test('returns strings as-is', () {
      final cfg = <String, dynamic>{
        WorkflowTaskConfig.followUpPrompts: ['a', 'b', 'c'],
      };
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), ['a', 'b', 'c']);
    });

    test('coerces non-string entries via toString', () {
      final cfg = <String, dynamic>{
        WorkflowTaskConfig.followUpPrompts: [1, 2.5, true],
      };
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), ['1', '2.5', 'true']);
    });

    test('coerces null entries to literal "null"', () {
      // Documents existing semantics — `values.map((v) => v.toString())`
      // yields the literal string "null" for null entries. Pinned so a future
      // refactor adding `.where((v) => v != null)` would surface here.
      final cfg = <String, dynamic>{
        WorkflowTaskConfig.followUpPrompts: [null, 'b'],
      };
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), ['null', 'b']);
    });

    test('returns empty list when key absent', () {
      expect(WorkflowTaskConfig.readFollowUpPrompts({}), isEmpty);
    });

    test('returns empty list when value is not a list', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.followUpPrompts: 'not a list'};
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), isEmpty);
    });

    test('returns empty list when value is null', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.followUpPrompts: null};
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), isEmpty);
    });
  });

  group('WorkflowTaskConfig.readStructuredSchema', () {
    test('returns typed Map<String, dynamic> as-is', () {
      final schema = <String, dynamic>{'type': 'object'};
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredSchema: schema};
      expect(WorkflowTaskConfig.readStructuredSchema(cfg), schema);
    });

    test('coerces Map<Object?, Object?> to Map<String, dynamic>', () {
      final raw = <Object?, Object?>{'type': 'object', 'count': 3};
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredSchema: raw};
      final result = WorkflowTaskConfig.readStructuredSchema(cfg);
      expect(result, isA<Map<String, dynamic>>());
      expect(result, {'type': 'object', 'count': 3});
    });

    test('returns null when key absent', () {
      expect(WorkflowTaskConfig.readStructuredSchema({}), isNull);
    });

    test('returns null when value is not a map', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredSchema: 'not a map'};
      expect(WorkflowTaskConfig.readStructuredSchema(cfg), isNull);
    });

    test('returns null when value is null', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredSchema: null};
      expect(WorkflowTaskConfig.readStructuredSchema(cfg), isNull);
    });
  });

  group('WorkflowTaskConfig.readStructuredOutputPayload', () {
    test('returns typed Map<String, dynamic> as-is', () {
      final payload = <String, dynamic>{'result': 'ok'};
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredOutputPayload: payload};
      expect(WorkflowTaskConfig.readStructuredOutputPayload(cfg), payload);
    });

    test('coerces Map<Object?, Object?> to Map<String, dynamic>', () {
      final raw = <Object?, Object?>{'result': 'ok', 'count': 1};
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredOutputPayload: raw};
      final result = WorkflowTaskConfig.readStructuredOutputPayload(cfg);
      expect(result, isA<Map<String, dynamic>>());
      expect(result, {'result': 'ok', 'count': 1});
    });

    test('returns null when key absent', () {
      expect(WorkflowTaskConfig.readStructuredOutputPayload({}), isNull);
    });

    test('returns null when value is not a map', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.structuredOutputPayload: 42};
      expect(WorkflowTaskConfig.readStructuredOutputPayload(cfg), isNull);
    });
  });

  group('WorkflowTaskConfig.readProviderSessionId', () {
    test('returns trimmed string when present and non-empty', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.providerSessionId: '  sess-123  '};
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), 'sess-123');
    });

    test('returns null for whitespace-only string', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.providerSessionId: '   '};
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), isNull);
    });

    test('returns null when key absent', () {
      expect(WorkflowTaskConfig.readProviderSessionId({}), isNull);
    });

    test('returns null when value is not a string', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.providerSessionId: 42};
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), isNull);
    });

    test('returns null when value is null', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.providerSessionId: null};
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), isNull);
    });
  });

  group('WorkflowTaskConfig.readContinueProviderSessionId', () {
    test('returns trimmed string when present and non-empty', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.continueProviderSessionId: '  prev-456  '};
      expect(WorkflowTaskConfig.readContinueProviderSessionId(cfg), 'prev-456');
    });

    test('returns null for whitespace-only string', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.continueProviderSessionId: ''};
      expect(WorkflowTaskConfig.readContinueProviderSessionId(cfg), isNull);
    });

    test('returns null when key absent', () {
      expect(WorkflowTaskConfig.readContinueProviderSessionId({}), isNull);
    });

    test('returns null when value is not a string', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.continueProviderSessionId: ['a']};
      expect(WorkflowTaskConfig.readContinueProviderSessionId(cfg), isNull);
    });
  });

  group('WorkflowTaskConfig writers (round-trip)', () {
    test('writeProviderSessionId round-trips through readProviderSessionId', () {
      final cfg = <String, dynamic>{};
      WorkflowTaskConfig.writeProviderSessionId(cfg, 'sess-abc');
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), 'sess-abc');
    });

    test('writeStructuredOutputPayload round-trips through readStructuredOutputPayload', () {
      final cfg = <String, dynamic>{};
      final payload = <String, dynamic>{'key': 'value', 'n': 7};
      WorkflowTaskConfig.writeStructuredOutputPayload(cfg, payload);
      expect(WorkflowTaskConfig.readStructuredOutputPayload(cfg), payload);
    });

    test('writeProviderSessionId overwrites existing value', () {
      final cfg = <String, dynamic>{WorkflowTaskConfig.providerSessionId: 'old'};
      WorkflowTaskConfig.writeProviderSessionId(cfg, 'new');
      expect(WorkflowTaskConfig.readProviderSessionId(cfg), 'new');
    });

    test('writeFollowUpPrompts round-trips through readFollowUpPrompts', () {
      final cfg = <String, dynamic>{};
      WorkflowTaskConfig.writeFollowUpPrompts(cfg, ['p1', 'p2']);
      expect(WorkflowTaskConfig.readFollowUpPrompts(cfg), ['p1', 'p2']);
    });

    test('writeStructuredSchema round-trips through readStructuredSchema', () {
      final cfg = <String, dynamic>{};
      final schema = <String, dynamic>{'type': 'object', 'required': ['x']};
      WorkflowTaskConfig.writeStructuredSchema(cfg, schema);
      expect(WorkflowTaskConfig.readStructuredSchema(cfg), schema);
    });

    test('writeContinueProviderSessionId round-trips through readContinueProviderSessionId', () {
      final cfg = <String, dynamic>{};
      WorkflowTaskConfig.writeContinueProviderSessionId(cfg, 'prev-xyz');
      expect(WorkflowTaskConfig.readContinueProviderSessionId(cfg), 'prev-xyz');
    });
  });
}
