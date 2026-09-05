part of 'memory_corpus_service.dart';

extension _MemoryCorpusAuthority on MemoryCorpusService {
  Future<_PreparedManifest> _prepareManifestLocked() async {
    final root = _resolveRoot(create: true);
    await _recoverLocked(root);
    final indexFile = File(p.join(root, 'MEMORY.md'));
    final cached = _authenticatedState;
    if (_manifestAuthenticated && cached != null && _readIndexRevisionPrefix(indexFile) == cached.revision) {
      return _PreparedManifest(root: root, state: cached);
    }
    final state = _readState(File(p.join(root, MemoryCorpusService._stateName)));
    final published = MemoryCorpusService._publishedStates[root];
    if (indexFile.existsSync() &&
        state != null &&
        state.hasCompleteManifest &&
        cached != null &&
        published != null &&
        (published.revision != cached.revision || published.fingerprint != cached.fingerprint) &&
        state.collectionId == published.collectionId &&
        state.revision == published.revision &&
        state.fingerprint == published.fingerprint &&
        _readIndexRevisionPrefix(indexFile) == published.revision) {
      _requireManifestMetadataMatch(state, published);
      _manifestAuthenticated = true;
      _authenticatedState = published;
      return _PreparedManifest(root: root, state: published);
    }
    if (indexFile.existsSync() && state != null && state.hasCompleteManifest) {
      if (!_manifestAuthenticated) {
        final scanned = await _scanCorpusState(root);
        if (scanned.collectionId != state.collectionId || scanned.revision != state.revision) {
          throw const MemoryCorpusRecoveryRequired(
            'collection identity or revision changed outside the corpus authority',
          );
        }
        if (scanned.fingerprint != state.fingerprint) {
          return _reconcileScannedLocked(root, state, scanned);
        }
        _requireManifestMetadataMatch(state, scanned);
        _authenticatedState = scanned;
      }
      _manifestAuthenticated = true;
      _authenticatedState ??= state;
      final authenticated = _authenticatedState!;
      final revision = _readIndexRevisionPrefix(indexFile);
      if (revision != authenticated.revision) {
        throw const MemoryCorpusRecoveryRequired(
          'collection identity or revision changed outside the corpus authority',
        );
      }
      return _PreparedManifest(root: root, state: authenticated);
    }
    if (!indexFile.existsSync()) {
      final hasRemnants =
          File(p.join(root, MemoryCorpusService._stateName)).existsSync() ||
          File(p.join(root, 'MEMORY.archive.md')).existsSync() ||
          File(p.join(root, 'learnings.md')).existsSync() ||
          File(p.join(root, 'errors.md')).existsSync() ||
          File(p.join(root, 'MEMORY.audit.md')).existsSync() ||
          await _hasNestedCorpusMembers(root);
      if (hasRemnants) {
        throw const MemoryCorpusRecoveryRequired('MEMORY.md is missing while corpus state or members remain');
      }
      final collectionId = const Uuid().v4();
      final corpus = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 1)),
      );
      final adopted = await _commitInitialCorpusLocked(root, corpus);
      _manifestAuthenticated = true;
      _authenticatedState = adopted;
      return _PreparedManifest(root: root, state: adopted);
    }
    final adopted = await _scanCorpusState(root);
    if (state != null && (state.collectionId != adopted.collectionId || state.revision != adopted.revision)) {
      throw const MemoryCorpusRecoveryRequired('collection identity or revision changed outside the corpus authority');
    }
    _writeManifestState(
      this,
      File(p.join(root, MemoryCorpusService._stateName)),
      adopted.collectionId,
      adopted.revision,
      adopted.fingerprint,
      adopted.members,
    );
    _manifestAuthenticated = true;
    _authenticatedState = adopted;
    return _PreparedManifest(root: root, state: adopted);
  }

  Future<_PreparedManifest> _reconcileScannedLocked(String root, _CorpusState prior, _CorpusState scanned) async {
    if (prior.collectionId != scanned.collectionId || prior.revision != scanned.revision) {
      throw const MemoryCorpusRecoveryRequired('collection identity or revision changed outside the corpus authority');
    }
    final indexPath = p.join(root, 'MEMORY.md');
    final indexBytes = Uint8List.fromList(File(indexPath).readAsBytesSync());
    final index = MemoryCorpusService._codec.parse(utf8.decode(indexBytes));
    if (index is! MemoryIndexDocument) throw const MemoryCorpusRecoveryRequired('MEMORY.md has the wrong role');
    final targetIndex = MemoryIndexDocument(
      metadata: MemoryCollectionMetadata(
        formatVersion: index.metadata.formatVersion,
        collectionId: index.metadata.collectionId,
        revision: scanned.revision + 1,
      ),
      entries: index.entries,
    );
    final targetBytes = Uint8List.fromList(utf8.encode(MemoryCorpusService._codec.render(targetIndex)));
    final targetMembers = <String, _CorpusMemberState>{...scanned.members};
    targetMembers['MEMORY.md'] = _describeMember('MEMORY.md', targetBytes, 0);
    final targetFingerprint = _fingerprintMembers(targetMembers);
    _writeManifestState(
      this,
      File(p.join(root, MemoryCorpusService._stateName)),
      scanned.collectionId,
      scanned.revision,
      scanned.fingerprint,
      scanned.members,
    );
    await _commitSelectedLocked(
      manifest: _PreparedManifest(root: root, state: scanned),
      targetRevision: scanned.revision + 1,
      baseSelection: {'MEMORY.md': indexBytes},
      targetSelection: {'MEMORY.md': targetBytes},
      targetMembers: targetMembers,
      targetFingerprint: targetFingerprint,
    );
    final reconciled = _readState(File(p.join(root, MemoryCorpusService._stateName)));
    if (reconciled == null) throw const MemoryCorpusRecoveryRequired('committed fingerprint state is missing');
    return _PreparedManifest(
      root: root,
      state: reconciled,
      externalChanges: _externalMemberChanges(prior.members, scanned.members),
    );
  }

  MemoryCorpusSelection _readSelectionLocked(_PreparedManifest prepared, Iterable<String> requestedPaths) {
    final inventory = <String, Uint8List>{};
    var bytes = 0;
    for (final path in requestedPaths.toSet().toList()..sort()) {
      final member = prepared.state.members[path];
      if (member == null) continue;
      final length = member.length!;
      if (inventory.length >= MemoryCorpusService.maxCorpusFiles) {
        throw const MemoryCorpusRecoveryRequired('selection exceeds the file-count limit');
      }
      if (bytes + length > MemoryCorpusService.maxCorpusBytes) {
        throw const MemoryCorpusRecoveryRequired('selection exceeds the aggregate-byte limit');
      }
      inventory[path] = _readAuthenticatedMember(prepared.root, prepared.state.members, path);
      bytes += length;
    }
    if (!inventory.containsKey('MEMORY.md')) {
      throw const MemoryCorpusRecoveryRequired('selection is missing MEMORY.md');
    }
    return MemoryCorpusSelection(
      collectionRevision: prepared.state.revision,
      fingerprint: prepared.state.fingerprint,
      corpus: _parseCorpus(inventory),
      paths: Set.unmodifiable(inventory.keys),
    );
  }

  Uint8List _readAuthenticatedMember(String root, Map<String, _CorpusMemberState> members, String path) {
    final member = members[path]!;
    final file = File(p.join(root, path));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file ||
        file.lengthSync() != member.length) {
      throw MemoryCorpusRecoveryRequired('$path changed after manifest authentication');
    }
    _readObserver?.call(path);
    final bytes = Uint8List.fromList(file.readAsBytesSync());
    if (_fingerprintBytes(bytes) != member.fingerprint) {
      throw MemoryCorpusRecoveryRequired('$path changed after manifest authentication');
    }
    return bytes;
  }

  Future<_PreparedManifest?> _canonicalManifestIfPresentLocked(String root, {required bool bootstrap}) async {
    final index = File(p.join(root, 'MEMORY.md'));
    if (!index.existsSync()) return bootstrap ? _prepareManifestLocked() : null;
    final hasState = File(p.join(root, MemoryCorpusService._stateName)).existsSync();
    final handle = index.openSync();
    late final String prefix;
    try {
      prefix = utf8.decode(handle.readSync(64), allowMalformed: true);
    } finally {
      handle.closeSync();
    }
    final hasCanonicalMarker = RegExp(r'^# DartClaw Canonical Memory(?:\r\n|\n|\r|$)').hasMatch(prefix);
    return hasState || hasCanonicalMarker ? _prepareManifestLocked() : null;
  }

  Future<MemoryCorpusChangeResult<T>> _changeSelectedLocked<T>({
    _PreparedManifest? prepared,
    required int expectedRevision,
    required bool Function(MemoryRole? role, String path) include,
    Iterable<String> recordIds = const [],
    Iterable<String> paths = const [],
    required FutureOr<MemoryCorpusChange<T>> Function(CanonicalMemoryCorpus current) prepare,
    bool validateSelection = false,
    FutureOr<void> Function(T value, CanonicalMemoryCorpus committed)? afterCommit,
  }) async {
    final manifest = prepared ?? await _prepareManifestLocked();
    final revision = manifest.state.revision;
    if (revision != expectedRevision) {
      return MemoryCorpusChangeResult<T>(
        wasStale: true,
        wasCommitted: false,
        collectionRevision: revision,
        fingerprint: manifest.state.fingerprint,
      );
    }
    final wantedIds = recordIds.toSet();
    final wantedPaths = paths.map(_normalizeMemberPath).toSet();
    final selectedPaths = manifest.state.members.entries
        .where(
          (entry) =>
              entry.key == 'MEMORY.md' ||
              include(_roleForPath(entry.key), entry.key) ||
              wantedPaths.contains(entry.key) ||
              entry.value.recordIds.any(wantedIds.contains),
        )
        .map((entry) => entry.key)
        .toSet();
    final currentSelection = _readSelectionLocked(manifest, selectedPaths);
    final change = await prepare(currentSelection.corpus);
    final replacement = change.replacement;
    if (replacement == null) {
      return MemoryCorpusChangeResult<T>(
        wasStale: false,
        wasCommitted: false,
        collectionRevision: revision,
        fingerprint: manifest.state.fingerprint,
        value: change.value,
      );
    }
    if (replacement.index.metadata.collectionId != manifest.state.collectionId) {
      throw ArgumentError.value(
        replacement.index.metadata.collectionId,
        'replacement.index.metadata.collectionId',
        'must match the current collection ID',
      );
    }
    final target = _withRevision(replacement, revision + 1);
    if (validateSelection) MemoryCorpusService._validator.validate(target);
    _requireUnselectedIndexRowsUnchanged(currentSelection.corpus, target, wantedIds);
    final targetSelection = target.byteInventory(MemoryCorpusService._codec);
    if (targetSelection.keys.any(
      (path) =>
          path != 'MEMORY.md' &&
          !selectedPaths.contains(path) &&
          !wantedPaths.contains(path) &&
          !include(_roleForPath(path), path),
    )) {
      throw ArgumentError('replacement contains a document outside the selected roles');
    }
    _requireInventoryBounds(
      targetSelection,
      currentInventory: currentSelection.corpus.byteInventory(MemoryCorpusService._codec),
    );
    final targetMembers = _projectMembers(manifest.state.members, selectedPaths, targetSelection);
    _validateProjectedMembers(target, targetMembers);
    // MEMORY.md renders the collection revision into its own bytes, so only the
    // replacement rendered at the current revision can match what is stored.
    final probeMembers = _projectMembers(
      manifest.state.members,
      selectedPaths,
      _withRevision(replacement, revision).byteInventory(MemoryCorpusService._codec),
    );
    if (_fingerprintMembers(probeMembers) == manifest.state.fingerprint) {
      return MemoryCorpusChangeResult<T>(
        wasStale: false,
        wasCommitted: false,
        collectionRevision: revision,
        fingerprint: manifest.state.fingerprint,
        value: change.value,
      );
    }
    final targetFingerprint = _fingerprintMembers(targetMembers);
    try {
      await _commitSelectedLocked(
        manifest: manifest,
        targetRevision: revision + 1,
        baseSelection: currentSelection.corpus.byteInventory(MemoryCorpusService._codec),
        targetSelection: targetSelection,
        targetMembers: targetMembers,
        targetFingerprint: targetFingerprint,
      );
    } on MemoryCorpusSimulatedCrash {
      rethrow;
    } catch (error, stackTrace) {
      final recovered = await _prepareManifestLocked();
      if (recovered.state.revision != revision + 1 || recovered.state.fingerprint != targetFingerprint) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    final commitResult = MemoryCorpusCommitResult.committed(
      collectionRevision: revision + 1,
      fingerprint: targetFingerprint,
    );
    try {
      await _postCommitProjection?.call(
        MemoryCorpusProjection(
          corpus: target,
          priorRecordIds: _corpusRecordIds(currentSelection.corpus),
          isComplete: targetMembers.length == targetSelection.length,
          baseRevision: revision,
          baseFingerprint: manifest.state.fingerprint,
        ),
        commitResult,
      );
      await afterCommit?.call(change.value, target);
    } on Object catch (error) {
      throw MemoryCorpusPostCommitException(result: commitResult, cause: error);
    }
    return MemoryCorpusChangeResult<T>(
      wasStale: false,
      wasCommitted: true,
      collectionRevision: revision + 1,
      fingerprint: targetFingerprint,
      value: change.value,
    );
  }

  void _requireUnselectedIndexRowsUnchanged(
    CanonicalMemoryCorpus current,
    CanonicalMemoryCorpus target,
    Set<String> explicitlySelectedIds,
  ) {
    final selectedIds = <String>{
      ...explicitlySelectedIds,
      for (final topic in current.topics) ...topic.entries.map((entry) => entry.id),
    };
    final targetById = {for (final entry in target.index.entries) entry.id: entry};
    for (final entry in current.index.entries) {
      if (!selectedIds.contains(entry.id) && targetById[entry.id] != entry) {
        throw MemoryCorpusValidationException(['index row outside selected ownership changed: ${entry.id}']);
      }
    }
  }

  Future<_CorpusState> _commitInitialCorpusLocked(String root, CanonicalMemoryCorpus corpus) async {
    final inventory = corpus.byteInventory(MemoryCorpusService._codec);
    final members = {for (final entry in inventory.entries) entry.key: _describeMember(entry.key, entry.value, 0)};
    final fingerprint = _fingerprintMembers(members);
    await _commitSelectedLocked(
      manifest: _PreparedManifest(
        root: root,
        state: _CorpusState(
          collectionId: corpus.index.metadata.collectionId,
          revision: 0,
          fingerprint: _fingerprintMembers(const {}),
          members: const {},
          status: null,
        ),
      ),
      targetRevision: 1,
      baseSelection: const {},
      targetSelection: inventory,
      targetMembers: members,
      targetFingerprint: fingerprint,
    );
    return _authenticatedState ?? (throw const MemoryCorpusRecoveryRequired('committed fingerprint state is missing'));
  }

  Future<void> _commitSelectedLocked({
    required _PreparedManifest manifest,
    required int targetRevision,
    required Map<String, Uint8List> baseSelection,
    required Map<String, Uint8List> targetSelection,
    required Map<String, _CorpusMemberState> targetMembers,
    required String targetFingerprint,
  }) async {
    final changedPaths = <String>{
      ...baseSelection.keys,
      ...targetSelection.keys,
    }.where((path) => !_bytesEqual(baseSelection[path], targetSelection[path])).toList()..sort();
    if (changedPaths.isEmpty) return;
    if (changedPaths.remove('MEMORY.md')) changedPaths.add('MEMORY.md');
    final root = manifest.root;
    final transactionDir = Directory(p.join(root, MemoryCorpusService._transactionDirName));
    if (transactionDir.existsSync()) transactionDir.deleteSync(recursive: true);
    transactionDir.createSync();
    final entries = <_TransactionEntry>[];
    try {
      for (var index = 0; index < changedPaths.length; index++) {
        final relativePath = changedPaths[index];
        final stagePath = p.join(transactionDir.path, 'stage-$index');
        final backupPath = p.join(transactionDir.path, 'backup-$index');
        final target = File(p.join(root, relativePath));
        final targetBytes = targetSelection[relativePath];
        if (targetBytes != null) {
          _writeBytes(File(stagePath), targetBytes);
          await _transition(MemoryCorpusTransition.stageWritten, relativePath);
        }
        final existed = FileSystemEntity.typeSync(target.path, followLinks: false) == FileSystemEntityType.file;
        if (existed) {
          _readObserver?.call(relativePath);
          _writeBytes(File(backupPath), target.readAsBytesSync());
          await _transition(MemoryCorpusTransition.backupWritten, relativePath);
        }
        entries.add(
          _TransactionEntry(
            path: relativePath,
            stagePath: targetBytes == null ? null : p.basename(stagePath),
            backupPath: existed ? p.basename(backupPath) : null,
          ),
        );
      }
      final journal = _TransactionJournal(
        collectionId: manifest.state.collectionId,
        baseRevision: manifest.state.revision,
        targetRevision: targetRevision,
        baseFingerprint: manifest.state.fingerprint,
        targetFingerprint: targetFingerprint,
        entries: entries,
      );
      await atomicWriteJson(File(p.join(root, MemoryCorpusService._journalName)), journal.toJson());
      for (final entry in entries) {
        if (entry.path == 'MEMORY.md') await _transition(MemoryCorpusTransition.beforeCommitMarker, entry.path);
        _replaceFromTransaction(root, transactionDir.path, entry);
        await _transition(MemoryCorpusTransition.targetReplaced, entry.path);
        if (entry.path == 'MEMORY.md') await _transition(MemoryCorpusTransition.commitMarkerReplaced, entry.path);
      }
      for (final path in changedPaths) {
        final member = targetMembers[path];
        if (member == null) continue;
        final file = File(p.join(root, path));
        targetMembers[path] = _CorpusMemberState(
          fingerprint: member.fingerprint,
          length: member.length,
          modifiedMicros: file.lastModifiedSync().microsecondsSinceEpoch,
          role: member.role,
          recordIds: member.recordIds,
          recordCount: member.recordCount,
          oldestMicros: member.oldestMicros,
          newestMicros: member.newestMicros,
        );
      }
      _writeManifestState(
        this,
        File(p.join(root, MemoryCorpusService._stateName)),
        manifest.state.collectionId,
        targetRevision,
        targetFingerprint,
        targetMembers,
      );
      await _transition(MemoryCorpusTransition.fingerprintRecorded, MemoryCorpusService._stateName);
      await _transition(MemoryCorpusTransition.beforeCleanup, MemoryCorpusService._journalName);
      _cleanupTransaction(root);
    } on MemoryCorpusSimulatedCrash {
      rethrow;
    } catch (error, stackTrace) {
      try {
        await _recoverLocked(root);
        if (!File(p.join(root, MemoryCorpusService._journalName)).existsSync()) _cleanupTransaction(root);
      } catch (recoveryError) {
        Error.throwWithStackTrace(
          StateError('Memory corpus commit failed: $error; recovery failed: $recoveryError'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _recoverLocked(String root) async {
    final journalFile = File(p.join(root, MemoryCorpusService._journalName));
    if (!journalFile.existsSync()) return;
    final journal = _TransactionJournal.fromJson(_readJsonMap(journalFile));
    final transactionDir = p.join(root, MemoryCorpusService._transactionDirName);
    final marker = File(p.join(root, 'MEMORY.md'));
    final markerRevision = _readIndexRevisionPrefix(marker);
    final committed = markerRevision == journal.targetRevision;
    final priorState = _readState(File(p.join(root, MemoryCorpusService._stateName)));
    if (committed) {
      for (final entry in journal.entries) {
        _replaceFromTransaction(root, transactionDir, entry);
      }
    } else {
      for (final entry in journal.entries.reversed) {
        final target = File(p.join(root, entry.path));
        final backupName = entry.backupPath;
        if (backupName == null) {
          if (target.existsSync()) target.deleteSync();
        } else {
          final backup = File(p.join(transactionDir, backupName));
          if (!backup.existsSync()) throw const MemoryCorpusRecoveryRequired('transaction backup is missing');
          _writeBytes(target, backup.readAsBytesSync());
        }
      }
    }
    final revision = committed ? journal.targetRevision : journal.baseRevision;
    if (revision == 0) {
      _cleanupTransaction(root);
      return;
    }
    final fingerprint = committed ? journal.targetFingerprint : journal.baseFingerprint;
    if (_readIndexRevisionPrefix(marker) != revision) {
      throw const MemoryCorpusRecoveryRequired('transaction artifacts do not match the marker revision');
    }
    late final String collectionId;
    late final Map<String, _CorpusMemberState> members;
    if (priorState?.hasCompleteManifest ?? false) {
      collectionId = committed ? journal.collectionId : priorState!.collectionId;
      members = <String, _CorpusMemberState>{...priorState!.members};
      for (final entry in journal.entries) {
        final target = File(p.join(root, entry.path));
        if (!target.existsSync()) {
          members.remove(entry.path);
        } else {
          final bytes = Uint8List.fromList(target.readAsBytesSync());
          members[entry.path] = _describeMember(entry.path, bytes, target.lastModifiedSync().microsecondsSinceEpoch);
        }
      }
    } else {
      final scanned = await _scanCorpusState(root);
      collectionId = scanned.collectionId;
      members = scanned.members;
    }
    if (collectionId != journal.collectionId || _fingerprintMembers(members) != fingerprint) {
      throw const MemoryCorpusRecoveryRequired('transaction artifacts do not match the marker');
    }
    _writeManifestState(
      this,
      File(p.join(root, MemoryCorpusService._stateName)),
      collectionId,
      revision,
      fingerprint,
      members,
    );
    _cleanupTransaction(root);
  }

  CanonicalMemoryCorpus _parseCorpus(Map<String, Uint8List> inventory) {
    CanonicalMemoryDocument parse(String path) {
      final bytes = inventory[path];
      if (bytes == null) throw MemoryCorpusRecoveryRequired('missing required $path');
      try {
        return MemoryCorpusService._codec.parse(utf8.decode(bytes));
      } on Object catch (error) {
        throw MemoryCorpusRecoveryRequired('$path is invalid: $error');
      }
    }

    final index = parse('MEMORY.md');
    if (index is! MemoryIndexDocument) throw const MemoryCorpusRecoveryRequired('MEMORY.md has the wrong role');
    final topics = <MemoryTopicDocument>[];
    final observations = <MemoryObservationDocument>[];
    final verbatim = <VerbatimMemoryMember>[];
    MemoryArchiveDocument? archive;
    MemoryLearningDocument? learnings;
    MemoryErrorDocument? errors;
    MemoryAuditDocument? audit;
    for (final path in inventory.keys) {
      if (path == 'MEMORY.md') continue;
      if (path.startsWith('memory/legacy/')) {
        verbatim.add(VerbatimMemoryMember(path: path, bytes: inventory[path]!));
        continue;
      }
      final document = parse(path);
      void requireSoleMember(String expected, Object? existing) {
        if (path != expected || existing != null) {
          throw MemoryCorpusRecoveryRequired('$path is not the unique ${document.role.wireName} document');
        }
      }

      switch (document) {
        case MemoryTopicDocument():
          if (path != 'memory/topics/${document.topic}.md') {
            throw MemoryCorpusRecoveryRequired('$path does not match topic ${document.topic}');
          }
          topics.add(document);
        case MemoryArchiveDocument():
          requireSoleMember('MEMORY.archive.md', archive);
          archive = document;
        case MemoryObservationDocument():
          if (path != 'memory/${document.date}.md') {
            throw MemoryCorpusRecoveryRequired('$path does not match observation date ${document.date}');
          }
          observations.add(document);
        case MemoryLearningDocument():
          requireSoleMember('learnings.md', learnings);
          learnings = document;
        case MemoryErrorDocument():
          requireSoleMember('errors.md', errors);
          errors = document;
        case MemoryAuditDocument():
          requireSoleMember('MEMORY.audit.md', audit);
          audit = document;
        case MemoryIndexDocument():
          throw MemoryCorpusRecoveryRequired('$path is an unexpected index document');
      }
    }
    return CanonicalMemoryCorpus(
      index: index,
      topics: topics,
      archive: archive,
      observations: observations,
      learnings: learnings,
      errors: errors,
      audit: audit,
      verbatimMembers: verbatim,
    );
  }

  String _resolveRoot({required bool create}) {
    if (_root case final root?) return root;
    final directory = Directory(p.absolute(workspaceDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) throw FileSystemException('Workspace does not exist', directory.path);
      directory.createSync(recursive: true);
    } else if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root does not resolve to a directory', directory.path);
    }
    return _root = p.normalize(resolved);
  }

  Future<void> _transition(MemoryCorpusTransition transition, String path) async {
    final hook = _transitionHook;
    if (hook != null) await hook(transition, path);
  }
}

Map<String, _CorpusMemberState> _projectMembers(
  Map<String, _CorpusMemberState> current,
  Set<String> selectedPaths,
  Map<String, Uint8List> selection,
) {
  final members = <String, _CorpusMemberState>{...current};
  for (final path in selectedPaths) {
    if (!selection.containsKey(path)) members.remove(path);
  }
  for (final entry in selection.entries) {
    members[entry.key] = _describeMember(entry.key, entry.value, 0);
  }
  return members;
}

CanonicalMemoryCorpus _withRevision(CanonicalMemoryCorpus corpus, int revision) => CanonicalMemoryCorpus(
  index: MemoryIndexDocument(
    metadata: MemoryCollectionMetadata(
      formatVersion: corpus.index.metadata.formatVersion,
      collectionId: corpus.index.metadata.collectionId,
      revision: revision,
    ),
    entries: corpus.index.entries,
  ),
  topics: corpus.topics,
  archive: corpus.archive,
  observations: corpus.observations,
  learnings: corpus.learnings,
  errors: corpus.errors,
  audit: corpus.audit,
  verbatimMembers: corpus.verbatimMembers,
);
Iterable<String> _corpusRecordIds(CanonicalMemoryCorpus corpus) sync* {
  yield* corpus.topics.expand((topic) => topic.entries).map((entry) => entry.id);
  yield* (corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]).map((entry) => entry.id);
  yield* corpus.observations.expand((document) => document.observations).map((entry) => entry.id);
  yield* (corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[]).map((entry) => entry.id);
  // Errors are corpus members but not index-eligible: their IDs must not reach
  // the derived search index's replace-by-prior-ID reconciliation.
}

List<MemoryCorpusExternalChange> _externalMemberChanges(
  Map<String, _CorpusMemberState> previous,
  Map<String, _CorpusMemberState> current,
) {
  final paths = <String>{...previous.keys, ...current.keys}.toList()..sort();
  return paths
      .where((path) => previous[path]?.fingerprint != current[path]?.fingerprint)
      .map(
        (path) =>
            MemoryCorpusExternalChange(role: _roleForPath(path), locator: path, wasRemoved: current[path] == null),
      )
      .toList();
}

MemoryRole? _roleForPath(String path) {
  if (path == 'MEMORY.md') return MemoryRole.indexDocument;
  if (path == 'MEMORY.archive.md') return MemoryRole.archive;
  if (path == 'learnings.md') return MemoryRole.learning;
  if (path == 'errors.md') return MemoryRole.error;
  if (path == 'MEMORY.audit.md') return MemoryRole.audit;
  if (path.startsWith('memory/topics/')) return MemoryRole.topic;
  if (RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path)) return MemoryRole.observation;
  return null;
}

/// The one containment rule for a corpus-relative path: the normalized path, or
/// `null` when it is absolute, Windows-shaped, or escapes the corpus root.
///
/// Callers differ only in what they throw. A tightening applied to one copy of
/// this rule and not the other would let the manifest transaction path and the
/// member path admit different sets.
String? _containedCorpusPath(String path) {
  if (p.isAbsolute(path) || path.contains(r'\')) return null;
  final normalized = p.posix.normalize(path);
  if (normalized == '.' || normalized == '..' || normalized.startsWith('../')) return null;
  return normalized;
}

String _normalizeMemberPath(String path) =>
    _containedCorpusPath(path) ?? (throw ArgumentError.value(path, 'path', 'must stay inside the corpus'));

void _requireInventoryBounds(Map<String, Uint8List> inventory, {Map<String, Uint8List> currentInventory = const {}}) {
  for (final entry in inventory.entries) {
    final limit = RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(entry.key)
        ? MemoryResourceLimits.observationPartitionBytes
        : MemoryResourceLimits.sourceBytes;
    if (entry.value.length > limit) {
      throw MemoryResourceLimitException(
        role: _roleForPath(entry.key) ?? MemoryRole.topic,
        locator: entry.key,
        observedBytes: entry.value.length,
        limitBytes: limit,
        currentBytes: currentInventory[entry.key]?.length ?? 0,
      );
    }
  }
}

String _fingerprint(Map<String, Uint8List> inventory) {
  return _fingerprintMembers({
    for (final entry in inventory.entries)
      entry.key: _CorpusMemberState(
        fingerprint: _fingerprintBytes(entry.value),
        length: entry.value.length,
        modifiedMicros: 0,
      ),
  });
}

String _fingerprintMembers(Map<String, _CorpusMemberState> members) {
  var hash = 0xcbf29ce484222325;
  final paths = members.keys.toList()..sort();
  for (final path in paths) {
    final pathBytes = utf8.encode(path);
    for (final byte in _lengthBytes(pathBytes.length)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    for (final byte in pathBytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    final member = members[path]!;
    for (final byte in _lengthBytes(member.length!)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    for (final byte in utf8.encode(member.fingerprint)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

Iterable<int> _lengthBytes(int value) sync* {
  var remaining = value;
  do {
    yield remaining & 0xff;
    remaining >>= 8;
  } while (remaining > 0);
}

String _fingerprintBytes(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

bool _bytesEqual(List<int>? left, List<int>? right) =>
    left == null || right == null ? left == right : left.length == right.length && _indexedEqual(left, right);

bool _indexedEqual<T>(List<T> left, List<T> right) {
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

_CorpusMemberState _describeMember(String path, Uint8List bytes, int modifiedMicros) {
  if (path.startsWith('memory/legacy/')) {
    return _CorpusMemberState(
      fingerprint: _fingerprintBytes(bytes),
      length: bytes.length,
      modifiedMicros: modifiedMicros,
      role: 'legacy',
      recordCount: 0,
    );
  }
  late final CanonicalMemoryDocument document;
  try {
    document = MemoryCorpusService._codec.parse(utf8.decode(bytes));
  } on Object catch (error) {
    throw MemoryCorpusRecoveryRequired('$path is invalid: $error');
  }
  final (role, ids, times) = switch (document) {
    MemoryIndexDocument() => (MemoryRole.indexDocument, document.entries.map((entry) => entry.id), const <DateTime>[]),
    MemoryTopicDocument() => (
      MemoryRole.topic,
      document.entries.map((entry) => entry.id),
      document.entries.map((entry) => entry.updated),
    ),
    MemoryArchiveDocument() => (
      MemoryRole.archive,
      document.entries.map((entry) => entry.id),
      document.entries.map((entry) => entry.updated),
    ),
    MemoryObservationDocument() => (
      MemoryRole.observation,
      document.observations.map((entry) => entry.id),
      document.observations.map((entry) => entry.recorded),
    ),
    MemoryLearningDocument() => (
      MemoryRole.learning,
      document.entries.map((entry) => entry.id),
      document.entries.map((entry) => entry.updated),
    ),
    MemoryErrorDocument() => (
      MemoryRole.error,
      document.entries.map((entry) => entry.id),
      document.entries.map((entry) => entry.updated),
    ),
    MemoryAuditDocument() => (
      MemoryRole.audit,
      document.records.map((entry) => entry.entryId),
      document.records.map((entry) => entry.deletedAt),
    ),
    _ => throw MemoryCorpusRecoveryRequired('$path has an unsupported canonical role'),
  };
  final expectedPath = switch (document) {
    MemoryIndexDocument() => 'MEMORY.md',
    MemoryTopicDocument() => 'memory/topics/${document.topic}.md',
    MemoryArchiveDocument() => 'MEMORY.archive.md',
    MemoryObservationDocument() => 'memory/${document.date}.md',
    MemoryLearningDocument() => 'learnings.md',
    MemoryErrorDocument() => 'errors.md',
    MemoryAuditDocument() => 'MEMORY.audit.md',
    _ => path,
  };
  if (path != expectedPath) throw MemoryCorpusRecoveryRequired('$path has the wrong canonical locator');
  final recordIds = ids.toList(growable: false);
  final micros = times.map((value) => value.toUtc().microsecondsSinceEpoch).toList(growable: false);
  return _CorpusMemberState(
    fingerprint: _fingerprintBytes(bytes),
    length: bytes.length,
    modifiedMicros: modifiedMicros,
    role: role.wireName,
    recordIds: recordIds,
    recordCount: recordIds.length,
    oldestMicros: micros.isEmpty ? null : micros.reduce((left, right) => left < right ? left : right),
    newestMicros: micros.isEmpty ? null : micros.reduce((left, right) => left > right ? left : right),
  );
}

void _validateProjectedMembers(CanonicalMemoryCorpus selected, Map<String, _CorpusMemberState> members) {
  final errors = <String>[];
  final activeIds = <String>{};
  final nonActiveIds = <String>{};
  final retiredIds = <String>{};
  for (final member in members.values) {
    final ids = member.recordIds;
    final unique = ids.toSet();
    if (unique.length != ids.length) errors.add('duplicate ${member.role} record ID');
    switch (member.role) {
      case 'topic':
        for (final id in ids) {
          if (!activeIds.add(id)) errors.add('duplicate active entry ID: $id');
        }
      case 'archive' || 'observation' || 'learning' || 'error':
        for (final id in ids) {
          if (!nonActiveIds.add(id) || activeIds.contains(id)) errors.add('duplicate canonical record ID: $id');
        }
      case 'audit':
        retiredIds.addAll(ids);
    }
  }
  for (final id in activeIds) {
    if (nonActiveIds.contains(id)) errors.add('entry ID exists in active and non-active documents: $id');
  }
  for (final id in retiredIds) {
    if (activeIds.contains(id) || nonActiveIds.contains(id)) {
      errors.add('retired entry ID is present in the canonical corpus: $id');
    }
  }
  final indexIds = selected.index.entries.map((entry) => entry.id).toList(growable: false);
  if (indexIds.toSet().length != indexIds.length) errors.add('duplicate index entry ID');
  if (indexIds.toSet().difference(activeIds).isNotEmpty || activeIds.difference(indexIds.toSet()).isNotEmpty) {
    errors.add('index entries do not match active topic records');
  }
  final indexById = {for (final row in selected.index.entries) row.id: row};
  for (final topic in selected.topics) {
    for (final entry in topic.entries) {
      final row = indexById[entry.id];
      if (row == null ||
          row.topic != entry.topic ||
          row.locator != entry.id ||
          row.revision != entry.revision ||
          row.summary != entry.summary ||
          row.updated != entry.updated) {
        errors.add('index metadata mismatch for ${entry.id}');
      }
    }
  }
  if (errors.isNotEmpty) throw MemoryCorpusValidationException(errors);
}

_CorpusState? _readState(File file) {
  if (!file.existsSync()) return null;
  final json = _readJsonMap(file);
  final revision = json['observedRevision'];
  final collectionId = json['observedCollectionId'];
  final fingerprint = json['fingerprint'];
  final members = json['members'];
  if (revision is! int ||
      revision < 1 ||
      collectionId is! String ||
      fingerprint is! String ||
      members is! Map<String, dynamic>) {
    throw const MemoryCorpusRecoveryRequired('committed fingerprint state is malformed');
  }
  final parsedMembers = <String, _CorpusMemberState>{};
  for (final entry in members.entries) {
    final value = entry.value;
    if (value is String) {
      parsedMembers[entry.key] = _CorpusMemberState(fingerprint: value);
      continue;
    }
    if (value is! Map<String, dynamic> ||
        value['fingerprint'] is! String ||
        value['length'] is! int ||
        (value['length'] as int) < 0 ||
        value['modifiedMicros'] is! int ||
        value['recordCount'] is! int ||
        (value['recordCount'] as int) < 0 ||
        value['role'] is! String ||
        !const {
          'index',
          'topic',
          'archive',
          'observation',
          'learning',
          'error',
          'audit',
          'legacy',
        }.contains(value['role'])) {
      throw const MemoryCorpusRecoveryRequired('committed fingerprint state is malformed');
    }
    parsedMembers[entry.key] = _CorpusMemberState(
      fingerprint: value['fingerprint'] as String,
      length: value['length'] as int,
      modifiedMicros: value['modifiedMicros'] as int,
      role: value['role'] as String?,
      recordIds: switch (value['recordIds']) {
        final List<dynamic> ids when ids.every((id) => id is String) => ids.cast<String>(),
        _ => const [],
      },
      recordCount: value['recordCount'] as int?,
      oldestMicros: value['oldestMicros'] as int?,
      newestMicros: value['newestMicros'] as int?,
    );
  }
  return _CorpusState(
    collectionId: collectionId,
    revision: revision,
    fingerprint: fingerprint,
    members: Map.unmodifiable(parsedMembers),
    status: switch (json['status']) {
      final Map<String, dynamic> value => _parseStatus(value),
      null => null,
      _ => throw const MemoryCorpusRecoveryRequired('committed fingerprint state is malformed'),
    },
  );
}

MemoryCorpusStatusSnapshot _parseStatus(Map<String, dynamic> json) {
  int? count(String key) => switch (json[key]) {
    null => null,
    final int value when value >= 0 => value,
    _ => throw const FormatException('Malformed persisted memory status'),
  };
  DateTime? timestamp(String key) => switch (json[key]) {
    null => null,
    final String value => DateTime.parse(value).toUtc(),
    _ => throw const FormatException('Malformed persisted memory status'),
  };
  final revision = json['collectionRevision'];
  final fingerprint = json['collectionFingerprint'];
  final locators = json['opaqueLegacyLocators'];
  final migration = json['migrationState'];
  if (revision is! int ||
      revision < 1 ||
      fingerprint is! String ||
      locators is! List ||
      locators.any((value) => value is! String) ||
      migration is! String ||
      !const {'migrated', 'notApplicable'}.contains(migration)) {
    throw const FormatException('Malformed persisted memory status');
  }
  for (final key in ['migrationSnapshotPath', 'migrationAction']) {
    if (json[key] != null && json[key] is! String) throw const FormatException('Malformed persisted memory status');
  }
  return MemoryCorpusStatusSnapshot(
    collectionRevision: revision,
    collectionFingerprint: fingerprint,
    curatedEntryCount: count('curatedEntryCount'),
    topicCount: count('topicCount'),
    archiveEntryCount: count('archiveEntryCount'),
    observationEntryCount: count('observationEntryCount'),
    learningEntryCount: count('learningEntryCount'),
    // A state file written before the error role existed omits the key; it
    // predates any error member, so its count is zero. Reading it as null would
    // make every such manifest mismatch its own fresh scan and fail startup.
    errorEntryCount: count('errorEntryCount') ?? 0,
    observationUsageBytes: count('observationUsageBytes'),
    observationOldest: timestamp('observationOldest'),
    observationNewest: timestamp('observationNewest'),
    opaqueLegacyLocators: locators.cast<String>(),
    migrationState: migration,
    migrationSnapshotPath: json['migrationSnapshotPath'] as String?,
    migrationAction: json['migrationAction'] as String?,
  );
}

void _requireManifestMetadataMatch(_CorpusState persisted, _CorpusState scanned) {
  Map<String, Object?> stable(MemoryCorpusStatusSnapshot value) => Map.of(value.toJson())
    ..remove('migrationState')
    ..remove('migrationSnapshotPath')
    ..remove('migrationAction');
  if (persisted.members.length != scanned.members.length ||
      persisted.status == null ||
      jsonEncode(stable(persisted.status!)) != jsonEncode(stable(scanned.status!))) {
    throw const MemoryCorpusRecoveryRequired('committed fingerprint metadata is inconsistent');
  }
  for (final entry in scanned.members.entries) {
    final value = persisted.members[entry.key];
    final scannedValue = entry.value;
    if (value == null ||
        value.fingerprint != scannedValue.fingerprint ||
        value.length != scannedValue.length ||
        value.role != scannedValue.role ||
        value.recordCount != scannedValue.recordCount ||
        value.oldestMicros != scannedValue.oldestMicros ||
        value.newestMicros != scannedValue.newestMicros ||
        (value.recordIds.length != scannedValue.recordIds.length ||
            !_indexedEqual(value.recordIds, scannedValue.recordIds))) {
      throw const MemoryCorpusRecoveryRequired('committed fingerprint metadata is inconsistent');
    }
  }
}

void _writeManifestState(
  MemoryCorpusService service,
  File file,
  String collectionId,
  int revision,
  String fingerprint,
  Map<String, _CorpusMemberState> members,
) {
  final root = file.parent.path;
  final status = _statusFromMembers(root, revision, fingerprint, members);
  secureWriteFileSync(
    file,
    jsonEncode({
      'observedCollectionId': collectionId,
      'observedRevision': revision,
      'fingerprint': fingerprint,
      'members': {for (final entry in members.entries) entry.key: entry.value.toJson()},
      'status': status.toJson(),
    }),
    restrictPermissions: false,
  );
  final state = _CorpusState(
    collectionId: collectionId,
    revision: revision,
    fingerprint: fingerprint,
    members: Map.unmodifiable(members),
    status: status,
  );
  service._authenticatedState = state;
  service._manifestAuthenticated = true;
  MemoryCorpusService._publishedStates[root] = state;
}

MemoryCorpusStatusSnapshot _statusFromMembers(
  String root,
  int revision,
  String fingerprint,
  Map<String, _CorpusMemberState> members,
) {
  final snapshotPath = p.join(root, '.dartclaw-memory-migration-snapshot');
  final migrated = Directory(snapshotPath).existsSync();
  final observations = members.entries.where((entry) => entry.value.role == MemoryRole.observation.wireName).toList();
  int count(MemoryRole role) => members.values
      .where((member) => member.role == role.wireName)
      .fold(0, (total, member) => total + (member.recordCount ?? 0));
  final times = observations.expand((entry) => [entry.value.oldestMicros, entry.value.newestMicros]).whereType<int>();
  final oldest = times.fold<int?>(null, (current, value) => current == null || value < current ? value : current);
  final newest = times.fold<int?>(null, (current, value) => current == null || value > current ? value : current);
  return MemoryCorpusStatusSnapshot(
    collectionRevision: revision,
    collectionFingerprint: fingerprint,
    curatedEntryCount: count(MemoryRole.topic),
    topicCount: members.values.where((member) => member.role == MemoryRole.topic.wireName).length,
    archiveEntryCount: count(MemoryRole.archive),
    observationEntryCount: observations.fold<int>(0, (total, entry) => total + (entry.value.recordCount ?? 0)),
    learningEntryCount: count(MemoryRole.learning),
    errorEntryCount: count(MemoryRole.error),
    observationUsageBytes: observations.fold<int>(0, (total, entry) => total + (entry.value.length ?? 0)),
    observationOldest: oldest == null ? null : DateTime.fromMicrosecondsSinceEpoch(oldest, isUtc: true),
    observationNewest: newest == null ? null : DateTime.fromMicrosecondsSinceEpoch(newest, isUtc: true),
    opaqueLegacyLocators: (members.keys.where((path) => path.startsWith('memory/legacy/')).toList()..sort()),
    migrationState: migrated ? 'migrated' : 'notApplicable',
    migrationSnapshotPath: migrated ? snapshotPath : null,
    migrationAction: migrated ? 'Inspect the retained snapshot before removing it manually.' : null,
  );
}

Future<bool> _contentMatches(String root, Map<String, _CorpusMemberState> expected) async {
  var actualCount = 0;
  var files = 0;
  var bytes = 0;
  await for (final path in _corpusPaths(root)) {
    actualCount++;
    if (!expected.containsKey(path)) return false;
    final file = File(p.join(root, path));
    final member = expected[path]!;
    if (file.lengthSync() != member.length) {
      return false;
    }
    if (files >= MemoryCorpusService.maxCorpusFiles || bytes + member.length! > MemoryCorpusService.maxCorpusBytes) {
      files = 0;
      bytes = 0;
    }
    files++;
    bytes += member.length!;
    if (_fingerprintFile(file) != member.fingerprint) {
      return false;
    }
  }
  return actualCount == expected.length;
}

String _fingerprintFile(File file) {
  var hash = 0xcbf29ce484222325;
  final handle = file.openSync();
  try {
    final buffer = Uint8List(64 * 1024);
    while (true) {
      final count = handle.readIntoSync(buffer);
      if (count == 0) break;
      for (var index = 0; index < count; index++) {
        hash ^= buffer[index];
        hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
      }
    }
  } finally {
    handle.closeSync();
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

Stream<String> _corpusPaths(String root) async* {
  for (final path in const ['MEMORY.md', 'MEMORY.archive.md', 'errors.md', 'learnings.md', 'MEMORY.audit.md']) {
    final type = FileSystemEntity.typeSync(p.join(root, path), followLinks: false);
    if (type == FileSystemEntityType.file) yield path;
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) {
      throw MemoryCorpusRecoveryRequired('$path is not a regular file');
    }
  }
  final memoryDir = Directory(p.join(root, 'memory'));
  final memoryType = FileSystemEntity.typeSync(memoryDir.path, followLinks: false);
  if (memoryType == FileSystemEntityType.notFound) return;
  if (memoryType != FileSystemEntityType.directory) {
    throw const MemoryCorpusRecoveryRequired('memory is not a regular directory');
  }
  Stream<String> visit(Directory directory, {required bool recursive, required bool Function(String) accepts}) async* {
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw MemoryCorpusRecoveryRequired('${p.relative(directory.path, from: root)} is not a regular directory');
    }
    await for (final entity in directory.list(recursive: recursive, followLinks: false)) {
      if (entity is! File) continue;
      final path = p.posix.joinAll(p.split(p.relative(entity.path, from: root)));
      if (accepts(path)) yield path;
    }
  }

  yield* visit(
    memoryDir,
    recursive: false,
    accepts: (path) => RegExp(r'^memory/\d{4}-\d{2}-\d{2}\.md$').hasMatch(path),
  );
  yield* visit(
    Directory(p.join(root, 'memory', 'topics')),
    recursive: false,
    accepts: (path) => path.startsWith('memory/topics/') && path.endsWith('.md'),
  );
  yield* visit(
    Directory(p.join(root, 'memory', 'legacy')),
    recursive: true,
    accepts: (path) => path.startsWith('memory/legacy/'),
  );
}

Map<String, dynamic> _readJsonMap(File file) {
  try {
    final value = jsonDecode(file.readAsStringSync());
    if (value is Map<String, dynamic>) return value;
  } on Object {
    // Converted to one stable recovery error below.
  }
  throw MemoryCorpusRecoveryRequired('invalid coordination state: ${p.basename(file.path)}');
}

int? _readIndexRevisionPrefix(File file) {
  if (!file.existsSync()) return null;
  final handle = file.openSync();
  try {
    final prefix = utf8.decode(handle.readSync(256), allowMalformed: true);
    final match = RegExp(r'^Collection-Revision: (\d+)$', multiLine: true).firstMatch(prefix);
    return match == null ? null : int.tryParse(match.group(1)!);
  } finally {
    handle.closeSync();
  }
}

void _replaceFromTransaction(String root, String transactionDir, _TransactionEntry entry) {
  final target = File(p.join(root, entry.path));
  _ensureContainedParent(root, entry.path);
  final stageName = entry.stagePath;
  if (stageName == null) {
    if (target.existsSync()) target.deleteSync();
    return;
  }
  final stage = File(p.join(transactionDir, stageName));
  if (!stage.existsSync()) throw const MemoryCorpusRecoveryRequired('transaction stage is missing');
  _writeBytes(target, stage.readAsBytesSync());
}

void _writeBytes(File target, List<int> bytes) {
  final temp = File('${target.path}.replace');
  try {
    final handle = temp.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeFromSync(bytes);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    temp.renameSync(target.path);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

void _cleanupTransaction(String root) {
  final journal = File(p.join(root, MemoryCorpusService._journalName));
  if (journal.existsSync()) journal.deleteSync();
  final directory = Directory(p.join(root, MemoryCorpusService._transactionDirName));
  if (directory.existsSync()) directory.deleteSync(recursive: true);
}

Future<bool> _hasNestedCorpusMembers(String root) async {
  await for (final path in _corpusPaths(root)) {
    if (path.startsWith('memory/')) return true;
  }
  return false;
}

extension _MemoryCorpusLegacy on MemoryCorpusService {
  void _replaceLegacyFiles(String root, Map<String, Uint8List?> writes) {
    final paths = writes.keys.toList()
      ..sort((left, right) {
        if (left == 'MEMORY.md') return 1;
        if (right == 'MEMORY.md') return -1;
        return left.compareTo(right);
      });
    final before = <String, Uint8List?>{};
    final replaced = <String>[];
    try {
      for (final path in paths) {
        _ensureContainedParent(root, path);
        final target = File(p.join(root, path));
        before[path] = target.existsSync() ? Uint8List.fromList(target.readAsBytesSync()) : null;
        final bytes = writes[path];
        if (bytes == null) {
          if (target.existsSync()) target.deleteSync();
        } else {
          final writer = _legacyWriteForTesting;
          if (writer == null) {
            _writeBytes(target, bytes);
          } else {
            writer(target, bytes);
          }
        }
        replaced.add(path);
      }
    } catch (error, stackTrace) {
      Object? rollbackError;
      for (final path in replaced.reversed) {
        try {
          final target = File(p.join(root, path));
          final bytes = before[path];
          if (bytes == null) {
            if (target.existsSync()) target.deleteSync();
          } else {
            final writer = _legacyWriteForTesting;
            if (writer == null) {
              _writeBytes(target, bytes);
            } else {
              writer(target, bytes);
            }
          }
        } on Object catch (candidate) {
          rollbackError ??= candidate;
        }
      }
      if (rollbackError != null) {
        Error.throwWithStackTrace(
          StateError('Corpus file mutation failed: $error; rollback failed: $rollbackError'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

void _ensureContainedParent(String root, String relativePath) {
  var current = root;
  final segments = p.posix.split(relativePath);
  for (final segment in segments.take(segments.length - 1)) {
    current = p.join(current, segment);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      Directory(current).createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Unexpected corpus parent entity', current);
    }
  }
}
