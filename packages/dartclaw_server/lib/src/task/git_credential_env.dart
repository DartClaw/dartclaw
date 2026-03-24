import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show CredentialsConfig;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('GitCredentialEnv');

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
  if (credentialsRef == null) return const {};

  final entry = credentials[credentialsRef];
  if (entry == null || !entry.isPresent) {
    _log.warning('Credential "$credentialsRef" not found — using default git auth');
    return const {};
  }

  return _buildGitEnvForCredential(
    remoteUrl,
    credentialsRef,
    entry.apiKey,
    dataDir: dataDir,
    tempFiles: tempFiles,
  );
}

Map<String, String> _buildGitEnvForCredential(
  String remoteUrl,
  String credRef,
  String apiKey, {
  required String dataDir,
  required List<String> tempFiles,
}) {
  final isSsh = remoteUrl.startsWith('git@') || remoteUrl.startsWith('ssh://');

  if (isSsh) {
    return {
      'GIT_SSH_COMMAND': 'ssh -i $apiKey -o StrictHostKeyChecking=accept-new',
    };
  } else {
    // HTTPS: write the token to a key file and generate an askpass script that
    // cats it. Avoids shell variable expansion — token is never interpolated
    // into the script body, so metacharacters in the key are safe.
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
}
