import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';

const _gitHubApiVersion = '2026-03-10';

typedef GitHubProbeRunner =
    Future<({int statusCode, String body})> Function(Uri uri, {required Map<String, String> headers});

/// Parsed GitHub repository identity.
final class GitHubRepositoryRef {
  final String owner;
  final String name;

  const GitHubRepositoryRef({required this.owner, required this.name});

  String get slug => '$owner/$name';

  String get canonicalHttpsUrl => 'https://github.com/$owner/$name.git';

  static GitHubRepositoryRef? tryParse(String remoteUrl) {
    final trimmed = remoteUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final sshMatch = RegExp(
      r'^(?:git@github\.com:|ssh://git@github\.com/)([^/]+)/(.+?)(?:\.git)?$',
    ).firstMatch(trimmed);
    if (sshMatch != null) {
      return GitHubRepositoryRef(owner: sshMatch.group(1)!, name: sshMatch.group(2)!);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.toLowerCase() != 'github.com') {
      return null;
    }

    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList(growable: false);
    if (segments.length < 2) {
      return null;
    }

    final owner = segments[0];
    final rawName = segments[1];
    final name = rawName.endsWith('.git') ? rawName.substring(0, rawName.length - 4) : rawName;
    if (owner.isEmpty || name.isEmpty) {
      return null;
    }
    return GitHubRepositoryRef(owner: owner, name: name);
  }
}

/// Structured project auth/preflight failure.
final class ProjectAuthException implements Exception {
  final ProjectAuthStatus authStatus;

  const ProjectAuthException(this.authStatus);

  String get code => authStatus.errorCode ?? 'PROJECT_AUTH_ERROR';

  String get message => authStatus.errorMessage ?? 'Project authentication failed';

  Map<String, dynamic> get details => {'auth': authStatus.toJson()};

  @override
  String toString() => 'ProjectAuthException($code): $message';
}

/// Builds local compatibility metadata for [project] without making network calls.
ProjectAuthStatus? describeProjectAuth(Project project, CredentialsConfig credentials) {
  if (project.id == '_local' || project.remoteUrl.trim().isEmpty) {
    return null;
  }

  final now = DateTime.now();
  final credentialsRef = project.credentialsRef;
  final entry = credentialsRef == null ? null : credentials[credentialsRef];
  final gitHubRepo = GitHubRepositoryRef.tryParse(project.remoteUrl);

  if (gitHubRepo != null) {
    if (credentialsRef == null || credentialsRef.isEmpty) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        compatible: false,
        checkedAt: now,
        errorCode: 'missing_credentials',
        errorMessage: 'GitHub projects require a GitHub token credential reference.',
      );
    }
    if (entry == null) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        credentialsRef: credentialsRef,
        compatible: false,
        checkedAt: now,
        errorCode: 'credential_not_found',
        errorMessage: 'Credential "$credentialsRef" was not found.',
      );
    }
    if (!entry.isGitHubToken) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        credentialsRef: credentialsRef,
        credentialType: entry.type.name,
        compatible: false,
        checkedAt: now,
        errorCode: 'credential_type_mismatch',
        errorMessage: 'GitHub projects require a typed github-token credential.',
      );
    }
    final repositoryPolicy = entry.repository?.trim().toLowerCase();
    if (repositoryPolicy != null && repositoryPolicy.isNotEmpty && repositoryPolicy != gitHubRepo.slug.toLowerCase()) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        credentialsRef: credentialsRef,
        credentialType: entry.type.name,
        compatible: false,
        checkedAt: now,
        errorCode: 'repository_mismatch',
        errorMessage: 'Credential "$credentialsRef" is scoped to ${entry.repository}, not ${gitHubRepo.slug}.',
      );
    }
    if (!entry.isPresent) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        credentialsRef: credentialsRef,
        credentialType: entry.type.name,
        compatible: false,
        checkedAt: now,
        errorCode: 'missing_secret',
        errorMessage: 'Credential "$credentialsRef" is configured but empty.',
      );
    }

    return ProjectAuthStatus(
      repository: gitHubRepo.slug,
      credentialsRef: credentialsRef,
      credentialType: entry.type.name,
      compatible: true,
      checkedAt: now,
    );
  }

  if (credentialsRef == null || credentialsRef.isEmpty) {
    return null;
  }
  if (entry == null) {
    return ProjectAuthStatus(
      credentialsRef: credentialsRef,
      compatible: false,
      checkedAt: now,
      errorCode: 'credential_not_found',
      errorMessage: 'Credential "$credentialsRef" was not found.',
    );
  }
  if (entry.isGitHubToken) {
    return ProjectAuthStatus(
      credentialsRef: credentialsRef,
      credentialType: entry.type.name,
      compatible: false,
      checkedAt: now,
      errorCode: 'unsupported_remote',
      errorMessage: 'GitHub token credentials only support github.com remotes.',
    );
  }
  return ProjectAuthStatus(
    credentialsRef: credentialsRef,
    credentialType: entry.type.name,
    compatible: entry.isPresent,
    checkedAt: now,
    errorCode: entry.isPresent ? null : 'missing_secret',
    errorMessage: entry.isPresent ? null : 'Credential "$credentialsRef" is configured but empty.',
  );
}

