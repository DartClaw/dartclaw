import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowDefinitionParser, WorkflowDefinitionValidator, WorkflowRegistry, WorkflowSource;
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import '../workflow_materializer.dart';
import '../serve_command.dart' show WriteLine;
import 'project_definition_paths.dart';

/// Lists available workflows (materialized + custom).
///
/// Default output is tabular with columns NAME, STEPS, SOURCE, DESCRIPTION.
/// Use `--json` for machine-readable JSON array output.
class WorkflowListCommand extends Command<void> {
  final DartclawConfig? _config;
  final AssetResolver _assetResolver;
  final WriteLine _writeLine;

  WorkflowListCommand({DartclawConfig? config, AssetResolver? assetResolver, WriteLine? writeLine})
    : _config = config,
      _assetResolver = assetResolver ?? AssetResolver(),
      _writeLine = writeLine ?? stdout.writeln {
    argParser
      ..addFlag('json', negatable: false, help: 'Output as JSON')
      ..addFlag('standalone', negatable: false, hide: true);
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List available workflows';

  @override
  Future<void> run() async {
    final globalConfigPath = globalResults?.options.contains('config') ?? false
        ? globalResults!['config'] as String?
        : null;
    final configPath = argResults!['standalone'] as bool
        ? resolveStandaloneWorkflowConfigPath(configPath: globalConfigPath)
        : resolveCliConfigPath(configPath: globalConfigPath);
    final config = _config ?? loadCliConfig(configPath: configPath);
    final registry = await buildWorkflowRegistry(config, assetResolver: _assetResolver);

    final definitions = registry.listAll();
    if (argResults!['json'] as bool) {
      _printJson(definitions, registry);
    } else {
      _printTable(definitions, registry);
    }
  }

  void _printExclusions(WorkflowRegistry registry) {
    final exclusions = registry.exclusions;
    if (exclusions.isEmpty) return;
    _writeLine('');
    _writeLine('Excluded at load time (${exclusions.length}):');
    for (final excl in exclusions) {
      final label = excl.workflowName ?? excl.sourcePath;
      _writeLine('  $label: ${excl.errors.join('; ')}');
    }
  }

  void _printJson(List<WorkflowDefinition> definitions, WorkflowRegistry registry) {
    final list = definitions.map((d) {
      final source = registry.sourceOf(d.name);
      return {
        'name': d.name,
        'description': d.description,
        'stepCount': d.steps.length,
        'source': source?.name,
        'variables': {
          for (final entry in d.variables.entries)
            entry.key: {
              'required': entry.value.required,
              if (entry.value.description.isNotEmpty) 'description': entry.value.description,
              if (entry.value.defaultValue != null) 'default': entry.value.defaultValue,
            },
        },
      };
    }).toList();
    _writeLine(const JsonEncoder.withIndent('  ').convert(list));
  }

  void _printTable(List<WorkflowDefinition> definitions, WorkflowRegistry registry) {
    if (definitions.isEmpty) {
      _writeLine('No workflows available.');
      _printExclusions(registry);
      return;
    }

    _writeLine('Available workflows:');
    _writeLine('');

    // Calculate column widths
    const minNameWidth = 24;
    const minDescWidth = 40;
    const minVarsWidth = 9; // 'VARIABLES'.length
    final nameWidth = definitions.fold(minNameWidth, (w, d) => d.name.length > w ? d.name.length : w);
    final varsWidth = definitions.fold(
      minVarsWidth,
      (w, d) => _requiredVariablesLabel(d).length > w ? _requiredVariablesLabel(d).length : w,
    );

    _writeLine(
      '  ${'NAME'.padRight(nameWidth)}  ${'STEPS'.padRight(5)}  ${'SOURCE'.padRight(11)}  '
      '${'VARIABLES'.padRight(varsWidth)}  DESCRIPTION',
    );

    final materializedCount = registry.listMaterialized().length;
    final customCount = registry.listCustom().length;
    for (final d in definitions) {
      final source = registry.sourceOf(d.name);
      final sourceLabel = (source?.name ?? 'unknown').padRight(11);
      final varsLabel = _requiredVariablesLabel(d).padRight(varsWidth);
      final desc = d.description.length > minDescWidth
          ? '${d.description.substring(0, minDescWidth - 3)}...'
          : d.description;
      _writeLine(
        '  ${d.name.padRight(nameWidth)}  ${d.steps.length.toString().padRight(5)}  $sourceLabel  $varsLabel  $desc',
      );
    }

    _writeLine('');
    final parts = <String>['${definitions.length} workflow${definitions.length == 1 ? '' : 's'}'];
    if (materializedCount > 0 || customCount > 0) {
      final breakdown = <String>[];
      if (materializedCount > 0) breakdown.add('$materializedCount materialized');
      if (customCount > 0) breakdown.add('$customCount custom');
      parts.add('(${breakdown.join(', ')})');
    }
    _writeLine('Total: ${parts.join(' ')}');
    _printExclusions(registry);
  }
}

/// Comma-joined required-variable names for a definition, or `—` when none are
/// required. Names only — types/defaults stay in `--json`.
String _requiredVariablesLabel(WorkflowDefinition definition) {
  final required = definition.variables.entries.where((e) => e.value.required).map((e) => e.key).toList();
  return required.isEmpty ? '—' : required.join(', ');
}

/// Builds a [WorkflowRegistry] synchronously for the `list` command.
///
/// Custom workflows from the workspace and per-project directories cannot be
/// loaded synchronously, so this helper is kept separate and used from within
/// an async context by [WorkflowListCommand.run]. The async loading is
/// extracted here for reuse.
Future<WorkflowRegistry> buildWorkflowRegistry(DartclawConfig config, {AssetResolver? assetResolver}) async {
  final registry = WorkflowRegistry(parser: WorkflowDefinitionParser(), validator: WorkflowDefinitionValidator());
  await WorkflowMaterializer.materialize(dataDir: config.server.dataDir, assetResolver: assetResolver);
  await registry.loadFromDirectory(
    WorkflowMaterializer.builtInDir(config.server.dataDir),
    source: WorkflowSource.materialized,
  );
  await registry.loadFromDirectory(WorkflowMaterializer.customDir(config.server.dataDir));
  await registry.loadFromDeprecatedLegacyDirectory(
    p.join(config.server.dataDir, 'workflows'),
    replacementDirectory: WorkflowMaterializer.customDir(config.server.dataDir),
  );
  for (final projectDef in config.projects.definitions.values) {
    await registry.loadFromDirectory(p.join(configuredProjectDirectory(config, projectDef), 'workflows'));
  }
  return registry;
}
