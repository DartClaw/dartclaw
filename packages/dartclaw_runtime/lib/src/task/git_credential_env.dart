import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show secureWriteFileSync;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../project/project_auth_support.dart';

final _log = Logger('GitCredentialEnv');

/// Per-command git credential resolution.
final class GitCredentialPlan implements ProcessEnvironmentPlan {
  final String remoteUrl;
  @override
  final Map<String, String> environment;

  const new({required this.remoteUrl, required this.environment});

  const new none() : remoteUrl = '', environment = const <String, String>{};
}

/// Prepends a `-c remote.origin.url=$resolvedRemoteUrl` override to [gitArgs]
/// when the resolved URL differs from [originalRemoteUrl] (e.g. a credential
/// plan rewrote the transport to a token-bearing HTTPS form). Returns
/// [gitArgs] unchanged when [originalRemoteUrl] is empty/whitespace or when
/// the two URLs match — leaves the working tree's recorded remote alone.
List<String> buildRemoteOverrideArgs(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs) {
  if (originalRemoteUrl.trim().isEmpty || originalRemoteUrl == resolvedRemoteUrl) {
    return gitArgs;
  }
  return ['-c', 'remote.origin.url=$resolvedRemoteUrl', ...gitArgs];
}

GitHubRepositoryRef? gitHubRepositoryForToken(String remoteUrl, CredentialEntry? credential) =>
    credential != null && credential.isPresent && credential.isGitHubToken
    ? GitHubRepositoryRef.tryParse(remoteUrl)
    : null;

/// Resolves git transport and environment variables for credential injection.
GitCredentialPlan resolveGitCredentialPlan(
  String remoteUrl,
  String? credentialsRef,
  CredentialsConfig credentials, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  final environment = <String, String>{
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    'GIT_CONFIG_COUNT': '1',
    'GIT_CONFIG_KEY_0': 'credential.helper',
    'GIT_CONFIG_VALUE_0': '',
  };
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

  final gitHubRepo = gitHubRepositoryForToken(remoteUrl, entry);
  if (gitHubRepo != null) {
    return GitCredentialPlan(
      remoteUrl: gitHubRepo.canonicalHttpsUrl,
      environment: {
        ...environment,
        ..._buildGitHubTokenEnv(credentialsRef, entry.token, dataDir: dataDir, tempFiles: tempFiles),
      },
    );
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
    secureWriteFileSync(File(keyFilePath), apiKey);
    _writeOwnerOnlyScript(scriptPath, '#!/bin/sh\ncat \'$keyFilePath\'\n');
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
    secureWriteFileSync(File(tokenFilePath), token);
    _writeOwnerOnlyScript(
      scriptPath,
      [
        '#!/bin/sh',
        'case "\$1" in',
        "  *Username*) printf '%s\\n' 'x-access-token' ;;",
        "  *) cat '$tokenFilePath' ;;",
        'esac',
        '',
      ].join('\n'),
    );
    for (final path in [scriptPath, tokenFilePath]) {
      if (!tempFiles.contains(path)) tempFiles.add(path);
    }
    return {'GIT_ASKPASS': scriptPath};
  } catch (e) {
    _log.warning('Failed to create GitHub askpass script: $e — using default git auth');
    return const {};
  }
}

void _writeOwnerOnlyScript(String path, String contents) {
  secureWriteFileSync(File(path), contents);
  Process.runSync('chmod', ['u+x', path]);
}
