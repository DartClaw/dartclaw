import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show SkillRegistryImpl, WorkflowDefinitionParser, WorkflowDefinitionResolver;
import 'package:path/path.dart' as p;

import '../workflow_skill_source_resolver.dart';

import '../../dartclaw_api_client.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;
import 'workflow_list_command.dart' show buildWorkflowRegistry;
import '../workflow_materializer.dart' show WorkflowMaterializer;
import 'andthen_skill_bootstrap.dart';

/// Prints a workflow definition. Raw by default; `--resolved` merges
/// `stepDefaults`, skill defaults (`default_prompt`, `default_outputs`), and
/// workflow-level variables; `--step <id>` narrows the resolved output to a
/// single step.
///
/// Connected mode calls `GET /api/workflows/definitions/<name>[?resolve=true[&step=<id>]]`.
/// Standalone mode loads the definition from the workspace registry and runs
/// [WorkflowDefinitionResolver] locally.
class WorkflowShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final AssetResolver _assetResolver;
  final DartclawApiClient? _apiClient;
  final Map<String, String>? _environment;
  final String? _projectFallbackCwd;
  final void Function(String) _write;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowShowCommand({
    DartclawConfig? config,
    AssetResolver? assetResolver,
    DartclawApiClient? apiClient,
    Map<String, String>? environment,
    String? projectFallbackCwd,
    void Function(String)? write,
    WriteLine? writeLine,
    ExitFn? exitFn,
  }) : _config = config,
       _assetResolver = assetResolver ?? AssetResolver(),
       _apiClient = apiClient,
       _environment = environment,
       _projectFallbackCwd = projectFallbackCwd,
       _write = write ?? stdout.write,
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit {
    argParser
      ..addFlag(
        'resolved',
        negatable: false,
        help: 'Print the fully merged form (stepDefaults applied, skill defaults injected)',
      )
      ..addOption('step', help: 'When combined with --resolved, emit a single resolved step')
      ..addFlag('json', negatable: false, help: 'Emit a JSON envelope {"yaml": "..."} for scripting')
      ..addFlag(
        'standalone',
        negatable: false,
        help: 'Load the workflow from the local registry (bypasses the server)',
      );
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Print a workflow definition (raw or fully resolved)';

  @override
  String get invocation => '${runner!.executableName} workflow show <name>';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Workflow name required', usage);
    }
    final workflowName = args.first;
    final resolved = argResults!['resolved'] as bool;
    final stepId = argResults!['step'] as String?;
    final asJson = argResults!['json'] as bool;
    final standalone = argResults!['standalone'] as bool;

    if (standalone) {
      await _runStandalone(workflowName, resolved: resolved, stepId: stepId, asJson: asJson);
      return;
    }

    final apiClient = _resolveApiClient();
    try {
      if (!resolved) {
        final body = await apiClient.getText('/api/workflows/definitions/$workflowName');
        _emit(body, asJson: asJson);
        return;
      }

      final queryParameters = <String, Object?>{
        'resolve': 'true',
        if (stepId != null && stepId.isNotEmpty) 'step': stepId,
      };
      // ignore: use_null_aware_elements — conditional only applies when stepId is a non-empty string.
      final body = await apiClient.getText(
        '/api/workflows/definitions/$workflowName',
        queryParameters: queryParameters,
      );
      _emit(body, asJson: asJson);
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  Future<void> _runStandalone(
    String name, {
    required bool resolved,
    required String? stepId,
    required bool asJson,
  }) async {
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    final registry = await buildWorkflowRegistry(config, assetResolver: _assetResolver);
    var definition = registry.getByName(name);
    var authoredYaml = registry.authoredYaml(name);

    if (definition == null || authoredYaml == null) {
      final sourceDir = WorkflowMaterializer.resolveBuiltInWorkflowSourceDir(assetResolver: _assetResolver);
      if (sourceDir != null) {
        final file = File(p.join(sourceDir, '$name.yaml'));
        if (file.existsSync()) {
          authoredYaml = file.readAsStringSync();
          definition ??= WorkflowDefinitionParser().parse(authoredYaml, sourcePath: file.path);
        }
      }
    }

    if (definition == null) {
      _writeLine('Workflow not found: $name');
      _exitFn(1);
    }

    if (!resolved) {
      _emit(authoredYaml ?? WorkflowDefinitionResolver().emitYaml(definition), asJson: asJson);
      return;
    }

    // Build a transient SkillRegistry so the standalone path can fill in
    // skill-declared default_prompt / default_outputs just like the server.
    final resolvedAssets = _assetResolver.resolve();
    final builtInSkillsDir = resolvedAssets?.skillsDir ?? WorkflowSkillSourceResolver.resolveBuiltInSkillsSourceDir();
    final userSkillRoots = workflowUserSkillRoots(_environment);
    final skills = SkillRegistryImpl()
      ..discover(
        projectDirs: workflowSkillProjectDirs(config, fallbackCwd: _projectFallbackCwd ?? Directory.current.path),
        workspaceDir: config.workspaceDir,
        dataDir: config.server.dataDir,
        builtInSkillsDir: builtInSkillsDir,
        userClaudeSkillsDir: userSkillRoots.claudeSkillsDir,
        userAgentsSkillsDir: userSkillRoots.agentsSkillsDir,
      );
    final resolver = WorkflowDefinitionResolver(skillRegistry: skills);
    final resolvedDef = resolver.resolve(definition);
    if (stepId != null && stepId.isNotEmpty) {
      final slice = resolver.sliceStep(resolvedDef, stepId);
      if (slice == null) {
        _writeLine('Step "$stepId" not found in workflow "$name"');
        _exitFn(1);
      }
      _emit(resolver.emitYaml(slice), asJson: asJson);
      return;
    }
    _emit(resolver.emitYaml(resolvedDef), asJson: asJson);
  }

  void _emit(String body, {required bool asJson}) {
    if (asJson) {
      _writeLine('{"yaml":${jsonEncode(body)}}');
    } else {
      _write(body);
      if (!body.endsWith('\n')) _write('\n');
    }
  }

  DartclawApiClient _resolveApiClient() {
    if (_apiClient != null) return _apiClient;
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    return DartclawApiClient.fromConfig(
      config: config,
      serverOverride: _globalOptionString(globalResults, 'server'),
      tokenOverride: _globalOptionString(globalResults, 'token'),
    );
  }
}

String? _globalOptionString(ArgResults? results, String name) {
  if (results == null) return null;
  try {
    return results[name] as String?;
  } on ArgumentError {
    return null;
  }
}
