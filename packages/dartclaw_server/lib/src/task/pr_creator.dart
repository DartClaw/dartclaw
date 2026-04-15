import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:logging/logging.dart';

import '../project/project_auth_support.dart';

const _gitHubApiVersion = '2026-03-10';

/// Result of a PR creation attempt.
sealed class PrCreationResult {
  const PrCreationResult();
}

/// PR was created successfully.
final class PrCreated extends PrCreationResult {
  /// The URL of the newly created PR.
  final String url;

  const PrCreated(this.url);
}

/// Manual follow-up is required after the push completed.
final class PrGhNotFound extends PrCreationResult {
  /// Human-readable instructions for creating the PR manually.
  final String instructions;

  const PrGhNotFound(this.instructions);
}

/// GitHub PR creation failed.
final class PrCreationFailed extends PrCreationResult {
  final String error;
  final String details;

  const PrCreationFailed({required this.error, required this.details});
}

typedef GitHubApiRunner =
    Future<({int statusCode, String body})> Function(
      String method,
      Uri uri, {
      required Map<String, String> headers,
      String? body,
    });

/// Creates GitHub pull requests via the GitHub REST API.
class PrCreator {
  static final _log = Logger('PrCreator');

  final CredentialsConfig _credentials;
  final HttpClient Function() _httpClientFactory;

  /// Injectable request runner for testing.
  final GitHubApiRunner? _apiRunner;

  PrCreator({
    CredentialsConfig credentials = const CredentialsConfig.defaults(),
    HttpClient Function()? httpClientFactory,
    GitHubApiRunner? apiRunner,
  }) : _credentials = credentials,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _apiRunner = apiRunner;

  /// Creates a GitHub PR for the given [branch].
  Future<PrCreationResult> create({required Project project, required Task task, required String branch}) async {
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
        Uri.parse('https://api.github.com/repos/${repo.owner}/${repo.name}/pulls'),
        headers: headers,
        body: jsonEncode({
          'title': task.title,
          'body': _buildPrBody(task),
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
          Uri.parse('https://api.github.com/repos/${repo.owner}/${repo.name}/issues/$issueNumber/labels'),
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

  String _buildPrBody(Task task) {
    final parts = <String>[task.description];
    if (task.acceptanceCriteria != null) {
      parts.add('\n### Acceptance Criteria\n${task.acceptanceCriteria}');
    }
    parts.add('\n---\n_Created by DartClaw task ${task.id}_');
    return parts.join('\n');
  }

  Future<({int statusCode, String body})> _request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final runner = _apiRunner;
    if (runner != null) {
      return runner(method, uri, headers: headers, body: body);
    }

    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, uri);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.encoding = utf8;
        request.write(body);
      }
      final response = await request.close().timeout(const Duration(seconds: 15));
      final responseBody = await utf8.decoder.bind(response).join();
      return (statusCode: response.statusCode, body: responseBody);
    } finally {
      client.close(force: true);
    }
  }

  String? _extractGitHubMessage(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
    return null;
  }
}
