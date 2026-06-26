import 'dart:io';

import 'package:path/path.dart' as p;

import 'version.dart';

/// Where a resolved asset root came from.
enum AssetSource {
  /// Explicit `--source-dir` / `--templates-dir` / `--static-dir`.
  explicitConfig,

  /// `--dev` / `devMode` source checkout.
  devSourceTree,

  /// Installed alongside the binary (`../share/dartclaw` or `<exeDir>`).
  installedAlongsideBinary,

  /// Version-pinned download cache (`~/.dartclaw/assets/v<version>`).
  downloadedCache,

  /// A source-tree default path that exists without an explicit source flag.
  sourceTreeDefault,
}

/// How built-in skills and workflow definitions should be resolved.
enum WorkflowAssetPolicy {
  /// Use the concrete `skills/` and `workflows/` directories under the resolved root.
  resolvedDirectories,

  /// Resolve built-ins from the source checkout fallback.
  sourceTreeFallback,
}

/// Inputs the resolver needs to honor caller intent.
class AssetResolutionRequest {
  /// Configured templates dir.
  final String configuredTemplatesDir;

  /// Configured static dir.
  final String configuredStaticDir;

  /// True when the user explicitly set a source/templates/static dir.
  final bool explicitlyConfigured;

  /// True under `--dev` / `devMode`.
  final bool devMode;

  const AssetResolutionRequest({
    required this.configuredTemplatesDir,
    required this.configuredStaticDir,
    required this.explicitlyConfigured,
    required this.devMode,
  });

  /// Request for install/cache lookup with no configured source-tree intent.
  const AssetResolutionRequest.noConfiguredAssets()
    : configuredTemplatesDir = '',
      configuredStaticDir = '',
      explicitlyConfigured = false,
      devMode = false;
}

/// A resolved asset location plus its provenance.
class ResolvedAssets {
  final String? root;
  final String templatesDir;
  final String staticDir;
  final String? skillsDir;
  final String? workflowsDir;
  final AssetSource source;
  final WorkflowAssetPolicy workflowAssetPolicy;
  final String? declaredVersion;

  const ResolvedAssets({
    this.root,
    required this.templatesDir,
    required this.staticDir,
    required this.source,
    required this.workflowAssetPolicy,
    this.skillsDir,
    this.workflowsDir,
    this.declaredVersion,
  });

  /// Creates a source-tree result with concrete template/static dirs.
  factory ResolvedAssets.fromSourceTree({
    required String templatesDir,
    required String staticDir,
    required AssetSource source,
  }) {
    final sourceTreeRoot = _inferSourceTreeRoot(templatesDir: templatesDir, staticDir: staticDir);
    return ResolvedAssets(
      root: sourceTreeRoot,
      templatesDir: templatesDir,
      staticDir: staticDir,
      skillsDir: sourceTreeRoot == null ? null : p.join(sourceTreeRoot, 'packages', 'dartclaw_workflow', 'skills'),
      workflowsDir: sourceTreeRoot == null
          ? null
          : p.join(sourceTreeRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
      source: source,
      workflowAssetPolicy: WorkflowAssetPolicy.sourceTreeFallback,
    );
  }

  /// Creates a flat install/cache/download result where all assets live under [root].
  factory ResolvedAssets.fromRoot(String root, AssetSource source, {String? declaredVersion}) => ResolvedAssets(
    root: root,
    templatesDir: p.join(root, 'templates'),
    staticDir: p.join(root, 'static'),
    skillsDir: p.join(root, 'skills'),
    workflowsDir: p.join(root, 'workflows'),
    source: source,
    workflowAssetPolicy: WorkflowAssetPolicy.resolvedDirectories,
    declaredVersion: declaredVersion,
  );

  /// Path to show when reporting the resolved source.
  String get sourcePath => root ?? templatesDir;

  /// Concrete `skills/` dir when assets came from a flat install/cache root.
  String? get rootSkillsDir => workflowAssetPolicy == WorkflowAssetPolicy.resolvedDirectories ? skillsDir : null;

  /// Concrete `workflows/` dir when assets came from a flat install/cache root.
  String? get rootWorkflowsDir => workflowAssetPolicy == WorkflowAssetPolicy.resolvedDirectories ? workflowsDir : null;

  /// One-line startup provenance.
  String describe() {
    final ver = declaredVersion == null ? '' : ' (declares v$declaredVersion)';
    return '${source.name} at $templatesDir$ver';
  }

  static String? _inferSourceTreeRoot({required String templatesDir, required String staticDir}) {
    final normalizedTemplates = p.normalize(templatesDir);
    final normalizedStatic = p.normalize(staticDir);
    if (p.basename(normalizedTemplates) != 'templates' || p.basename(normalizedStatic) != 'static') {
      return null;
    }

    final srcDir = p.dirname(normalizedTemplates);
    if (!p.equals(srcDir, p.dirname(normalizedStatic)) || p.basename(srcDir) != 'src') {
      return null;
    }

    final libDir = p.dirname(srcDir);
    final packageDir = p.dirname(libDir);
    final packagesDir = p.dirname(packageDir);
    if (p.basename(libDir) != 'lib' ||
        p.basename(packageDir) != 'dartclaw_server' ||
        p.basename(packagesDir) != 'packages') {
      return null;
    }

    return p.dirname(packagesDir);
  }
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

  /// Resolves assets using caller intent before install/cache fallbacks.
  ResolvedAssets? resolveAssets(AssetResolutionRequest request) {
    final sourceTreeExists =
        Directory(request.configuredTemplatesDir).existsSync() && Directory(request.configuredStaticDir).existsSync();

    ResolvedAssets sourceTree(AssetSource source) => ResolvedAssets.fromSourceTree(
      templatesDir: request.configuredTemplatesDir,
      staticDir: request.configuredStaticDir,
      source: source,
    );

    if (sourceTreeExists && request.explicitlyConfigured) return sourceTree(AssetSource.explicitConfig);
    if (sourceTreeExists && request.devMode) return sourceTree(AssetSource.devSourceTree);

    for (final candidate in _provenancedCandidates()) {
      if (!_isValidRoot(candidate.root)) continue;
      final declared = _readVersionMarker(candidate.root);
      if (candidate.source == AssetSource.downloadedCache && declared != version) {
        continue;
      }
      return ResolvedAssets.fromRoot(candidate.root, candidate.source, declaredVersion: declared);
    }

    if (sourceTreeExists) return sourceTree(AssetSource.sourceTreeDefault);
    return null;
  }

  Iterable<({String root, AssetSource source})> _provenancedCandidates() sync* {
    final executableDir = p.dirname(resolvedExecutable);
    yield (
      root: p.normalize(p.join(executableDir, '..', 'share', 'dartclaw')),
      source: AssetSource.installedAlongsideBinary,
    );
    yield (root: p.normalize(executableDir), source: AssetSource.installedAlongsideBinary);
    final resolvedHomeDir = _resolveHomeDir();
    if (resolvedHomeDir != null) {
      yield (root: p.join(resolvedHomeDir, '.dartclaw', 'assets', 'v$version'), source: AssetSource.downloadedCache);
    }
  }

  String? _readVersionMarker(String root) {
    final file = File(p.join(root, 'VERSION'));
    if (!file.existsSync()) return null;
    final v = file.readAsStringSync().trim();
    return v.isEmpty ? null : v;
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
