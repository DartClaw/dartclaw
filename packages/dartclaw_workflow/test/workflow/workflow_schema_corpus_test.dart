import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/schema_presets.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_definition.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_definition_parser.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_definition_validator.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_dsl_rules.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_schema_emitter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../fitness_support.dart';
import 'workflow_json_schema_test_support.dart';

void main() {
  final root = resolveRepoRoot();
  final schema = emitWorkflowJsonSchema();
  final checker = WorkflowSchemaChecker(schema);
  final definitions = Map<String, Object?>.from(schema[r'$defs']! as Map);

  test('all seven maintained workflows validate against the emitted schema', () {
    final paths = [
      for (final name in ['plan-and-implement', 'spec-and-implement', 'code-review'])
        p.join(root, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions', '$name.yaml'),
      for (final name in [
        'plan-and-implement-inline',
        'spec-and-implement-inline',
        'review-and-remediate-inline',
        'multi-agent-review-inline',
      ])
        p.join(root, '.dartclaw', 'workflows', 'custom', '$name.yaml'),
    ];
    expect(paths.every((path) => File(path).existsSync()), isTrue, reason: paths.join('\n'));
    for (final path in paths) {
      final document = _plain(loadYaml(File(path).readAsStringSync()));
      expect(checker.validate(document), isEmpty, reason: p.relative(path, from: root));
    }
  });

  test('invalid mutations name their offending paths', () {
    final cases = <(Map<String, Object?>, String)>[
      (_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'promtp': 'typo'}), r'$.steps[0].promtp'),
      (_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'parallel': 'yes'}), r'$.steps[0].parallel'),
      (
        _workflow({
          'id': 'loop',
          'name': 'Loop',
          'type': 'loop',
          'maxIterations': 2,
          'exitGate': 'done == true',
          'onMaxIterations': 'sometimes',
          'steps': [
            {'id': 'inside', 'name': 'Inside', 'prompt': 'work'},
          ],
        }),
        r'$.steps[0].onMaxIterations',
      ),
      (_workflow({'id': 'bad', 'name': 'Bad', 'type': 'nonesuch', 'prompt': 'work'}), r'$.steps[0].type'),
      (_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'script': 'true'}), r'$.steps[0]'),
    ];
    for (final (document, path) in cases) {
      expect(
        checker.validate(document).where((diagnostic) => diagnostic.contains(path)),
        isNotEmpty,
        reason: '$document',
      );
    }
    expect(checker.validate(_workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work'})), isEmpty);
  });

  test('polymorphic authoring shapes and aliases validate', () {
    final stepShapes = <Map<String, Object?>>[
      {'prompt': 'one prompt'},
      {
        'prompt': ['one', 'two'],
      },
      {
        'prompt': 'work',
        'outputs': {'value': 'json'},
      },
      {
        'prompt': 'work',
        'outputs': {'value': schemaPresets.keys.first},
      },
      {
        'prompt': 'work',
        'outputs': {
          'value': {'schema': schemaPresets.keys.first},
        },
      },
      {
        'prompt': 'work',
        'outputs': {
          'value': {
            'schema': {'type': 'string'},
          },
        },
      },
      {'type': 'bash', 'script': 'true', 'timeout': '30s'},
      {'type': 'bash', 'script': 'true', 'timeout': 30},
      {'prompt': 'work', 'map_over': '{{items}}'},
      {'prompt': 'work', 'mapOver': '{{items}}'},
      {'prompt': 'work', 'continue_session': true},
      {'prompt': 'work', 'continueSession': 'prior'},
      {'prompt': 'work', 'on_failure': 'continue'},
      {'prompt': 'work', 'onFailure': 'retry'},
    ];
    for (var index = 0; index < stepShapes.length; index++) {
      expect(
        checker.validate(_workflow({'id': 'step-$index', 'name': 'Step $index', ...stepShapes[index]})),
        isEmpty,
        reason: '${stepShapes[index]}',
      );
    }
    for (final worktree in [
      'inline',
      {'mode': 'per-task'},
    ]) {
      expect(
        checker.validate({
          ..._workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work'}),
          'gitStrategy': {'worktree': worktree},
        }),
        isEmpty,
        reason: '$worktree',
      );
    }

    expect(
      checker.validate(
        _workflow({
          'id': 'agent',
          'name': 'Agent',
          'prompt': 'work',
          'outputs': {'value': 'not-a-format-or-preset'},
        }),
      ),
      contains(contains(r'$.steps[0].outputs.value')),
    );
  });

  test('closed step composition accepts legal keys and rejects wrong-type keys', () {
    final valid = [
      {'id': 'bash-script', 'name': 'Bash', 'type': 'bash', 'script': 'true'},
      {'id': 'agent-prompt', 'name': 'Agent', 'prompt': 'work'},
      {'id': 'bash-prompt', 'name': 'Bash', 'type': 'bash', 'prompt': 'true'},
    ];
    for (final step in valid) {
      expect(checker.validate(_workflow(step)), isEmpty, reason: '$step');
    }
    final invalid = [
      {'id': 'agent-script', 'name': 'Agent', 'prompt': 'work', 'script': 'true'},
      {'id': 'unknown', 'name': 'Unknown', 'prompt': 'work', 'unregistered': true},
    ];
    for (final step in invalid) {
      expect(checker.validate(_workflow(step)), isNotEmpty, reason: '$step');
    }
  });

  test('value-sensitive constraints match parser and validator acceptance', () {
    final cases = <({String name, Map<String, Object?> document, bool accepted})>[
      (
        name: 'map_over with parallel false',
        document: _mapWorkflow({'map_over': 'items', 'parallel': false}),
        accepted: true,
      ),
      (
        name: 'mapOver with parallel null',
        document: _mapWorkflow({'mapOver': 'items', 'parallel': null}),
        accepted: true,
      ),
      (
        name: 'map_over null with parallel true',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'map_over': null, 'parallel': true}),
        accepted: true,
      ),
      (
        name: 'map_over with parallel true',
        document: _mapWorkflow({'map_over': 'items', 'parallel': true}),
        accepted: false,
      ),
      (
        name: 'parallel true with continueSession false',
        document: _continuingWorkflow({'parallel': true, 'continueSession': false}),
        accepted: true,
      ),
      (
        name: 'parallel true with continue_session null',
        document: _continuingWorkflow({'parallel': true, 'continue_session': null}),
        accepted: true,
      ),
      (
        name: 'parallel true with continueSession true',
        document: _continuingWorkflow({'parallel': true, 'continueSession': true}),
        accepted: false,
      ),
      (
        name: 'bash script null without prompt',
        document: _workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'script': null}),
        accepted: true,
      ),
      (
        name: 'bash prompt null and script value',
        document: _workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'prompt': null, 'script': 'echo ok'}),
        accepted: false,
      ),
      (
        name: 'bash prompt value and script null',
        document: _workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'prompt': 'echo ok', 'script': null}),
        accepted: false,
      ),
      (
        name: 'bash prompt null and script null',
        document: _workflow({'id': 'bash', 'name': 'Bash', 'type': 'bash', 'prompt': null, 'script': null}),
        accepted: false,
      ),
      (
        name: 'agent prompt null without skill',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'prompt': null}),
        accepted: false,
      ),
      (
        name: 'agent skill null without prompt',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'skill': null}),
        accepted: false,
      ),
      (
        name: 'agent prompt and skill null',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'prompt': null, 'skill': null}),
        accepted: false,
      ),
      (
        name: 'agent prompt null with valued skill alternative',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'prompt': null, 'skill': 'run-skill'}),
        accepted: true,
      ),
      (
        name: 'agent valued prompt with skill null',
        document: _workflow({'id': 'agent', 'name': 'Agent', 'prompt': 'work', 'skill': null}),
        accepted: true,
      ),
    ];

    for (final testCase in cases) {
      final schemaDiagnostics = checker.validate(testCase.document);
      final parserResult = _parserAndValidatorAcceptance(testCase.document);
      expect(schemaDiagnostics.isEmpty, testCase.accepted, reason: '${testCase.name}: $schemaDiagnostics');
      expect(parserResult.accepted, testCase.accepted, reason: '${testCase.name}: ${parserResult.diagnostics}');
      expect(schemaDiagnostics.isEmpty, parserResult.accepted, reason: testCase.name);
    }
  });

  test('artifact surface and emitted vocabulary equal the rule source', () {
    expect(
      emittedSchemaKeywords(schema),
      unorderedEquals({
        r'$defs',
        r'$ref',
        r'$schema',
        'additionalProperties',
        'allOf',
        'anyOf',
        'const',
        'enum',
        'if',
        'items',
        'minItems',
        'not',
        'oneOf',
        'properties',
        'required',
        'then',
        'title',
        'type',
      }),
    );
    expect(
      emittedSchemaTypes(schema),
      unorderedEquals({'array', 'boolean', 'integer', 'null', 'number', 'object', 'string'}),
    );

    for (final block in WorkflowDslRules.blocks) {
      final blockSchema = block == WorkflowDslRules.workflow
          ? schema
          : Map<String, Object?>.from(definitions[block.name]! as Map);
      final properties = Map<String, Object?>.from(blockSchema['properties']! as Map);
      expect(properties.keys, unorderedEquals(block.keys), reason: block.name);
      for (final field in block.fields.where((field) => field.enumValues.isNotEmpty)) {
        expect(
          _stringEnums(Map<String, Object?>.from(properties[field.names.first]! as Map)),
          unorderedEquals(field.enumValues.map(_wireValue)),
          reason: '${block.name}.${field.names.first}',
        );
      }
    }

    final stepSchema = Map<String, Object?>.from(definitions['step']! as Map);
    for (final type in WorkflowTaskType.values) {
      for (final field in WorkflowDslRules.step.fields.where((field) => field.names.first != 'type')) {
        for (final kind in field.acceptedKinds) {
          final value = _sample(field, kind);
          final instance = <String, Object?>{
            'id': 'step',
            'name': 'Step',
            if (field.names.contains('skill')) 'prompt': 'prompt' else 'skill': 'skill',
            'type': type.toJson(),
          };
          for (final alias in field.names) {
            final candidate = {...instance, alias: value};
            final accepted = checker.validateNode(stepSchema, candidate).isEmpty;
            expect(
              accepted,
              field.acceptsKindForType(kind, type),
              reason: '${type.toJson()}.${field.names.first}.$alias.${kind.name}',
            );
          }
        }
      }
    }
  });
}