/// Resolves project auth metadata and, for GitHub token credentials, verifies repository access.
Future<ProjectAuthStatus?> probeProjectAuth(
  Project project,
  CredentialsConfig credentials, {
  HttpClient Function()? httpClientFactory,
  GitHubProbeRunner? probeRunner,
}) async {
  final described = describeProjectAuth(project, credentials);
  if (described == null || !described.compatible) {
    return described;
  }

  final repository = described.repository;
  final credentialsRef = project.credentialsRef;
  if (repository == null || credentialsRef == null) {
    return described;
  }

  final entry = credentials[credentialsRef];
  if (entry == null || !entry.isGitHubToken) {
    return described;
  }

  final gitHubRepo = GitHubRepositoryRef.tryParse(project.remoteUrl);
  if (gitHubRepo == null) {
    return described;
  }

  final client = (httpClientFactory ?? HttpClient.new)();
  final headers = <String, String>{
    HttpHeaders.acceptHeader: 'application/vnd.github+json',
    HttpHeaders.authorizationHeader: 'Bearer ${entry.token}',
    'X-GitHub-Api-Version': _gitHubApiVersion,
    HttpHeaders.userAgentHeader: 'dartclaw',
  };
  try {
    final uri = Uri.parse('https://api.github.com/repos/${gitHubRepo.owner}/${gitHubRepo.name}');
    final response = probeRunner != null
        ? await probeRunner(uri, headers: headers)
        : await _runHttpProbe(client, uri, headers: headers);

    if (response.statusCode == 200) {
      return ProjectAuthStatus(
        repository: gitHubRepo.slug,
        credentialsRef: credentialsRef,
        credentialType: entry.type.name,
        compatible: true,
        checkedAt: DateTime.now(),
      );
    }

    final message = _extractGitHubMessage(response.body);
    final errorCode = switch (response.statusCode) {
      401 => 'github_auth_failed',
      403 => 'github_access_denied',
      404 => 'repository_access_denied',
      _ => 'github_probe_failed',
    };
    final errorMessage = switch (response.statusCode) {
      401 ||
      403 ||
      404 => 'GitHub token "$credentialsRef" cannot access ${gitHubRepo.slug}${message == null ? "" : ": $message"}',
      _ =>
        'GitHub repository probe failed for ${gitHubRepo.slug} (HTTP ${response.statusCode})${message == null ? "" : ": $message"}',
    };
    return ProjectAuthStatus(
      repository: gitHubRepo.slug,
      credentialsRef: credentialsRef,
      credentialType: entry.type.name,
      compatible: false,
      checkedAt: DateTime.now(),
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  } on SocketException catch (error) {
    return ProjectAuthStatus(
      repository: gitHubRepo.slug,
      credentialsRef: credentialsRef,
      credentialType: entry.type.name,
      compatible: false,
      checkedAt: DateTime.now(),
      errorCode: 'probe_network_error',
      errorMessage: 'GitHub probe failed for ${gitHubRepo.slug}: ${error.message}',
    );
  } on TimeoutException {
    return ProjectAuthStatus(
      repository: gitHubRepo.slug,
      credentialsRef: credentialsRef,
      credentialType: entry.type.name,
      compatible: false,
      checkedAt: DateTime.now(),
      errorCode: 'probe_timeout',
      errorMessage: 'GitHub probe timed out for ${gitHubRepo.slug}.',
    );
  } finally {
    client.close(force: true);
  }
}

Future<({int statusCode, String body})> _runHttpProbe(
  HttpClient client,
  Uri uri, {
  required Map<String, String> headers,
}) async {
  client.connectionTimeout = const Duration(seconds: 10);
  final request = await client.getUrl(uri);
  headers.forEach(request.headers.set);
  final response = await request.close().timeout(const Duration(seconds: 10));
  final body = await utf8.decoder.bind(response).join();
  return (statusCode: response.statusCode, body: body);
}

String? _extractGitHubMessage(String body) {
  if (body.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}
