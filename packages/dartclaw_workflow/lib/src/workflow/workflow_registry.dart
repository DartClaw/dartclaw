import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowDefinition;
import 'package:logging/logging.dart';

import 'workflow_definition_source.dart';
import 'workflow_definition_resolver.dart';
import 'workflow_definition_parser.dart';
import 'skill_registry.dart';
import 'workflow_definition_validator.dart' show ValidationReport, WorkflowDefinitionValidator;

/// Source type for a registered workflow definition.
enum WorkflowSource {
  /// Materialized into the workspace from bundled assets or the source tree.
  materialized,

  /// User-authored — discovered from a filesystem directory.
  custom,
}

class _RegisteredWorkflow {
  final WorkflowDefinition definition;
  final WorkflowSource source;
  final String? sourcePath;
  final String? sourceFingerprint;

  const _RegisteredWorkflow({required this.definition, required this.source, this.sourcePath, this.sourceFingerprint});
}

/// Production registry of workflow definitions - materialized and custom.
///
/// Implements [WorkflowDefinitionSource] as the single source of workflow
/// definitions for the API routes, CLI, and UI.
///
/// Materialized workflows are loaded from the workspace copy of the bundled
/// YAML definitions. Custom workflows are discovered from filesystem
/// directories at startup.
///
/// Name collision policy: materialized names take precedence. Custom
/// workflows with the same name as a materialized workflow are logged and
/// skipped.
class WorkflowRegistry implements WorkflowDefinitionSource {
  static const _resolver = WorkflowDefinitionResolver();

  final WorkflowDefinitionParser _parser;
  final WorkflowDefinitionValidator _validator;
  final Set<String>? _continuityProviders;
  final Logger _log;

  final Map<String, _RegisteredWorkflow> _definitions = {};

  WorkflowRegistry({
    required WorkflowDefinitionParser parser,
    required WorkflowDefinitionValidator validator,
    Set<String>? continuityProviders,
    Logger? log,
  }) : _parser = parser,
       _validator = validator,
       _continuityProviders = continuityProviders,
       _log = log ?? Logger('WorkflowRegistry');

  set skillRegistry(SkillRegistry? registry) => _validator.skillRegistry = registry;

