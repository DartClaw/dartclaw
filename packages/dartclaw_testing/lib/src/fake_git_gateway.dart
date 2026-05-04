import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;

/// In-memory [WorkflowGitPort] for workflow and merge tests.
final class FakeGitGateway implements WorkflowGitPort {
  final _commits = <String, Map<String, String>>{};
  final _refs = <String, String>{};
  final _worktrees = <String, _FakeWorktree>{};
  final _conflictPathsByRef = <String, List<String>>{};
  var _nextCommit = 1;
  String? _nextAddFailure;

  /// Observable operations in call order.
  final events = <String>[];

  /// Number of times [stashPop] was attempted.
  int stashPopAttempts = 0;

  /// Creates a worktree with an initial commit and branch.
  String initWorktree(
    String worktreePath, {
    String branch = 'main',
    Map<String, String> files = const <String, String>{},
  }) {
    final sha = _createCommit(files);
    _refs[branch] = sha;
    _worktrees[worktreePath] = _FakeWorktree(branch: branch, head: sha);
    return sha;
  }

  /// Creates or updates [ref] with a new commit.
  String commitRef(String ref, Map<String, String> files) {
    final sha = _createCommit(files);
    _refs[ref] = sha;
    return sha;
  }

  /// Advances [ref] to an existing commit SHA.
  void setRef(String ref, String sha) {
    _requireCommit(sha);
    _refs[ref] = sha;
  }

  /// Adds or replaces an untracked working-tree file.
  void addUntracked(String worktreePath, String path, {String content = ''}) {
    _worktree(worktreePath).untracked[path] = content;
  }

  /// Modifies a tracked working-tree file.
  void modifyTracked(String worktreePath, String path, String content) {
    _worktree(worktreePath).modified[path] = content;
  }

  /// Adds a stash entry without mutating the working tree.
  void addStash(String worktreePath, Iterable<String> paths) {
    _worktree(worktreePath).stash.insert(0, _FakeStash({for (final path in paths) path: 'stashed:$path'}));
  }

  /// Makes a merge of [ref] fail with [paths] as conflicts.
  void conflictOnMerge(String ref, Iterable<String> paths) {
    _conflictPathsByRef[ref] = List.unmodifiable(paths);
  }

  /// Makes the next [add] call fail.
  void failNextAdd(String message) {
    _nextAddFailure = message;
  }

  @override
  Future<String> revParse(String worktreePath, String ref) async {
    events.add('rev-parse $ref');
    final worktree = _worktree(worktreePath);
    if (ref == 'HEAD') return worktree.head;
    if (ref == '--abbrev-ref HEAD') return worktree.branch ?? 'HEAD';
    return _resolveRef(ref);
  }

  @override
  Future<List<String>> diffNameOnly(
    String worktreePath, {
    String? against,
    bool cached = false,
    String? diffFilter,
  }) async {
    events.add('diff --name-only');
    final worktree = _worktree(worktreePath);
    if (diffFilter == 'U') return List.unmodifiable(worktree.conflicts);
    if (cached) return _sorted(worktree.staged);
    final changed = <String>{...worktree.modified.keys, ...worktree.untracked.keys, ...worktree.staged};
    return _sorted(changed);
  }

  @override
  Future<bool> pathExistsAtRef(String worktreePath, {required String ref, required String path}) async {
    events.add('cat-file $ref:$path');
    final sha = ref == 'HEAD' ? _worktree(worktreePath).head : _resolveRef(ref);
    return _commits[sha]?.containsKey(path) ?? false;
  }

  @override
  Future<GitStatus> status(String worktreePath) async {
    events.add('status');
    final worktree = _worktree(worktreePath);
    final modified = <String>{...worktree.modified.keys, ...worktree.staged};
    return GitStatus(
      indexClean: modified.isEmpty && worktree.conflicts.isEmpty,
      modified: _sorted(modified),
      untracked: _sorted(worktree.untracked.keys),
    );
  }

  @override
  Future<List<String>> untrackedFiles(String worktreePath) async {
    events.add('untracked');
    return _sorted(_worktree(worktreePath).untracked.keys);
  }

  @override
  Future<List<String>> stashedPaths(String worktreePath, {int index = 0}) async {
    events.add('stash show');
    final stash = _worktree(worktreePath).stash;
    if (index < 0 || index >= stash.length) return const <String>[];
    return _sorted(stash[index].files.keys);
  }

  @override
  Future<void> add(String worktreePath, List<String> paths, {bool all = false}) async {
    events.add(all ? 'add -A' : 'add ${paths.join(' ')}');
    final failure = _nextAddFailure;
    if (failure != null) {
      _nextAddFailure = null;
      throw WorkflowGitException(failure, stderr: failure);
    }
    final worktree = _worktree(worktreePath);
    final selected = all ? <String>{...worktree.modified.keys, ...worktree.untracked.keys} : paths.toSet();
    for (final path in selected) {
      if (!worktree.modified.containsKey(path) && !worktree.untracked.containsKey(path)) {
        continue;
      }
      worktree.staged.add(path);
      if (worktree.untracked.containsKey(path)) {
        worktree.modified[path] = worktree.untracked.remove(path)!;
      }
    }
  }

