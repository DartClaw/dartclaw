import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show CredentialRegistry, DartclawConfig, ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        CliSkillIntrospector,
        SkillIntrospector,
        ValidationError,
        ValidationReport,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        WorkflowSkillCheckResult,
        checkWorkflowSkillRefs;

import '../config_loader.dart';
import '../serve_command.dart' show WriteLine;
import 'workflow_provider_environment.dart';
import 'workflow_skill_preflight_config.dart';

/// Validates a workflow YAML file at the given path.
///
/// Parses and validates the file, printing grouped diagnostics:
///   - Parse errors (malformed YAML)
///   - Validation errors (semantic hard failures)
///   - Warnings (soft notices)
///
/// Exit codes:
///   0 — clean or warnings-only (loadable)
///   1 — parse error or validation errors (would not load)
class WorkflowValidateCommand extends Command<void> {
  final DartclawConfig? _config;
  final WriteLine _writeLine;
  final SkillIntrospector? _introspector;

  WorkflowValidateCommand({DartclawConfig? config, WriteLine? writeLine, SkillIntrospector? introspector})
    : _config = config,
      _writeLine = writeLine ?? stdout.writeln,
      _introspector = introspector {
    argParser.addFlag(
      'skills',
      negatable: false,
      help: 'Probe each step\'s provider for its referenced skill and warn on unresolvable refs.',
    );
  }

  @override
  String get name => 'validate';

  @override
  String get description =>
      'Validate a workflow YAML file and print grouped diagnostics.\n'
      'Exits 0 for clean or warnings-only definitions, 1 for errors.';