  /// Discovers and loads custom workflow YAML files from [directory].
  ///
  /// Scans for `.yaml` files (non-recursive), parses and validates each.
  /// Valid definitions are registered with the provided [source].
  /// Invalid files are logged and skipped — the server continues without them.
  ///
  /// If [directory] does not exist, this is a no-op (not an error).
  Future<void> loadFromDirectory(String directory, {WorkflowSource source = WorkflowSource.custom}) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      _log.fine('Workflow directory does not exist, skipping: $directory');
      return;
    }

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yaml')) continue;
      final sourceLabel = source == WorkflowSource.materialized ? 'Materialized' : 'Custom';

      try {
        final content = await entity.readAsString();
        final definition = _parser.parse(content, sourcePath: entity.path);
        final ValidationReport report = _validator.validate(definition, continuityProviders: _continuityProviders);
        if (report.hasErrors) {
          _log.warning(
            '$sourceLabel workflow excluded: ${entity.path} — '
            'validation errors: ${report.errors.join('; ')}',
          );
          continue;
        }
        if (report.hasWarnings) {
          _log.warning(
            '$sourceLabel workflow "${definition.name}" from ${entity.path} '
            'loaded with warnings: ${report.warnings.join('; ')}',
          );
        }

        // Name collision check — materialized names always win.
        if (_definitions.containsKey(definition.name)) {
          final existing = _definitions[definition.name]!;
          if (existing.source == WorkflowSource.materialized && source == WorkflowSource.custom) {
            _log.warning(
              'Custom workflow "${definition.name}" from ${entity.path} skipped '
              '— name conflicts with materialized workflow. Choose a different name.',
            );
            continue;
          }
          if (existing.source == WorkflowSource.custom && source == WorkflowSource.materialized) {
            _log.warning(
              'Materialized workflow "${definition.name}" from ${entity.path} '
              'replaces previous custom definition.',
            );
          } else if (existing.source == WorkflowSource.custom && source == WorkflowSource.custom) {
            // Custom-to-custom collision: last loaded wins with warning.
            _log.warning(
              'Custom workflow "${definition.name}" from ${entity.path} '
              'replaces previous custom definition.',
            );
          }
        }

        _definitions[definition.name] = _RegisteredWorkflow(
          definition: definition,
          source: source,
          sourcePath: entity.path,
          sourceFingerprint: _fingerprintString(content),
        );
        if (source == WorkflowSource.materialized) {
          _log.info('Loaded materialized workflow: ${definition.name}');
        } else {
          _log.info('Loaded custom workflow: ${definition.name} from ${entity.path}');
        }
      } on FormatException catch (e) {
        _log.warning('$sourceLabel workflow excluded: ${entity.path} — invalid YAML: $e');
      } on ArgumentError catch (e) {
        _log.warning('$sourceLabel workflow excluded: ${entity.path} — invalid workflow definition: $e');
      } on TypeError catch (e, st) {
        // TypeError out of the parser indicates a hard cast failure inside
        // WorkflowDefinitionParser (a parser bug), not malformed user input.
        // Log at severe so it stays visible alongside other internal errors;
        // the workflow is still excluded so the registry remains usable.
        _log.severe('$sourceLabel workflow excluded: ${entity.path} — internal parser error: $e', e, st);
      } on FileSystemException catch (e) {
        _log.warning('$sourceLabel workflow excluded: ${entity.path} — file read error: $e');
      }
    }
  }

  @override
  WorkflowDefinition? getByName(String name) {
    _refreshIfSourceChanged(name);
    return _definitions[name]?.definition;
  }

  @override
  String? authoredYaml(String name) {
    _refreshIfSourceChanged(name);
    final registered = _definitions[name];
    if (registered == null) return null;
    final sourcePath = registered.sourcePath;
    if (sourcePath != null) {
      final file = File(sourcePath);
      if (file.existsSync()) return file.readAsStringSync();
    }
    return _resolver.emitYaml(registered.definition);
  }

  @override
  List<WorkflowSummary> listSummaries() {
    _refreshAllSources();
    return _definitions.values.map((registered) => _toSummary(registered.definition)).toList(growable: false);
  }

  List<WorkflowDefinition> listAll() {
    _refreshAllSources();
    return _definitions.values.map((r) => r.definition).toList(growable: false);
  }

  /// Returns only materialized workflow definitions.
  List<WorkflowDefinition> listMaterialized() {
    _refreshAllSources();
    return _definitions.values
        .where((r) => r.source == WorkflowSource.materialized)
        .map((r) => r.definition)
        .toList(growable: false);
  }

  /// Compatibility alias for older callers.
  @Deprecated('Use listMaterialized()')
  List<WorkflowDefinition> listBuiltIn() => listMaterialized();

  /// Returns only custom workflow definitions.
  List<WorkflowDefinition> listCustom() {
    _refreshAllSources();
    return _definitions.values
        .where((r) => r.source == WorkflowSource.custom)
        .map((r) => r.definition)
        .toList(growable: false);
  }

  int get length => _definitions.length;

  WorkflowSource? sourceOf(String name) {
    _refreshIfSourceChanged(name);
    return _definitions[name]?.source;
  }

  void _refreshAllSources() {
    for (final name in _definitions.keys.toList(growable: false)) {
      _refreshIfSourceChanged(name);
    }
  }

  void _refreshIfSourceChanged(String name) {
    final registered = _definitions[name];
    if (registered == null) return;
    final sourcePath = registered.sourcePath;
    if (sourcePath == null) return;
    final file = File(sourcePath);
    if (!file.existsSync()) return;

    final content = file.readAsStringSync();
    final fingerprint = _fingerprintString(content);
    if (fingerprint == registered.sourceFingerprint) return;

    try {
      final definition = _parser.parse(content, sourcePath: sourcePath);
      if (definition.name != name) {
        _log.warning(
          'Workflow source changed name from "$name" to "${definition.name}" in $sourcePath; keeping previous definition.',
        );
        return;
      }
      final report = _validator.validate(definition, continuityProviders: _continuityProviders);
      if (report.hasErrors) {
        _log.warning(
          'Workflow source changed but reload was rejected for $sourcePath — '
          'validation errors: ${report.errors.join('; ')}',
        );
        return;
      }
      if (report.hasWarnings) {
        _log.warning('Workflow source changed and reloaded for "$name" with warnings: ${report.warnings.join('; ')}');
      }
      _definitions[name] = _RegisteredWorkflow(
        definition: definition,
        source: registered.source,
        sourcePath: sourcePath,
        sourceFingerprint: fingerprint,
      );
      _log.info('Reloaded workflow definition "$name" from changed source: $sourcePath');
    } on FormatException catch (e) {
      _log.warning('Workflow source changed but reload was rejected for $sourcePath — invalid YAML: $e');
    } on ArgumentError catch (e) {
      _log.warning('Workflow source changed but reload was rejected for $sourcePath — invalid workflow definition: $e');
    } on TypeError catch (e, st) {
      _log.severe('Workflow source changed but reload hit an internal parser error for $sourcePath: $e', e, st);
    } on FileSystemException catch (e) {
      _log.warning('Workflow source changed but reload could not read $sourcePath: $e');
    }
  }

  static WorkflowSummary _toSummary(WorkflowDefinition definition) => (
    name: definition.name,
    description: definition.description,
    stepCount: definition.steps.length,
    hasLoops: definition.loops.isNotEmpty,
    maxTokens: definition.maxTokens,
    variables: definition.variables,
  );

  static String _fingerprintString(String value) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
