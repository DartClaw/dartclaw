import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the active server assets came from.
enum AssetSource {
  /// Explicit `--source-dir` / `--templates-dir` / `--static-dir`.
  explicitConfig,

  /// `--dev` / `devMode` source checkout.
  devSourceTree,

  /// A source-tree default path that exists without an explicit source flag.
  sourceTreeDefault,

  /// Assets compiled into the DartClaw binary.
  embedded,
}

/// Inputs the resolver needs to honor caller intent.
class AssetResolutionRequest {
  final String configuredTemplatesDir;
  final String configuredStaticDir;
  final bool explicitlyConfigured;
  final bool devMode;

  const AssetResolutionRequest({
    required this.configuredTemplatesDir,
    required this.configuredStaticDir,
    required this.explicitlyConfigured,
    required this.devMode,
  });

  const AssetResolutionRequest.noConfiguredAssets()
    : configuredTemplatesDir = '',
      configuredStaticDir = '',
      explicitlyConfigured = false,
      devMode = false;
}

/// A resolved asset location plus its provenance.
class ResolvedAssets {
  final String? root;
  final String? templatesDir;
  final String? staticDir;
  final String? skillsDir;
  final String? workflowsDir;
  final AssetSource source;

  const ResolvedAssets({
    this.root,
    required this.templatesDir,
    required this.staticDir,
    required this.source,
    this.skillsDir,
    this.workflowsDir,
  });

  factory ResolvedAssets.fromSourceTree({
    required String templatesDir,
    required String staticDir,
    required AssetSource source,
  }) {
    final root = _inferSourceTreeRoot(templatesDir: templatesDir, staticDir: staticDir);
    return ResolvedAssets(
      root: root,
      templatesDir: templatesDir,
      staticDir: staticDir,
      skillsDir: root == null ? null : p.join(root, 'packages', 'dartclaw_workflow', 'skills'),
      workflowsDir: root == null
          ? null
          : p.join(root, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
      source: source,
    );
  }

  const ResolvedAssets.embedded()
    : root = null,
      templatesDir = null,
      staticDir = null,
      skillsDir = null,
      workflowsDir = null,
      source = AssetSource.embedded;

  String get sourcePath => root ?? templatesDir ?? source.name;

  String describe() => source == AssetSource.embedded ? source.name : '${source.name} at $sourcePath';

  static String? _inferSourceTreeRoot({required String templatesDir, required String staticDir}) {
    final normalizedTemplates = p.normalize(templatesDir);
    final normalizedStatic = p.normalize(staticDir);
    if (p.basename(normalizedTemplates) != 'templates' || p.basename(normalizedStatic) != 'static') return null;

    final srcDir = p.dirname(normalizedTemplates);
    if (!p.equals(srcDir, p.dirname(normalizedStatic)) || p.basename(srcDir) != 'src') return null;

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

/// Resolves disk assets from caller intent, then falls back to embedded assets.
class AssetResolver {
  const AssetResolver();

  ResolvedAssets resolveAssets(AssetResolutionRequest request) {
    final sourceTreeExists =
        request.configuredTemplatesDir.isNotEmpty &&
        request.configuredStaticDir.isNotEmpty &&
        Directory(request.configuredTemplatesDir).existsSync() &&
        Directory(request.configuredStaticDir).existsSync();

    ResolvedAssets sourceTree(AssetSource source) => ResolvedAssets.fromSourceTree(
      templatesDir: request.configuredTemplatesDir,
      staticDir: request.configuredStaticDir,
      source: source,
    );

    if (sourceTreeExists && request.explicitlyConfigured) return sourceTree(AssetSource.explicitConfig);
    if (sourceTreeExists && request.devMode) return sourceTree(AssetSource.devSourceTree);
    if (sourceTreeExists) return sourceTree(AssetSource.sourceTreeDefault);
    return const ResolvedAssets.embedded();
  }
}
