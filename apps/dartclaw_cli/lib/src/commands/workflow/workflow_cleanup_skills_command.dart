import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkspaceSkillLinker;
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import '../serve_command.dart' show WriteLine;
import 'project_definition_paths.dart';

typedef WorkflowCleanupExitFn = void Function(int code);

class WorkflowCleanupSkillsCommand extends Command<void> {
  final DartclawConfig? _config;
  final WorkspaceSkillLinker _linker;
  final WriteLine _writeLine;
  final WorkflowCleanupExitFn _exitFn;
  final String _currentDirectory;

  WorkflowCleanupSkillsCommand({
    DartclawConfig? config,
    WorkspaceSkillLinker? linker,
    WriteLine? writeLine,
    WorkflowCleanupExitFn? exitFn,
    String? currentDirectory,
  }) : _config = config,
       _linker = linker ?? WorkspaceSkillLinker(),
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit,
       _currentDirectory = currentDirectory ?? Directory.current.path {
    argParser
      ..addMultiOption(
        'workspace',
        valueHelp: 'path',
        help: 'Additional workspace or worktree path to clean. May be repeated.',
      )
      ..addFlag('include-cwd', negatable: false, help: 'Also clean the current working directory.');
  }

  @override
  String get name => 'cleanup-skills';

  @override
  String get description => 'Remove DartClaw-managed workflow skill links from project workspaces';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    for (final warning in config.warnings) {
      _writeLine('WARNING: $warning');
    }

    final targets = _cleanupTargets(config);
    if (targets.isEmpty) {
      _writeLine('No workflow skill workspaces configured.');
      _exitFn(0);
      return;
    }

    var cleaned = 0;
    var skipped = 0;
    for (final target in targets) {
      if (!Directory(target).existsSync()) {
        skipped++;
        _writeLine('Skipped missing workspace: $target');
        continue;
      }
      _linker.clean(workspaceDir: target);
      cleaned++;
      _writeLine('Cleaned workflow skill links: $target');
    }

    _writeLine('Workflow skill cleanup complete: $cleaned cleaned, $skipped skipped.');
    _exitFn(0);
  }

  List<String> _cleanupTargets(DartclawConfig config) {
    final targets = <String>{};
    for (final path in configuredProjectDirectories(config)) {
      targets.add(_normalizePath(path));
    }
    for (final path in argResults!['workspace'] as List<String>) {
      final trimmed = path.trim();
      if (trimmed.isNotEmpty) targets.add(_normalizePath(trimmed));
    }
    if (argResults!['include-cwd'] as bool || (targets.isEmpty && config.projects.definitions.isEmpty)) {
      targets.add(_normalizePath(_currentDirectory));
    }
    return targets.toList()..sort();
  }
}

String _normalizePath(String path) => p.normalize(p.absolute(path));
