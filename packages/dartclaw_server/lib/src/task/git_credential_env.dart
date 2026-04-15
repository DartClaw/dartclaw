import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../project/project_auth_support.dart';

final _log = Logger('GitCredentialEnv');

/// Per-command git credential resolution.
final class GitCredentialPlan {
  final String remoteUrl;
  final Map<String, String> environment;

  const GitCredentialPlan({required this.remoteUrl, required this.environment});
}

/// Resolves git transport and environment variables for credential injection.
GitCredentialPlan resolveGitCredentialPlan(
  String remoteUrl,
  String? credentialsRef,
  CredentialsConfig credentials, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  final environment = <String, String>{'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'never'};
  final isSsh = remoteUrl.startsWith('git@') || remoteUrl.startsWith('ssh://');
  if (credentialsRef == null) {
    if (isSsh) {
      environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new';
    }
    return GitCredentialPlan(remoteUrl: remoteUrl, environment: environment);
  }

  final entry = credentials[credentialsRef];
  if (entry == null || !entry.isPresent) {
    _log.warning('Credential "$credentialsRef" not found — using non-interactive default git auth');
    if (isSsh) {
      environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new';
    }
    return GitCredentialPlan(remoteUrl: remoteUrl, environment: environment);
  }

  if (entry.isGitHubToken) {
    final gitHubRepo = GitHubRepositoryRef.tryParse(remoteUrl);
    if (gitHubRepo != null) {
      return GitCredentialPlan(
        remoteUrl: gitHubRepo.canonicalHttpsUrl,
        environment: {
          ...environment,
          ..._buildGitHubTokenEnv(credentialsRef, entry.token, dataDir: dataDir, tempFiles: tempFiles),
        },
      );
    }
  }

  if (isSsh) {
    return GitCredentialPlan(
      remoteUrl: remoteUrl,
      environment: {
        ...environment,
        'GIT_SSH_COMMAND': 'ssh -i ${entry.apiKey} -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
      },
    );
  }

  return GitCredentialPlan(
    remoteUrl: remoteUrl,
    environment: {
      ...environment,
      ..._buildLegacyAskPassEnv(credentialsRef, entry.apiKey, dataDir: dataDir, tempFiles: tempFiles),
    },
  );
}

/// Resolves git environment variables for credential injection.
///
/// For SSH remotes: sets [GIT_SSH_COMMAND] with the credential's key path.
/// For HTTPS remotes: creates a temporary askpass script and sets [GIT_ASKPASS].
/// Returns an empty map if no credential found (fallback to default git auth).
///
/// Shared between [ProjectServiceImpl] and [RemotePushService].
Map<String, String> resolveGitCredentialEnv(
  String remoteUrl,
  String? credentialsRef,
  CredentialsConfig credentials, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  return resolveGitCredentialPlan(
    remoteUrl,
    credentialsRef,
    credentials,
    dataDir: dataDir,
    tempFiles: tempFiles,
  ).environment;
}

Map<String, String> _buildLegacyAskPassEnv(
  String credRef,
  String apiKey, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  final keyFilePath = p.join(dataDir, 'projects', '.git-askpass-$credRef.key');
  final scriptPath = p.join(dataDir, 'projects', '.git-askpass-$credRef');
  try {
    Directory(p.dirname(scriptPath)).createSync(recursive: true);
    File(keyFilePath).writeAsStringSync(apiKey);
    File(scriptPath).writeAsStringSync('#!/bin/sh\ncat \'$keyFilePath\'\n');
    Process.runSync('chmod', ['+x', scriptPath]);
    for (final path in [scriptPath, keyFilePath]) {
      if (!tempFiles.contains(path)) tempFiles.add(path);
    }
    return {'GIT_ASKPASS': scriptPath};
  } catch (e) {
    _log.warning('Failed to create askpass script: $e — using default git auth');
    return const {};
  }
}

Map<String, String> _buildGitHubTokenEnv(
  String credRef,
  String token, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  final tokenFilePath = p.join(dataDir, 'projects', '.git-askpass-$credRef.token');
  final scriptPath = p.join(dataDir, 'projects', '.git-askpass-$credRef');
  try {
    Directory(p.dirname(scriptPath)).createSync(recursive: true);
    File(tokenFilePath).writeAsStringSync(token);
    File(scriptPath).writeAsStringSync(
      [
        '#!/bin/sh',
        'case "\$1" in',
        "  *Username*) printf '%s\\n' 'x-access-token' ;;",
        "  *) cat '$tokenFilePath' ;;",
        'esac',
        '',
      ].join('\n'),
    );
    Process.runSync('chmod', ['+x', scriptPath]);
    for (final path in [scriptPath, tokenFilePath]) {
      if (!tempFiles.contains(path)) tempFiles.add(path);
    }
    return {'GIT_ASKPASS': scriptPath};
  } catch (e) {
    _log.warning('Failed to create GitHub askpass script: $e — using default git auth');
    return const {};
  }
}
