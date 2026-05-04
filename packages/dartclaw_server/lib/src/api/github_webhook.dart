import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_utils.dart';
import 'api_helpers.dart';
import 'github_webhook_config.dart';

final _log = Logger('GitHubWebhookHandler');

class GitHubWebhookHandler {
  final GitHubWebhookConfig config;
  final WorkflowService workflows;
  final WorkflowDefinitionSource definitions;
  final ProjectService? projects;
  final EventBus? eventBus;
  final List<String> trustedProxies;

  GitHubWebhookHandler({
    required this.config,
    required this.workflows,
    required this.definitions,
    this.projects,
    this.eventBus,
    this.trustedProxies = const [],
  });

  Future<Response> handle(Request request) async {
    final body = await readBounded(request, maxWebhookPayloadBytes);
    if (body == null) {
      _log.warning('GitHub webhook payload exceeds size limit');
      return Response(413);
    }

    if (!_validSignature(request.headers['x-hub-signature-256'], body)) {
      fireFailedAuthEvent(
        eventBus,
        request,
        source: 'webhook',
        reason: 'invalid_github_signature',
        trustedProxies: trustedProxies,
      );
      return Response.forbidden('');
    }

    final payload = jsonDecode(body) as Map<String, dynamic>;
    final eventName = request.headers['x-github-event'] ?? '';
    if (eventName != 'pull_request') {
      return jsonResponse(200, {'ignored': true});
    }

    final action = payload['action']?.toString() ?? '';
    final pullRequest = payload['pull_request'] as Map<String, dynamic>?;
    final repository = payload['repository'] as Map<String, dynamic>?;
    if (pullRequest == null || repository == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Missing pull_request payload');
    }

    final labelNames = ((pullRequest['labels'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((label) => label['name']?.toString())
        .whereType<String>()
        .toSet();

    GitHubWorkflowTrigger? trigger;
    for (final candidate in config.triggers) {
      final matches =
          candidate.event == eventName &&
          (candidate.actions.isEmpty || candidate.actions.contains(action)) &&
          (candidate.labels.isEmpty || candidate.labels.every(labelNames.contains));
      if (matches) {
        trigger = candidate;
        break;
      }
    }
    if (trigger == null) {
      return jsonResponse(200, {'ignored': true});
    }

    final definition = definitions.getByName(trigger.workflow);
    if (definition == null) {
      return errorResponse(404, 'DEFINITION_NOT_FOUND', 'Workflow definition not found: ${trigger.workflow}');
    }

    final prNumber = pullRequest['number']?.toString() ?? '';
    final repoSlug = repository['full_name']?.toString() ?? '';
    final requiresProject = definition.variables.containsKey('PROJECT');
    final projectId = requiresProject ? await _resolveProjectId(repoSlug) : null;
    if (requiresProject && projectId == null) {
      return errorResponse(
        400,
        'PROJECT_RESOLUTION_FAILED',
        'No unique configured project matched repository slug: $repoSlug',
      );
    }

    if (await _isDuplicate(trigger.workflow, prNumber, projectId: projectId, repoSlug: repoSlug)) {
      return jsonResponse(200, {'ok': true, 'deduped': true});
    }

    final head = pullRequest['head'] as Map<String, dynamic>?;
    final base = pullRequest['base'] as Map<String, dynamic>?;
    final variables = <String, String>{
      'TARGET': pullRequest['title']?.toString() ?? '',
      'PR_NUMBER': prNumber,
      'BRANCH': head?['ref']?.toString() ?? '',
      'BASE_BRANCH': base?['ref']?.toString() ?? '',
      if (!requiresProject) 'REPO': repoSlug,
    };
    if (projectId != null) {
      variables['PROJECT'] = projectId;
    }

    final run = await workflows.start(definition, variables, projectId: projectId);
    return jsonResponse(200, {'ok': true, 'runId': run.id});
  }

  bool _validSignature(String? signatureHeader, String body) {
    final secret = config.webhookSecret;
    if (secret == null || secret.isEmpty) {
      return false;
    }
    if (signatureHeader == null || !signatureHeader.startsWith('sha256=')) {
      return false;
    }
    final digest = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body)).toString();
    return constantTimeEquals(signatureHeader, 'sha256=$digest');
  }

  Future<bool> _isDuplicate(String workflowName, String prNumber, {String? projectId, required String repoSlug}) async {
    final runs = await workflows.list(definitionName: workflowName);
    return runs.any((run) {
      if (run.status.terminal || run.variablesJson['PR_NUMBER'] != prNumber) return false;
      if (projectId != null) {
        return run.variablesJson['PROJECT'] == projectId;
      }
      return run.variablesJson['REPO'] == repoSlug;
    });
  }

  Future<String?> _resolveProjectId(String repoSlug) async {
    if (repoSlug.trim().isEmpty) return null;

    final projectService = projects;
    if (projectService == null) {
      return null;
    }

    final target = repoSlug.toLowerCase();
    final allProjects = await projectService.getAll();
    final matches = allProjects
        .where((project) => _repoSlugFromRemote(project.remoteUrl) == target)
        .map((project) => project.id)
        .toList(growable: false);
    if (matches.length != 1) {
      return null;
    }
    return matches.single;
  }

  String? _repoSlugFromRemote(String remoteUrl) {
    final trimmed = remoteUrl.trim();
    if (trimmed.isEmpty) return null;

    final ssh = RegExp(r'^[^@]+@[^:]+:([^/]+)/(.+?)(?:\.git)?$').firstMatch(trimmed);
    if (ssh != null) {
      return '${ssh.group(1)}/${ssh.group(2)}'.toLowerCase();
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1].replaceFirst(RegExp(r'\.git$'), '');
    return '$owner/$repo'.toLowerCase();
  }
}
