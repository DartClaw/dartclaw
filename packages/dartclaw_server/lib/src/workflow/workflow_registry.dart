import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        builtInWorkflowYaml;
import 'package:logging/logging.dart';

import 'workflow_definition_source.dart';

/// Source type for a registered workflow definition.
enum WorkflowSource {
  /// Bundled with DartClaw — loaded from embedded constants.
  builtIn,

  /// User-authored — discovered from a filesystem directory.
  custom,
}

class _RegisteredWorkflow {
  final WorkflowDefinition definition;
  final WorkflowSource source;
  final String? sourcePath;

  const _RegisteredWorkflow({
    required this.definition,
    required this.source,
    this.sourcePath,
  });
}

/// Production registry of workflow definitions — built-in and custom.
///
/// Implements [WorkflowDefinitionSource] (S05) to serve as the single
/// source of workflow definitions for the API routes, CLI, and UI.
///
/// Built-in workflows are loaded from embedded Dart string constants
/// (derived from the YAML source files in `definitions/`). Custom
/// workflows are discovered from filesystem directories at startup.
///
/// Name collision policy: built-in names take precedence. Custom
/// workflows with the same name as a built-in are logged and skipped.
class WorkflowRegistry implements WorkflowDefinitionSource {
  final WorkflowDefinitionParser _parser;
  final WorkflowDefinitionValidator _validator;
  final Logger _log;

  final Map<String, _RegisteredWorkflow> _definitions = {};

  WorkflowRegistry({
    required WorkflowDefinitionParser parser,
    required WorkflowDefinitionValidator validator,
    Logger? log,
  }) : _parser = parser,
       _validator = validator,
       _log = log ?? Logger('WorkflowRegistry');

  /// Loads all built-in workflow definitions from embedded constants.
  ///
  /// Called once during server startup before custom discovery, so that
  /// built-in names take precedence over any custom workflows with the
  /// same name.
  void loadBuiltIn() {
    for (final entry in builtInWorkflowYaml.entries) {
      try {
        final definition = _parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        final errors = _validator.validate(definition);
        if (errors.isNotEmpty) {
          _log.severe(
            'Built-in workflow "${entry.key}" failed validation: '
            '${errors.join('; ')}. This is a bug — please report it.',
          );
          continue;
        }
        _definitions[definition.name] = _RegisteredWorkflow(
          definition: definition,
          source: WorkflowSource.builtIn,
        );
        _log.info('Loaded built-in workflow: ${definition.name}');
      } on FormatException catch (e) {
        _log.severe(
          'Built-in workflow "${entry.key}" has invalid YAML: $e. '
          'This is a bug — please report it.',
        );
      }
    }
  }

  /// Discovers and loads custom workflow YAML files from [directory].
  ///
  /// Scans for `.yaml` files (non-recursive), parses and validates each.
  /// Valid definitions are registered with source type [WorkflowSource.custom].
  /// Invalid files are logged and skipped — the server continues without them.
  ///
  /// If [directory] does not exist, this is a no-op (not an error).
  Future<void> loadFromDirectory(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      _log.fine('Workflow directory does not exist, skipping: $directory');
      return;
    }

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml')) continue;

      try {
        final content = await entity.readAsString();
        final definition = _parser.parse(content, sourcePath: entity.path);
        final errors = _validator.validate(definition);
        if (errors.isNotEmpty) {
          _log.warning(
            'Custom workflow excluded: ${entity.path} — '
            'validation errors: ${errors.join('; ')}',
          );
          continue;
        }

        // Name collision check — built-in names always win.
        if (_definitions.containsKey(definition.name)) {
          final existing = _definitions[definition.name]!;
          if (existing.source == WorkflowSource.builtIn) {
            _log.warning(
              'Custom workflow "${definition.name}" from '
              '${entity.path} skipped — name conflicts with built-in '
              'workflow. Choose a different name.',
            );
            continue;
          }
          // Custom-to-custom collision: last loaded wins with warning.
          _log.warning(
            'Custom workflow "${definition.name}" from '
            '${entity.path} replaces previous custom definition.',
          );
        }

        _definitions[definition.name] = _RegisteredWorkflow(
          definition: definition,
          source: WorkflowSource.custom,
          sourcePath: entity.path,
        );
        _log.info('Loaded custom workflow: ${definition.name} from ${entity.path}');
      } on FormatException catch (e) {
        _log.warning('Custom workflow excluded: ${entity.path} — invalid YAML: $e');
      } on FileSystemException catch (e) {
        _log.warning('Custom workflow excluded: ${entity.path} — file read error: $e');
      }
    }
  }

  @override
  WorkflowDefinition? getByName(String name) => _definitions[name]?.definition;

  @override
  List<WorkflowDefinition> listAll() =>
      _definitions.values.map((r) => r.definition).toList();

  /// Returns only built-in workflow definitions.
  List<WorkflowDefinition> listBuiltIn() => _definitions.values
      .where((r) => r.source == WorkflowSource.builtIn)
      .map((r) => r.definition)
      .toList();

  /// Returns only custom workflow definitions.
  List<WorkflowDefinition> listCustom() => _definitions.values
      .where((r) => r.source == WorkflowSource.custom)
      .map((r) => r.definition)
      .toList();

  /// Returns the number of registered workflows.
  int get length => _definitions.length;

  /// Returns the source type for a workflow by name, or null if not found.
  WorkflowSource? sourceOf(String name) => _definitions[name]?.source;
}
