import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ValidationError, ValidationReport, WorkflowDefinitionParser, WorkflowDefinitionValidator;

import '../config_loader.dart';
import '../serve_command.dart' show WriteLine;

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

  WorkflowValidateCommand({DartclawConfig? config, WriteLine? writeLine})
    : _config = config,
      _writeLine = writeLine ?? stdout.writeln;

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
    final validator = WorkflowDefinitionValidator();

    // --- Parse phase ---
    exitCode = 0;

    final ValidationReport report;
    final String workflowName;
    try {
      final content = await File(path).readAsString();
      final definition = parser.parse(content, sourcePath: path);
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

    // --- Diagnostics output ---
    _printReport(path, workflowName, report);

    if (report.hasErrors) {
      exitCode = 1;
    }
  }

  void _printReport(String path, String workflowName, ValidationReport report) {
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

    if (report.errors.isEmpty && report.warnings.isEmpty) {
      _writeLine('No issues found.');
      _writeLine('');
    }

    final parts = <String>[];
    if (report.errors.isNotEmpty) {
      parts.add('${report.errors.length} error${report.errors.length == 1 ? '' : 's'}');
    }
    if (report.warnings.isNotEmpty) {
      parts.add('${report.warnings.length} warning${report.warnings.length == 1 ? '' : 's'}');
    }

    if (report.hasErrors) {
      _writeLine('Result: INVALID (${parts.join(', ')})');
    } else if (report.hasWarnings) {
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
