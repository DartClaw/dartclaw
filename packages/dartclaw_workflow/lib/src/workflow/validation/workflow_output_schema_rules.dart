part of '../workflow_definition_validator.dart';

extension _WorkflowOutputSchemaRules on WorkflowDefinitionValidator {
  void _validateOutputConfigs(
    WorkflowDefinition definition,
    List<ValidationError> errors,
    List<ValidationError> warnings,
  ) {
    final descriptionsByOutput = <String, List<(String, String)>>{};

    for (final step in definition.steps) {
      if (step.outputs == null) continue;

      for (final entry in step.outputs!.entries) {
        final key = entry.key;
        final config = entry.value;
        final description = config.description?.trim();
        if (description != null && description.isNotEmpty) {
          descriptionsByOutput.putIfAbsent(key, () => <(String, String)>[]).add((step.id, description));
        }

        // Non-null but whitespace-only description is always an authoring
        // mistake — either provide content or omit the key.
        if (config.description != null && config.description!.trim().isEmpty) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" output "$key" has a blank "description" — '
                  'provide content or remove the key.',
              type: ValidationErrorType.missingField,
              stepId: step.id,
            ),
          );
        }

        // Output key must be in contextOutputs.
        if (!step.contextOutputs.contains(key)) {
          errors.add(
            ValidationError(
              message: 'Step "${step.id}" output "$key" is not declared in contextOutputs.',
              type: ValidationErrorType.contextInconsistency,
              stepId: step.id,
            ),
          );
        }

        // Schema preset name must be known.
        if (config.presetName != null) {
          final preset = schemaPresets[config.presetName];
          if (preset == null) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" output "$key" references unknown schema preset "${config.presetName}".',
                type: ValidationErrorType.invalidReference,
                stepId: step.id,
              ),
            );
          } else if (preset.description != null &&
              preset.description!.trim().isNotEmpty &&
              config.description != null &&
              config.description!.trim().isNotEmpty) {
            // Both preset and YAML define a description — the inline one wins,
            // defeating the point of referencing the preset. Warn the author
            // so they can drop one or the other intentionally.
            warnings.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" sets both an inline "description" and '
                    'references preset "${config.presetName}" which already provides one. '
                    'The inline description overrides the preset — drop one to avoid drift.',
                type: ValidationErrorType.contextInconsistency,
                stepId: step.id,
              ),
            );
          }
        }

        // Inline schema must be an object with 'type'.
        if (config.inlineSchema != null) {
          if (!config.inlineSchema!.containsKey('type')) {
            errors.add(
              ValidationError(
                message: 'Step "${step.id}" output "$key" inline schema missing "type" field.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
          }
        }

        if (config.format == OutputFormat.json && !config.hasSchema) {
          errors.add(
            ValidationError(
              message:
                  'Step "${step.id}" output "$key": format: json requires a schema '
                  '(preset name or inline schema).',
              type: ValidationErrorType.missingField,
              stepId: step.id,
            ),
          );
        }

        if (config.outputMode == OutputMode.structured) {
          if (config.format != OutputFormat.json) {
            errors.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" uses outputMode: structured but format is '
                    '"${config.format.name}". Structured output requires format: json.',
                type: ValidationErrorType.contextInconsistency,
                stepId: step.id,
              ),
            );
          }
          if (!config.hasSchema) {
            errors.add(
              ValidationError(
                message:
                    'Step "${step.id}" output "$key" uses outputMode: structured but has no schema. '
                    'Structured output requires a schema preset or inline schema.',
                type: ValidationErrorType.missingField,
                stepId: step.id,
              ),
            );
          }
          final inlineSchema = config.inlineSchema;
          if (inlineSchema != null) {
            final violations = <String>[];
            _collectStructuredSchemaViolations(inlineSchema, path: key, violations: violations);
            for (final violation in violations) {
              errors.add(
                ValidationError(
                  message: 'Step "${step.id}" output "$key" inline schema $violation',
                  type: ValidationErrorType.contextInconsistency,
                  stepId: step.id,
                ),
              );
            }
          }
        }
      }
    }

    for (final entry in descriptionsByOutput.entries) {
      final uniqueDescriptions = entry.value.map((item) => item.$2).toSet();
      if (uniqueDescriptions.length < 2) continue;
      final producers = entry.value.map((item) => item.$1).join(', ');
      warnings.add(
        ValidationError(
          message:
              'Output "${entry.key}" is produced by multiple steps with different descriptions '
              '($producers). The first producer wins in context-summary rendering.',
          type: ValidationErrorType.contextInconsistency,
        ),
      );
    }
  }

  void _collectStructuredSchemaViolations(
    Map<String, dynamic> schema, {
    required String path,
    required List<String> violations,
  }) {
    final type = schema['type'];
    if (type == 'object') {
      final additionalProperties = schema['additionalProperties'];
      if (additionalProperties != false) {
        violations.add('at "$path" must set additionalProperties: false.');
      }
      final properties = schema['properties'];
      if (properties is Map<String, dynamic>) {
        for (final entry in properties.entries) {
          final child = entry.value;
          if (child is Map<String, dynamic>) {
            _collectStructuredSchemaViolations(child, path: '$path.${entry.key}', violations: violations);
          }
        }
      }
    } else if (type == 'array') {
      final items = schema['items'];
      if (items is Map<String, dynamic>) {
        _collectStructuredSchemaViolations(items, path: '$path[]', violations: violations);
      }
    }
  }

}