Map<String, Object?> _workflow(Map<String, Object?> step) => {
  'name': 'schema-corpus-test',
  'description': 'Schema corpus test',
  'steps': [step],
};

Map<String, Object?> _workflowSteps(List<Map<String, Object?>> steps) => {
  'name': 'schema-corpus-test',
  'description': 'Schema corpus test',
  'steps': steps,
};

Map<String, Object?> _continuingWorkflow(Map<String, Object?> fields) => _workflowSteps([
  {'id': 'source', 'name': 'Source', 'prompt': 'source'},
  {'id': 'target', 'name': 'Target', 'prompt': 'target', ...fields},
]);

Map<String, Object?> _mapWorkflow(Map<String, Object?> fields) => _workflowSteps([
  {
    'id': 'source',
    'name': 'Source',
    'prompt': 'source',
    'outputs': {'items': 'lines'},
  },
  {
    'id': 'map',
    'name': 'Map',
    'prompt': 'map',
    'foreach_steps': ['child'],
    ...fields,
  },
  {'id': 'child', 'name': 'Child', 'prompt': 'child'},
]);

({bool accepted, String diagnostics}) _parserAndValidatorAcceptance(Map<String, Object?> document) {
  try {
    final definition = WorkflowDefinitionParser().parse(jsonEncode(document));
    final errors = WorkflowDefinitionValidator().validate(definition).errors;
    return (accepted: errors.isEmpty, diagnostics: errors.join('\n'));
  } on FormatException catch (error) {
    return (accepted: false, diagnostics: error.message);
  }
}

Object? _plain(Object? value) => switch (value) {
  YamlMap map => {for (final entry in map.entries) '${entry.key}': _plain(entry.value)},
  YamlList list => [for (final item in list) _plain(item)],
  _ => value,
};

Object? _sample(WorkflowFieldRule field, WorkflowValueKind kind) {
  if (kind == WorkflowValueKind.string && field.enumValues.isNotEmpty) return _wireValue(field.enumValues.first);
  return switch (kind) {
    WorkflowValueKind.string => 'value',
    WorkflowValueKind.boolean => true,
    WorkflowValueKind.integer => 1,
    WorkflowValueKind.number => 1.5,
    WorkflowValueKind.stringList => <String>[],
    WorkflowValueKind.mapping => <String, Object?>{},
    WorkflowValueKind.list => <Object?>[],
    WorkflowValueKind.nullValue => null,
  };
}

String _wireValue(Object value) => switch (value) {
  WorkflowTaskType type => type.toJson(),
  OutputFormat format => format.name,
  SchemaPreset preset => preset.name,
  WorkflowGitWorktreeMode mode => mode.toJson(),
  MergeResolveEscalation escalation => escalation.toYamlString(),
  Enum value => value.name,
  _ => '$value',
};

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
  return values;
}