  @override
  String get invocation => '${runner?.executableName} workflow validate <path>';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Missing required argument: <path>');
    }
    final path = rest.first;

    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);

    // Derive continuity providers by probing harness capabilities.
    final allContinuityProviders = HarnessFactory().probeContinuityProviders();
    final continuityProviders = config.providers.entries.keys.where(allContinuityProviders.contains).toSet();

    final parser = WorkflowDefinitionParser();
    final validator = WorkflowDefinitionValidator(roleDefaults: _workflowRoleDefaults(config));

    // --- Parse phase ---
    exitCode = 0;

    final ValidationReport report;
    final WorkflowDefinition definition;
    final String workflowName;
    try {
      final content = await File(path).readAsString();
      definition = parser.parse(content, sourcePath: path);
      workflowName = definition.name;
      report = validator.validate(definition, continuityProviders: continuityProviders);
    } on FileSystemException catch (e) {
      _writeLine('Parse error: ${e.message}: $path');
      exitCode = 1;
      return;
    } on FormatException catch (e) {
      _writeLine('Parse errors:');
      _writeLine('  ${e.message}');
      _writeLine('');
      _writeLine('Result: INVALID (1 parse error)');
      exitCode = 1;
      return;
    }

    // Opt-in skill probe: never affects exit code (warnings/notes only) and
    // never hard-fails — any unexpected error degrades to an informational note.
    WorkflowSkillCheckResult? skillResult;
    if (argResults!['skills'] as bool) {
      try {
        skillResult = await _checkSkills(config, definition);
      } catch (e) {
        skillResult = WorkflowSkillCheckResult(
          unresolved: const [],
          probeNotes: ['Skill resolution could not be checked: $e'],
        );
      }
    }

    // --- Diagnostics output ---
    _printReport(path, workflowName, report, skillResult);

    if (report.hasErrors) {
      exitCode = 1;
    }
  }

  Future<WorkflowSkillCheckResult> _checkSkills(DartclawConfig config, WorkflowDefinition definition) {
    final introspector =
        _introspector ??
        CliSkillIntrospector(
          environmentForProvider: (providerId) => buildWorkflowProviderEnvironment(
            providerId: providerId,
            providerFamily: ProviderIdentity.resolveFamily(
              providerId,
              options: workflowProviderOptions(config, providerId),
              executable: resolveWorkflowProviderExecutable(config, providerId),
            ),
            registry: CredentialRegistry(credentials: config.credentials, env: Platform.environment),
            baseEnvironment: Platform.environment,
          ),
        );
    return checkWorkflowSkillRefs(
      definition: definition,
      introspector: introspector,
      skillPreflightConfig: buildWorkflowSkillPreflightConfig(config),
      roleDefaults: _workflowRoleDefaults(config),
    );
  }

  void _printReport(String path, String workflowName, ValidationReport report, WorkflowSkillCheckResult? skillResult) {
    _writeLine('Validating: $path');
    _writeLine('');

    if (report.errors.isNotEmpty) {
      _writeLine('Validation errors (${report.errors.length}):');
      for (final e in report.errors) {
        _writeLine('  ${_formatDiagnostic(e)}');
      }
      _writeLine('');
    }

    if (report.warnings.isNotEmpty) {
      _writeLine('Warnings (${report.warnings.length}):');
      for (final w in report.warnings) {
        _writeLine('  ${_formatDiagnostic(w)}');
      }
      _writeLine('');
    }

    final skillWarnings = skillResult?.unresolved ?? const [];
    final skillNotes = skillResult?.probeNotes ?? const [];
    if (skillWarnings.isNotEmpty) {
      _writeLine('Skill warnings (${skillWarnings.length}):');
      for (final w in skillWarnings) {
        _writeLine('  [step=${w.stepId}] skill "${w.skill}" is not resolvable for provider "${w.provider}"');
      }
      _writeLine('');
    }
    if (skillNotes.isNotEmpty) {
      _writeLine('Skill resolution not checked (${skillNotes.length}):');
      for (final note in skillNotes) {
        _writeLine('  $note');
      }
      _writeLine('');
    }

    if (report.errors.isEmpty && report.warnings.isEmpty && skillWarnings.isEmpty && skillNotes.isEmpty) {
      _writeLine('No issues found.');
      _writeLine('');
    }

    // Skill warnings are advisory (opt-in probe): they widen the warning count
    // and flip a clean run to "OK with warnings", but never to INVALID.
    final totalWarnings = report.warnings.length + skillWarnings.length;
    final parts = <String>[];
    if (report.errors.isNotEmpty) {
      parts.add('${report.errors.length} error${report.errors.length == 1 ? '' : 's'}');
    }
    if (totalWarnings > 0) {
      parts.add('$totalWarnings warning${totalWarnings == 1 ? '' : 's'}');
    }

    if (report.hasErrors) {
      _writeLine('Result: INVALID (${parts.join(', ')})');
    } else if (totalWarnings > 0) {
      _writeLine('Result: OK with warnings (${parts.join(', ')})');
    } else {
      _writeLine('Result: OK');
    }
  }

  String _formatDiagnostic(ValidationError e) {
    final location = [if (e.stepId != null) 'step=${e.stepId}', if (e.loopId != null) 'loop=${e.loopId}'].join(', ');
    return location.isEmpty ? e.message : '[$location] ${e.message}';
  }
}

WorkflowRoleDefaults _workflowRoleDefaults(DartclawConfig config) => WorkflowRoleDefaults(
  workflow: WorkflowRoleDefault(
    provider: config.workflow.defaults.workflow.provider,
    model: config.workflow.defaults.workflow.model,
    effort: config.workflow.defaults.workflow.effort,
  ),
  planner: WorkflowRoleDefault(
    provider: config.workflow.defaults.planner.provider,
    model: config.workflow.defaults.planner.model,
    effort: config.workflow.defaults.planner.effort,
  ),
  executor: WorkflowRoleDefault(
    provider: config.workflow.defaults.executor.provider,
    model: config.workflow.defaults.executor.model,
    effort: config.workflow.defaults.executor.effort,
  ),
  reviewer: WorkflowRoleDefault(
    provider: config.workflow.defaults.reviewer.provider,
    model: config.workflow.defaults.reviewer.model,
    effort: config.workflow.defaults.reviewer.effort,
  ),
);
