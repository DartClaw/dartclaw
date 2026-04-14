import 'dart:io';

import 'package:path/path.dart' as p;

import 'version.dart';

/// Resolved filesystem asset locations for a DartClaw installation.
class ResolvedAssetPaths {
  final String root;

  const ResolvedAssetPaths({required this.root});

  String get templatesDir => p.join(root, 'templates');
  String get staticDir => p.join(root, 'static');
  String get skillsDir => p.join(root, 'skills');
  String get workflowsDir => p.join(root, 'workflows');
}

/// Resolves a local asset root from the executable layout or the user cache.
///
/// The resolver is intentionally filesystem-only. It validates a candidate root
/// by requiring `templates/` and `static/` to exist before accepting it.
class AssetResolver {
  final String resolvedExecutable;
  final String? homeDir;
  final String version;

  AssetResolver({String? resolvedExecutable, this.homeDir, this.version = dartclawVersion})
    : resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable;

  ResolvedAssetPaths? resolve() {
    for (final candidateRoot in _candidateRoots()) {
      if (_isValidRoot(candidateRoot)) {
        return ResolvedAssetPaths(root: candidateRoot);
      }
    }
    return null;
  }

  Iterable<String> _candidateRoots() sync* {
    final executableDir = p.dirname(resolvedExecutable);
    yield p.normalize(p.join(executableDir, '..', 'share', 'dartclaw'));
    yield p.normalize(executableDir);

    final resolvedHomeDir = _resolveHomeDir();
    if (resolvedHomeDir != null) {
      yield p.join(resolvedHomeDir, '.dartclaw', 'assets', 'v$version');
    }
  }

  String? _resolveHomeDir() {
    final override = homeDir?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }

    final envHome = Platform.environment['HOME']?.trim();
    if (envHome != null && envHome.isNotEmpty) {
      return envHome;
    }

    final userProfile = Platform.environment['USERPROFILE']?.trim();
    if (userProfile != null && userProfile.isNotEmpty) {
      return userProfile;
    }

    return null;
  }

  bool _isValidRoot(String candidateRoot) {
    return Directory(p.join(candidateRoot, 'templates')).existsSync() &&
        Directory(p.join(candidateRoot, 'static')).existsSync();
  }
}
