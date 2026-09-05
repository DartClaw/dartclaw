import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:logging/logging.dart';

import '../project/project_auth_support.dart';

const _gitHubApiVersion = '2026-03-10';

/// Result of a PR creation attempt.
sealed class PrCreationResult {
  const new();
}

/// PR was created successfully.
final class PrCreated extends PrCreationResult {
  /// The URL of the newly created PR.
  final String url;

  const new(this.url);
}

/// Manual follow-up is required after the push completed.
final class PrGhNotFound extends PrCreationResult {
  /// Human-readable instructions for creating the PR manually.
  final String instructions;

  const new(this.instructions);
}

/// GitHub PR creation failed.
final class PrCreationFailed extends PrCreationResult {
  final String error;
  final String details;

  const new({required this.error, required this.details});
}

/// Issues an authenticated GitHub REST API call and returns the raw response.
typedef GitHubApiRunner = Future<({int statusCode, String body})> Function(
  String method,
  Uri uri, {
  required Map<String, String> headers,
  String? body,
});

/// Creates GitHub pull requests via the GitHub REST API.
class PrCreator {
  static final _log = Logger('PrCreator');

  final CredentialsConfig _credentials;
  final HttpClientFactory _httpClientFactory;
  final Uri _apiBaseUri;

  /// Injectable request runner for testing.
  final GitHubApiRunner? _apiRunner;

  new({
    CredentialsConfig credentials = const CredentialsConfig.defaults(),
    HttpClientFactory? httpClientFactory,
    GitHubApiRunner? apiRunner,

    /// GitHub REST API origin, defaulting to `https://api.github.com`.
    Uri? apiBaseUri,
  }) : _credentials = credentials,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _apiRunner = apiRunner,
       _apiBaseUri = apiBaseUri ?? Uri.parse('https://api.github.com');

  /// Creates a GitHub PR for the given [branch].
  ///
  /// [notes] is an optional operator-facing addendum (e.g. unresolved workflow
  /// items) appended to the PR body under its own heading.
  Future<PrCreationResult> create({
    required Project project,
    required Task task,
    required String branch,
    String? notes,
  }) async {
    final auth = describeProjectAuth(project, _credentials);
    if (auth == null || !auth.compatible) {
      return PrCreationFailed(
        error: 'Project credential is not compatible with GitHub PR delivery',
        details: auth?.errorMessage ?? 'The project is missing a usable GitHub token credential.',
      );
    }
    final repo = GitHubRepositoryRef.tryParse(project.remoteUrl);
    final credentialsRef = project.credentialsRef;
    if (repo == null || credentialsRef == null) {
      return const PrCreationFailed(
        error: 'Project is not configured for GitHub PR delivery',
        details: 'GitHub pull requests require a github.com remote and a credentialsRef.',
      );
    }
    final entry = _credentials[credentialsRef];
    if (entry == null || !entry.isGitHubToken || !entry.isPresent) {
      return PrCreationFailed(
        error: 'GitHub token credential is unavailable',
        details: 'Credential "$credentialsRef" is missing, empty, or not a github-token entry.',
      );
    }

    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'application/vnd.github+json',
      HttpHeaders.authorizationHeader: 'Bearer ${entry.token}',
      'X-GitHub-Api-Version': _gitHubApiVersion,
      HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
      HttpHeaders.userAgentHeader: 'dartclaw',
    };

    try {
      final prResponse = await _request(
        'POST',
        _apiBaseUri.resolve('/repos/${repo.owner}/${repo.name}/pulls'),
        headers: headers,
        body: jsonEncode({
          'title': task.title,
          'body': _buildPrBody(task, notes: notes),
          'head': branch,
          'base': project.defaultBranch,
          if (project.pr.draft) 'draft': true,
        }),
      );
      if (prResponse.statusCode != 201) {
        final message = _extractGitHubMessage(prResponse.body) ?? 'GitHub returned HTTP ${prResponse.statusCode}';
        _log.warning('GitHub PR creation failed (${prResponse.statusCode}): $message');
        return PrCreationFailed(error: 'GitHub PR creation failed (HTTP ${prResponse.statusCode})', details: message);
      }

      final payload = jsonDecode(prResponse.body) as Map<String, dynamic>;
      final url = payload['html_url'] as String? ?? '';
      final issueNumber = payload['number'];
      if (url.trim().isEmpty || issueNumber is! int) {
        return const PrCreationFailed(
          error: 'GitHub PR response was incomplete',
          details: 'Expected html_url and number in the pull request response.',
        );
      }

      if (project.pr.labels.isNotEmpty) {
        final labelResponse = await _request(
          'POST',
          _apiBaseUri.resolve('/repos/${repo.owner}/${repo.name}/issues/$issueNumber/labels'),
          headers: headers,
          body: jsonEncode({'labels': project.pr.labels}),
        );
        if (labelResponse.statusCode != 200) {
          final message =
              _extractGitHubMessage(labelResponse.body) ?? 'GitHub returned HTTP ${labelResponse.statusCode}';
          _log.warning('GitHub label application failed (${labelResponse.statusCode}): $message');
          return PrCreationFailed(
            error: 'GitHub PR labels failed (HTTP ${labelResponse.statusCode})',
            details: 'Created PR $url, but applying labels failed: $message',
          );
        }
      }

      _log.info('PR created for branch $branch: $url');
      return PrCreated(url);
    } catch (e) {
      _log.warning('GitHub PR creation threw: $e');
      return PrCreationFailed(error: 'Failed to call GitHub API', details: e.toString());
    }
  }

  String _buildPrBody(Task task, {String? notes}) {
    final parts = <String>[task.description];
    if (task.acceptanceCriteria != null) {
      parts.add('\n### Acceptance Criteria\n${task.acceptanceCriteria}');
    }
    if (notes != null && notes.trim().isNotEmpty) {
      // Fenced code block: notes carry agent-influenced item ids, and GitHub
      // interprets @mentions, closes-#N keywords, and links anywhere in a PR
      // body – a code block neutralizes all three while staying readable.
      parts.add('\n### Unresolved items\n```\n${notes.trim()}\n```');
    }
    parts.add('\n---\n_Created by DartClaw task ${task.id}_');
    return parts.join('\n');
  }

  Future<({int statusCode, String body})> _request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) {
    final runner = _apiRunner;
    if (runner != null) {
      return runner(method, uri, headers: headers, body: body);
    }

    return httpRequest(
      uri,
      method: method,
      headers: headers,
      body: body,
      connectionTimeout: const Duration(seconds: 10),
      timeout: const Duration(seconds: 15),
      factory: _httpClientFactory,
    );
  }

  String? _extractGitHubMessage(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final message = decoded['message'];
    if (message is! String || message.trim().isEmpty) {
      return null;
    }
    // A 422 says only "Validation Failed" at the top level; the reason
    // ("No commits between main and …") is in `errors[].message`.
    final errors = decoded['errors'];
    final reasons = errors is List
        ? errors
              .whereType<Map<String, dynamic>>()
              .map((e) => e['message'])
              .whereType<String>()
              .where((m) => m.trim().isNotEmpty)
              .toList()
        : const <String>[];
    return reasons.isEmpty ? message.trim() : '${message.trim()}: ${reasons.join('; ')}';
  }
}
