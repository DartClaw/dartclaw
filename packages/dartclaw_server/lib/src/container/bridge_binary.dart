import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../generated/embedded_assets.g.dart';

/// Materializes the Linux bridge executable the host delivers into containers.
///
/// The bridge ships with DartClaw and is cross-compiled at release time, so the
/// host and the in-container binary are always the same build (ADR-051). This
/// class only resolves and unpacks it; the protocol handshake is what actually
/// proves the pair matches.
final class BridgeBinaryProvisioner {
  BridgeBinaryProvisioner({required this.dataDir, Map<String, List<int>>? embeddedAssets, Directory? sourceTreeDir})
    : _embedded = embeddedAssets ?? embeddedServerBinaryAssets,
      _sourceTreeDir = sourceTreeDir ?? Directory(p.join(Directory.current.path, 'build', 'bridge'));

  static final _log = Logger('BridgeBinaryProvisioner');

  /// Asset key prefix inside the embedded binary-asset map.
  static const assetPrefix = 'bridge';

  /// Where the bridge is delivered inside the container.
  static const containerPath = '/opt/dartclaw/dartclaw-bridge';

  final String dataDir;
  final Map<String, List<int>> _embedded;
  final Directory _sourceTreeDir;

  final Map<String, String> _materialized = {};

  /// Container architectures the release ships a bridge for.
  static const supportedArchitectures = {'x64', 'arm64'};

  /// Maps a Docker server architecture onto the shipped variant.
  static String? architectureFor(String dockerArch) => switch (dockerArch.trim().toLowerCase()) {
    'amd64' || 'x86_64' || 'x64' => 'x64',
    'arm64' || 'aarch64' => 'arm64',
    _ => null,
  };

  static String fileNameFor(String architecture) => 'dartclaw-bridge-linux-$architecture';

  /// Returns the host path of the bridge binary for [architecture], unpacking
  /// it on first use.
  ///
  /// Throws [StateError] when the release carries no bridge for that
  /// architecture — a container turn must fail rather than run without
  /// mediation.
  Future<String> ensureAvailable(String architecture) async {
    final existing = _materialized[architecture];
    if (existing != null) return existing;

    final fileName = fileNameFor(architecture);
    final target = File(p.join(dataDir, 'bridge', fileName));
    final bytes = _resolveBytes(fileName);
    if (bytes == null) {
      throw StateError(
        'No container bridge binary for linux-$architecture is available. Release builds ship one; in a source '
        'checkout run `bash dev/tools/build_bridge.sh` to cross-compile it.',
      );
    }

    if (!target.parent.existsSync()) {
      target.parent.createSync(recursive: true);
    }
    // Rewritten unconditionally: a same-length file already on disk is not
    // evidence that it is this release's bridge, and the executable runs
    // inside every isolated container.
    target.writeAsBytesSync(bytes, flush: true);
    _log.info('Materialized container bridge for linux-$architecture (${bytes.length} bytes)');
    await _makeExecutable(target.path);
    _materialized[architecture] = target.path;
    return target.path;
  }

  List<int>? _resolveBytes(String fileName) {
    // What shipped with this release always wins. Falling back to a path under
    // the working directory would let any directory containing build/bridge/
    // decide which executable runs inside every container; only a source
    // checkout, which embeds nothing, reaches that branch.
    final compressed = _embedded['$assetPrefix/$fileName.gz'];
    if (compressed != null) return gzip.decode(compressed);
    final embedded = _embedded['$assetPrefix/$fileName'];
    if (embedded != null) return embedded;

    final sourceFile = File(p.join(_sourceTreeDir.path, fileName));
    return sourceFile.existsSync() ? sourceFile.readAsBytesSync() : null;
  }

  Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to make the container bridge executable: ${result.stderr}');
    }
  }
}