  @override
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    events.add('commit');
    final worktree = _worktree(worktreePath);
    if (worktree.staged.isEmpty) {
      throw const WorkflowGitException('Failed to commit staged changes', stdout: 'nothing to commit');
    }
    final tree = Map<String, String>.from(_commits[worktree.head] ?? const <String, String>{});
    for (final path in worktree.staged) {
      tree[path] = worktree.modified[path] ?? tree[path] ?? '';
      worktree.modified.remove(path);
    }
    worktree.staged.clear();
    final sha = _createCommit(tree);
    worktree.head = sha;
    final branch = worktree.branch;
    if (branch != null) {
      _refs[branch] = sha;
    }
    return WorkflowGitCommit(sha: sha, message: message);
  }

  @override
  Future<void> checkout(String worktreePath, String ref) async {
    events.add('checkout $ref');
    final worktree = _worktree(worktreePath);
    final sha = _resolveRef(ref);
    worktree
      ..branch = _refs.containsKey(ref) ? ref : null
      ..head = sha
      ..modified.clear()
      ..untracked.clear()
      ..staged.clear()
      ..conflicts.clear();
  }

  @override
  Future<bool> stashPush(String worktreePath, {bool includeUntracked = true}) async {
    events.add('stash push');
    final worktree = _worktree(worktreePath);
    final files = <String, String>{...worktree.modified, if (includeUntracked) ...worktree.untracked};
    if (files.isEmpty) return false;
    worktree.stash.insert(0, _FakeStash(files));
    worktree
      ..modified.clear()
      ..untracked.clear()
      ..staged.clear();
    return true;
  }

  @override
  Future<void> stashPop(String worktreePath) async {
    events.add('stash pop');
    stashPopAttempts++;
    final worktree = _worktree(worktreePath);
    if (worktree.stash.isEmpty) return;
    final stash = worktree.stash.first;
    final headTree = _commits[worktree.head] ?? const <String, String>{};
    final overlap = stash.files.keys
        .where((path) => worktree.untracked.containsKey(path) || headTree.containsKey(path))
        .toList();
    if (overlap.isNotEmpty) {
      throw WorkflowGitException(
        'Failed to restore stash',
        stderr: overlap.map((path) => '$path already exists, no checkout').join('\n'),
      );
    }
    for (final entry in stash.files.entries) {
      worktree.untracked[entry.key] = entry.value;
    }
    worktree.stash.removeAt(0);
  }

  @override
  Future<void> stashDrop(String worktreePath, {int index = 0}) async {
    events.add('stash drop');
    final stash = _worktree(worktreePath).stash;
    if (index >= 0 && index < stash.length) {
      stash.removeAt(index);
    }
  }

  @override
  Future<void> merge(
    String worktreePath, {
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  }) async {
    events.add('merge $ref');
    final worktree = _worktree(worktreePath);
    final conflicts = _conflictPathsByRef[ref] ?? const <String>[];
    if (conflicts.isNotEmpty) {
      worktree.conflicts
        ..clear()
        ..addAll(conflicts);
      throw WorkflowGitException('Failed to merge $ref', stderr: 'CONFLICT ${conflicts.join(', ')}');
    }

    final sourceTree = _commits[_resolveRef(ref)] ?? const <String, String>{};
    final targetTree = _commits[worktree.head] ?? const <String, String>{};
    final changed = <String>[];
    for (final entry in sourceTree.entries) {
      if (targetTree[entry.key] == entry.value) continue;
      worktree.modified[entry.key] = entry.value;
      worktree.staged.add(entry.key);
      changed.add(entry.key);
    }
    if (strategy == WorkflowGitMergeStrategy.merge && changed.isNotEmpty) {
      await commit(worktreePath, message: message ?? 'Merge $ref');
    }
  }

  @override
  Future<void> mergeAbort(String worktreePath) async {
    events.add('merge --abort');
    _worktree(worktreePath)
      ..conflicts.clear()
      ..staged.clear()
      ..modified.clear();
  }

  @override
  Future<void> resetHard(String worktreePath, String ref) async {
    events.add('reset --hard $ref');
    final worktree = _worktree(worktreePath);
    worktree
      ..head = _resolveRef(ref)
      ..modified.clear()
      ..untracked.clear()
      ..staged.clear()
      ..conflicts.clear();
  }

  String _createCommit(Map<String, String> files) {
    final sha = 'fake-${_nextCommit.toString().padLeft(4, '0')}';
    _nextCommit++;
    _commits[sha] = Map.unmodifiable(files);
    return sha;
  }

  _FakeWorktree _worktree(String worktreePath) {
    final worktree = _worktrees[worktreePath];
    if (worktree == null) {
      throw WorkflowGitException('Unknown fake worktree $worktreePath');
    }
    return worktree;
  }

  String _resolveRef(String ref) {
    if (ref == 'HEAD') {
      throw const WorkflowGitException('HEAD requires a worktree');
    }
    final sha = _refs[ref] ?? ref;
    _requireCommit(sha);
    return sha;
  }

  void _requireCommit(String sha) {
    if (!_commits.containsKey(sha)) {
      throw WorkflowGitException('Unknown fake ref $sha');
    }
  }

  static List<String> _sorted(Iterable<String> values) => values.toList()..sort();
}

final class _FakeWorktree {
  String? branch;
  String head;
  final modified = <String, String>{};
  final untracked = <String, String>{};
  final staged = <String>{};
  final stash = <_FakeStash>[];
  final conflicts = <String>[];

  _FakeWorktree({required this.branch, required this.head});
}

final class _FakeStash {
  final Map<String, String> files;

  _FakeStash(Map<String, String> files) : files = Map.unmodifiable(files);
}
