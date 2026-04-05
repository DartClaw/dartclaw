import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show DartclawConfig, WorkflowDefinition, WorkflowDefinitionParser, WorkflowDefinitionValidator;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowRegistry, WorkflowSource;
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import '../serve_command.dart' show WriteLine;

/// Lists available workflows (built-in + custom).
///
/// Default output is tabular with columns NAME, STEPS, SOURCE, DESCRIPTION.
/// Use `--json` for machine-readable JSON array output.
class WorkflowListCommand extends Command<void> {
  final DartclawConfig? _config;
  final WriteLine _writeLine;

  WorkflowListCommand({DartclawConfig? config, WriteLine? writeLine})
    : _config = config,
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
    final registry = await buildWorkflowRegistry(config);

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
        'source': source == WorkflowSource.builtIn ? 'built-in' : 'custom',
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

    final builtInCount = registry.listBuiltIn().length;
    final customCount = registry.listCustom().length;

    _writeLine('Available workflows:');
    _writeLine('');

    // Calculate column widths
    const minNameWidth = 24;
    const minDescWidth = 40;
    final nameWidth = definitions.fold(minNameWidth, (w, d) => d.name.length > w ? d.name.length : w);

    _writeLine(
      '  ${'NAME'.padRight(nameWidth)}  ${'STEPS'.padRight(5)}  ${'SOURCE'.padRight(8)}  DESCRIPTION',
    );

    for (final d in definitions) {
      final source = registry.sourceOf(d.name);
      final sourceLabel = source == WorkflowSource.builtIn ? 'built-in' : 'custom  ';
      final desc = d.description.length > minDescWidth
          ? '${d.description.substring(0, minDescWidth - 3)}...'
          : d.description;
      _writeLine(
        '  ${d.name.padRight(nameWidth)}  ${d.steps.length.toString().padRight(5)}  $sourceLabel  $desc',
      );
    }

    _writeLine('');
    final parts = <String>['${definitions.length} workflow${definitions.length == 1 ? '' : 's'}'];
    if (builtInCount > 0 || customCount > 0) {
      final breakdown = <String>[];
      if (builtInCount > 0) breakdown.add('$builtInCount built-in');
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
Future<WorkflowRegistry> buildWorkflowRegistry(DartclawConfig config) async {
  final registry = WorkflowRegistry(
    parser: WorkflowDefinitionParser(),
    validator: WorkflowDefinitionValidator(),
  );
  registry.loadBuiltIn();
  await registry.loadFromDirectory(p.join(config.workspaceDir, 'workflows'));
  for (final projectDef in config.projects.definitions.values) {
    final projectCloneDir = p.join(config.projectsClonesDir, projectDef.id);
    await registry.loadFromDirectory(p.join(projectCloneDir, 'workflows'));
  }
  return registry;
}
