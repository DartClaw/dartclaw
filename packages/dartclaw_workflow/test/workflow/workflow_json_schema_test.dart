import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/schema_presets.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_definition.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_dsl_rules.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_schema_emitter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/generate_workflow_schema.dart' as generator;
import '../fitness_support.dart';
import 'workflow_json_schema_test_support.dart';

void main() {
  late Map<String, Object?> schema;
  late Map<String, Object?> definitions;

  setUpAll(() {
    schema = emitWorkflowJsonSchema();
    definitions = Map<String, Object?>.from(schema[r'$defs']! as Map);
  });

  test('every declared block field alias and value kind is emitted', () {
    expect(
      definitions.keys,
      unorderedEquals(
        WorkflowDslRules.blocks.where((block) => block != WorkflowDslRules.workflow).map((block) => block.name),
      ),
    );

    for (final block in WorkflowDslRules.blocks) {
      final blockSchema = block == WorkflowDslRules.workflow
          ? schema
          : Map<String, Object?>.from(definitions[block.name]! as Map);
      expect(blockSchema['additionalProperties'], isFalse, reason: block.name);
      final properties = Map<String, Object?>.from(blockSchema['properties']! as Map);
      expect(properties.keys, unorderedEquals(block.keys), reason: block.name);
      for (final field in block.fields) {
        final first = properties[field.names.first];
        for (final alias in field.names) {
          expect(properties[alias], first, reason: '${block.name}.$alias');
        }
        final actualTypes = _schemaTypes(first! as Map, schema);
        final expectedTypes = field.acceptedKinds.map(_jsonType).toSet();
        expect(actualTypes, containsAll(expectedTypes), reason: '${block.name}.${field.names.first}');
      }
    }

    final output = Map<String, Object?>.from(definitions['output']! as Map);
    final outputProperties = Map<String, Object?>.from(output['properties']! as Map);
    expect(
      _stringEnums(Map<String, Object?>.from(outputProperties['schema']! as Map)),
      unorderedEquals(schemaPresets.keys),
    );

    final step = Map<String, Object?>.from(definitions['step']! as Map);
    final stepProperties = Map<String, Object?>.from(step['properties']! as Map);
    final outputs = Map<String, Object?>.from(stepProperties['outputs']! as Map);
    expect(
      _stringEnums(outputs),
      unorderedEquals([...OutputFormat.values.map((value) => value.name), ...schemaPresets.keys]),
    );
  });

  test('step schema is closed and narrows each task type', () {
    final step = Map<String, Object?>.from(definitions['step']! as Map);
    expect(step['additionalProperties'], isFalse);
    final conditionals = (step['allOf']! as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .where((branch) => branch.containsKey('if'))
        .toList();
    final explicitTypes = <String>{};
    for (final branch in conditionals) {
      final condition = Map<String, Object?>.from(branch['if']! as Map);
      final properties = condition['properties'];
      if (properties is Map<Object?, Object?>) {
        if (properties['type'] case final Map<Object?, Object?> typeSchema) {
          final value = typeSchema['const'];
          if (value is String) explicitTypes.add(value);
        }
      }
    }
    expect(explicitTypes, unorderedEquals(WorkflowTaskType.values.map((type) => type.toJson())));
    expect(conditionals, hasLength(WorkflowTaskType.values.length + 1));

    final checker = WorkflowSchemaChecker(schema);
    expect(checker.validate(_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work'})), isEmpty);
    expect(checker.validate(_workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'script': 'true'})), isEmpty);
    expect(checker.validate(_workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'prompt': 'true'})), isEmpty);
    expect(
      checker.validate(_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'script': 'true'})),
      contains(contains(r'$.steps[0]')),
    );
    expect(
      checker.validate(_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'typo': true})),
      contains(r'$.steps[0].typo: unknown property'),
    );
  });

  test('committed artifact is deterministic and drift is actionable', () {
    final first = generator.renderWorkflowJsonSchema();
    final second = generator.renderWorkflowJsonSchema();
    expect(second, first);
    final decoded = jsonDecode(first) as Map<String, dynamic>;
    expect(decoded[r'$schema'], 'https://json-schema.org/draft/2020-12/schema');
    expect(decoded.containsKey(r'$id'), isFalse);
    expect(decoded['additionalProperties'], isFalse);

    final artifact = File(p.join(resolveRepoRoot(), 'schemas', 'workflow.schema.json'));
    expect(generator.workflowSchemaIsCurrent(artifact, first), isTrue);

    final temp = Directory.systemTemp.createTempSync('dartclaw_workflow_schema_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final missing = File(p.join(temp.path, 'workflow.schema.json'));
    expect(generator.workflowSchemaIsCurrent(missing, first), isFalse);
    missing.writeAsStringSync('{}\n');
    expect(generator.workflowSchemaIsCurrent(missing, first), isFalse);
    expect(generator.workflowSchemaDriftMessage(missing.path), contains(missing.path));
    expect(generator.workflowSchemaDriftMessage(missing.path), contains(generator.regenerationCommand));
  });

  test('emitted vocabulary is framework agnostic', () {
    final rendered = jsonEncode(schema).toLowerCase();
    for (final forbidden in ['andthen', 'dartclaw-discover', 'plan.md', 'plan.json', 'prd.md']) {
      expect(rendered, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}

Map<String, Object?> _workflow(Map<String, Object?> step) => {
  'name': 'schema-test',
  'description': 'Schema test',
  'steps': [step],
};

Set<String> _schemaTypes(Map<Object?, Object?> schema, Map<String, Object?> root) {
  final node = Map<String, Object?>.from(schema);
  final reference = node[r'$ref'];
  if (reference is String) {
    final name = reference.split('/').last;
    final definitions = root[r'$defs']! as Map<Object?, Object?>;
    return _schemaTypes(Map<String, Object?>.from(definitions[name]! as Map<Object?, Object?>), root);
  }
  final types = <String>{};
  final type = node['type'];
  if (type is String) types.add(type);
  if (type is List<Object?>) types.addAll(type.cast<String>());
  for (final keyword in const ['oneOf', 'anyOf']) {
    if (node[keyword] case final List<Object?> branches) {
      for (final branch in branches.cast<Map<Object?, Object?>>()) {
        types.addAll(_schemaTypes(branch, root));
      }
    }
  }
  return types;
}

Set<String> _stringEnums(Map<String, Object?> schema) {
  final values = <String>{};
  if (schema['type'] == 'string') {
    if (schema['enum'] case final List<Object?> entries) values.addAll(entries.cast<String>());
  }
  for (final keyword in const ['oneOf', 'anyOf']) {
    if (schema[keyword] case final List<Object?> branches) {
      for (final branch in branches.cast<Map<Object?, Object?>>()) {
        values.addAll(_stringEnums(Map<String, Object?>.from(branch)));
      }
    }
  }
  if (schema['additionalProperties'] case final Map<Object?, Object?> additional) {
    values.addAll(_stringEnums(Map<String, Object?>.from(additional)));
  }
  return values;
}

String _jsonType(WorkflowValueKind kind) => switch (kind) {
  WorkflowValueKind.string => 'string',
  WorkflowValueKind.boolean => 'boolean',
  WorkflowValueKind.integer => 'integer',
  WorkflowValueKind.number => 'number',
  WorkflowValueKind.stringList || WorkflowValueKind.list => 'array',
  WorkflowValueKind.mapping => 'object',
  WorkflowValueKind.nullValue => 'null',
};
