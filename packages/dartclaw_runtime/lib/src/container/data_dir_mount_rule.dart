import 'package:dartclaw_kernel/dartclaw_kernel.dart' show canonicalizePathWithExistingAncestors;
import 'package:path/path.dart' as p;

/// The Docker `-v` specs one operator-chosen read-only source contributes.
final class OperatorMount {
  /// Bind and mask specs, empty when the source must not be mounted at all.
  final List<String> specs;

  /// Why [specs] differ from a plain read-only bind, or `null` when they do not.
  final String? reason;

  const new({required this.specs, this.reason});
}

/// Maps [source] to [target] read-only without ever exposing [dataDir].
///
/// Paths are compared canonically, symlinks resolved where they exist. A
/// source equal to or inside one of [ownedRoots] (DartClaw-owned directories
/// that are container-visible anyway) mounts unchanged. Otherwise a source
/// equal to or inside the data directory is not mounted, and a source that
/// contains it is bound with an anonymous volume masking the data directory's
/// container path. The bind keeps the caller's spelling of [source].
OperatorMount operatorMount({
  required String source,
  required String target,
  required String dataDir,
  Iterable<String> ownedRoots = const [],
}) {
  final bind = OperatorMount(specs: ['$source:$target:ro']);
  final canonicalSource = canonicalizePathWithExistingAncestors(source);
  bool contains(String root, String path) => p.equals(root, path) || p.isWithin(root, path);

  if (ownedRoots.any((root) => contains(canonicalizePathWithExistingAncestors(root), canonicalSource))) return bind;
  final canonicalDataDir = canonicalizePathWithExistingAncestors(dataDir);
  if (contains(canonicalDataDir, canonicalSource)) {
    final where = p.equals(canonicalDataDir, canonicalSource) ? 'is' : 'is inside';
    return OperatorMount(
      specs: const [],
      reason: 'Not mounting $source at $target: it $where the data directory $dataDir',
    );
  }
  if (!p.isWithin(canonicalSource, canonicalDataDir)) return bind;
  final relative = p.split(p.relative(canonicalDataDir, from: canonicalSource));
  final mask = p.posix.joinAll([target, ...relative]);
  return OperatorMount(
    specs: [...bind.specs, mask],
    reason: 'Mounting $source at $target with the data directory $dataDir masked empty at $mask',
  );
}
