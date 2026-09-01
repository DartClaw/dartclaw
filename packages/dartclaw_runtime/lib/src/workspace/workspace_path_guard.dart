import 'dart:io';

import 'package:path/path.dart' as p;

/// A candidate path that resolved to a regular file inside the workspace, or
/// the rule that refused it.
///
/// Exactly one of [file] and [refusal] is non-null.
typedef WorkspacePathVerdict = ({File? file, String? refusal});

/// Resolves a candidate path against one workspace root, refusing anything that
/// leaves it.
///
/// Containment is decided on **symlink-resolved** paths on both sides: a link
/// stored inside the workspace can point anywhere, and a containment check on
/// the unresolved path admits it. The root is resolved the same way
/// `WorkspaceFileReader` resolves it, so the two do not disagree about where
/// the workspace is.
final class WorkspacePathGuard {
  final String _root;

  /// Pins [workspaceDir] to its canonical directory for subsequent checks.
  new(String workspaceDir) : _root = _resolveRoot(workspaceDir);

  /// The canonical workspace root every verdict is measured against.
  String get root => _root;

  /// Resolves [candidate], workspace-relative or absolute.
  ///
  /// Containment is decided on the candidate's canonical location and is
  /// decided **first**: everything outside the workspace answers one message
  /// whatever is actually there. Distinguishing "no file exists" from "is not a
  /// regular file" for an uncontained path would make this a filesystem
  /// existence-and-type oracle over the whole host, which is a different
  /// disclosure from the one this tool is allowed to make. Inside the workspace
  /// the specific rule is named, because a caller may read there anyway.
  WorkspacePathVerdict resolveFile(String candidate) {
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return (file: null, refusal: 'path must not be blank');

    final absolute = p.isAbsolute(trimmed) ? p.normalize(trimmed) : p.normalize(p.join(_root, trimmed));
    final resolved = _canonicalize(absolute);
    if (!p.isWithin(_root, resolved)) {
      return (file: null, refusal: '"$candidate" is not inside the workspace and cannot be sent');
    }

    final type = FileSystemEntity.typeSync(resolved, followLinks: false);
    if (type == FileSystemEntityType.notFound) return (file: null, refusal: 'no file exists at "$candidate"');
    if (type != FileSystemEntityType.file) return (file: null, refusal: '"$candidate" is not a regular file');
    return (file: File(resolved), refusal: null);
  }

  /// Where [absolute] actually points, with every symlink in the chain followed.
  ///
  /// Resolves the deepest ancestor the host can resolve and re-appends the rest,
  /// so a path naming something that does not exist still answers where it
  /// *would* be — a containment check that only worked for existing paths would
  /// have to report absence before containment, which is the disclosure
  /// [resolveFile] refuses to make. A link whose target is missing resolves to
  /// where the link sits, so it is judged as the link it is.
  static String _canonicalize(String absolute) {
    var head = absolute;
    final tail = <String>[];
    while (true) {
      try {
        final resolvedHead = p.normalize(File(head).resolveSymbolicLinksSync());
        return tail.isEmpty ? resolvedHead : p.normalize(p.joinAll([resolvedHead, ...tail.reversed]));
      } on FileSystemException {
        final parent = p.dirname(head);
        if (parent == head) return absolute;
        tail.add(p.basename(head));
        head = parent;
      }
    }
  }

  /// Mirrors `WorkspaceFileReader`'s root resolution — a third convention for
  /// where the workspace is would be a third answer.
  static String _resolveRoot(String workspaceDir) {
    final directory = Directory(p.absolute(workspaceDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return p.normalize(directory.path);
    if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root does not resolve to a directory', directory.path);
    }
    return p.normalize(resolved);
  }
}
