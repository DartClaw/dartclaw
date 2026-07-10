import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionParser, WorkflowDefinitionResolver;
import 'package:path/path.dart' as p;

import '../config_loader.dart';
import '../connected_command_support.dart';
import 'workflow_list_command.dart' show buildWorkflowRegistry;
import '../workflow_materializer.dart' show WorkflowMaterializer;

/// Prints a workflow definition. Raw by default; `--resolved` merges
/// `stepDefaults` and workflow-level variables; `--step <id>` narrows the resolved output to a
/// single step.
///
/// Connected mode calls `GET /api/workflows/definitions/<name>[?resolve=true[&step=<id>]]`.
/// Standalone mode loads the definition from the workspace registry and runs
/// [WorkflowDefinitionResolver] locally.
class WorkflowShowCommand extends ConnectedCommand {
  final AssetResolver _assetResolver;
  final Map<String, String>? _environment;
  final String? _projectFallbackCwd;
  final void Function(String) _write;

  WorkflowShowCommand({
    super.config,
    AssetResolver? assetResolver,
    super.apiClient,
    Map<String, String>? environment,
    String? projectFallbackCwd,
    void Function(String)? write,
    super.writeLine,
    super.exitFn,
  }) : _assetResolver = assetResolver ?? AssetResolver(),
       _environment = environment,
       _projectFallbackCwd = projectFallbackCwd,
       _write = write ?? stdout.write {
    argParser
      ..addFlag(
        'resolved',
        negatable: false,
        help: 'Print the fully merged form (stepDefaults applied, workflow variables substituted)',
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

    await runConnected((apiClient) async {
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
    });
  }

  Future<void> _runStandalone(
    String name, {
    required bool resolved,
    required String? stepId,
    required bool asJson,
  }) async {
    final configPath = resolveStandaloneWorkflowConfigPath(
      configPath: globalOptionString(globalResults, 'config'),
      env: _environment,
      currentDirectory: _projectFallbackCwd,
    );
    final config = injectedConfig ?? loadCliConfig(configPath: configPath, env: _environment);
    final registry = await buildWorkflowRegistry(config, assetResolver: _assetResolver);
    var definition = registry.getByName(name);
    var authoredYaml = registry.authoredYaml(name);

    if (definition == null || authoredYaml == null) {
      final sourceDir = WorkflowMaterializer.resolveBuiltInWorkflowSourceDir();
      if (sourceDir != null) {
        final file = File(p.join(sourceDir, '$name.yaml'));
        if (file.existsSync()) {
          authoredYaml = file.readAsStringSync();
          definition ??= WorkflowDefinitionParser().parse(authoredYaml, sourcePath: file.path);
        }
      }
    }

    if (definition == null) {
      writeLine('Workflow not found: $name');
      exitFn(1);
    }

    if (!resolved) {
      _emit(authoredYaml ?? WorkflowDefinitionResolver().emitYaml(definition), asJson: asJson);
      return;
    }

    final resolver = WorkflowDefinitionResolver();
    final resolvedDef = resolver.resolve(definition);
    if (stepId != null && stepId.isNotEmpty) {
      final slice = resolver.sliceStep(resolvedDef, stepId);
      if (slice == null) {
        writeLine('Step "$stepId" not found in workflow "$name"');
        exitFn(1);
      }
      _emit(resolver.emitYaml(slice), asJson: asJson);
      return;
    }
    _emit(resolver.emitYaml(resolvedDef), asJson: asJson);
  }

  void _emit(String body, {required bool asJson}) {
    if (asJson) {
      writeLine('{"yaml":${jsonEncode(body)}}');
    } else {
      _write(body);
      if (!body.endsWith('\n')) _write('\n');
    }
  }
}
