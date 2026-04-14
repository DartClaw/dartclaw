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
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List available workflows';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final registry = await buildWorkflowRegistry(config, assetResolver: _assetResolver);

    final definitions = registry.listAll();
    if (argResults!['json'] as bool) {
      _printJson(definitions, registry);
    } else {
      _printTable(definitions, registry);
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
      return;
    }

    _writeLine('Available workflows:');
    _writeLine('');

    // Calculate column widths
    const minNameWidth = 24;
    const minDescWidth = 40;
    final nameWidth = definitions.fold(minNameWidth, (w, d) => d.name.length > w ? d.name.length : w);

    _writeLine('  ${'NAME'.padRight(nameWidth)}  ${'STEPS'.padRight(5)}  ${'SOURCE'.padRight(11)}  DESCRIPTION');

    final materializedCount = registry.listMaterialized().length;
    final customCount = registry.listCustom().length;
    for (final d in definitions) {
      final source = registry.sourceOf(d.name);
      final sourceLabel = (source?.name ?? 'unknown').padRight(11);
      final desc = d.description.length > minDescWidth
          ? '${d.description.substring(0, minDescWidth - 3)}...'
          : d.description;
      _writeLine('  ${d.name.padRight(nameWidth)}  ${d.steps.length.toString().padRight(5)}  $sourceLabel  $desc');
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
  }
}

/// Builds a [WorkflowRegistry] synchronously for the `list` command.
///
/// Custom workflows from the workspace and per-project directories cannot be
/// loaded synchronously, so this helper is kept separate and used from within
/// an async context by [WorkflowListCommand.run]. The async loading is
/// extracted here for reuse.
Future<WorkflowRegistry> buildWorkflowRegistry(
  DartclawConfig config, {
  AssetResolver? assetResolver,
}) async {
  final registry = WorkflowRegistry(parser: WorkflowDefinitionParser(), validator: WorkflowDefinitionValidator());
  await WorkflowMaterializer.materialize(workspaceDir: config.workspaceDir, assetResolver: assetResolver);
  await registry.loadFromDirectory(p.join(config.workspaceDir, 'workflows'), source: WorkflowSource.materialized);
  for (final projectDef in config.projects.definitions.values) {
    final projectCloneDir = p.join(config.projectsClonesDir, projectDef.id);
    await registry.loadFromDirectory(p.join(projectCloneDir, 'workflows'));
  }
  return registry;
}
