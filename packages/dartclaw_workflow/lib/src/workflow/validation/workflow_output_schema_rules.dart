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

        // `outputs` and `step_outcome` are the execution envelope's top-level
        // keys — a declared output using either would collide with the finalizer
        // shape, so they are reserved host-side.
        if (reservedEnvelopeOutputKeys.contains(key)) {
          errors.add(
            _err(
              ValidationErrorType.invalidReference,
              'Step "${step.id}" output "$key" uses a reserved execution-envelope key name. '
              '"$executionEnvelopeOutputsKey" and "$executionEnvelopeStepOutcomeKey" are reserved by the host.',
              stepId: step.id,
            ),
          );
          continue;
        }

        final description = config.description?.trim();
        if (description != null && description.isNotEmpty) {
          descriptionsByOutput.putIfAbsent(key, () => <(String, String)>[]).add((step.id, description));
        }

        // Non-null but whitespace-only description is always an authoring
        // mistake — either provide content or omit the key.
        if (config.description != null && config.description!.trim().isEmpty) {
          errors.add(
            _err(
              ValidationErrorType.missingField,
              'Step "${step.id}" output "$key" has a blank "description" — '
              'provide content or remove the key.',
              stepId: step.id,
            ),
          );
        }

        // Schema preset name must be known.
        if (config.presetName != null) {
          final preset = schemaPresets[config.presetName];
          if (preset == null) {
            errors.add(
              _err(
                ValidationErrorType.invalidReference,
                'Step "${step.id}" output "$key" references unknown schema preset "${config.presetName}".',
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
              _contextErr(
                step.id,
                'Step "${step.id}" output "$key" sets both an inline "description" and '
                'references preset "${config.presetName}" which already provides one. '
                'The inline description overrides the preset — drop one to avoid drift.',
              ),
            );
          }
        }

        // Inline schema must be an object with 'type', and must not use
        // unsupported JSON Schema keywords that would silently green-light.
        if (config.inlineSchema != null) {
          if (!config.inlineSchema!.containsKey('type')) {
            errors.add(
              _err(
                ValidationErrorType.missingField,
                'Step "${step.id}" output "$key" inline schema missing "type" field.',
                stepId: step.id,
              ),
            );
          }
          final schemaValidator = const SchemaValidator();
          final unsupportedDiagnostics = schemaValidator.checkUnsupportedKeywords(config.inlineSchema!, path: key);
          for (final diagnostic in unsupportedDiagnostics) {
            errors.add(_contextErr(step.id, 'Step "${step.id}" output "$key" inline schema: $diagnostic'));
          }
        }

        // `preferPatterns` break a multi-match tie by bare basename, compared
        // against a candidate's `p.basename`. A path separator could never
        // equal a basename, so reject separators and empties as authoring bugs.
        final resolverOverride = config.resolverOverride;
        if (resolverOverride is FileSystemOutput) {
          for (final pattern in resolverOverride.preferPatterns) {
            if (pattern.trim().isEmpty || pattern.contains('/') || pattern.contains(r'\')) {
              errors.add(
                _err(
                  ValidationErrorType.invalidReference,
                  'Step "${step.id}" output "$key": preferPatterns entries must be non-empty bare basenames '
                  '(no path separators): "$pattern".',
                  stepId: step.id,
                ),
              );
            }
          }
        }

        // Foreach controllers emit a system-generated aggregate list — the
        // shape is dictated by the controller, not extracted from an LLM
        // response, so the json+schema requirement does not apply.
        if (config.format == OutputFormat.json && !config.hasSchema && !step.isForeachController) {
          errors.add(
            _err(
              ValidationErrorType.missingField,
              'Step "${step.id}" output "$key": format: json requires a schema '
              '(preset name or inline schema).',
              stepId: step.id,
            ),
          );
        }

        if (config.outputMode == OutputMode.structured) {
          if (config.format != OutputFormat.json) {
            errors.add(
              _contextErr(
                step.id,
                'Step "${step.id}" output "$key" uses outputMode: structured but format is '
                '"${config.format.name}". Structured output requires format: json.',
              ),
            );
          }
          if (!config.hasSchema) {
            errors.add(
              _err(
                ValidationErrorType.missingField,
                'Step "${step.id}" output "$key" uses outputMode: structured but has no schema. '
                'Structured output requires a schema preset or inline schema.',
                stepId: step.id,
              ),
            );
          }
          final inlineSchema = config.inlineSchema;
          if (inlineSchema != null) {
            final violations = <String>[];
            _collectStructuredSchemaViolations(inlineSchema, path: key, violations: violations);
            for (final violation in violations) {
              errors.add(_contextErr(step.id, 'Step "${step.id}" output "$key" inline schema $violation'));
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
        _contextErr(
          null,
          'Output "${entry.key}" is produced by multiple steps with different descriptions '
          '($producers). The first producer wins in context-summary rendering.',
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
