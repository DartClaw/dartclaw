part of 'conversation_service.dart';

extension _ConversationServicePersistence on ConversationService {
  Future<void> _trackWork(Future<void> work) {
    late final Future<void> pending;
    pending = work.whenComplete(() => _pendingWork.remove(pending));
    _pendingWork.add(pending);
    return pending;
  }

  void _requireAdmission() {
    if (_stopping) {
      throw const ConversationMutationException(503, 'SERVER_STOPPING', 'The server is shutting down');
    }
  }

  Future<void> _observeOutcome(String sessionId, String turnId) async {
    final outcome = await turns.waitForOutcome(sessionId, turnId);
    await mutations.run(sessionId, () async {
      var state = await sessions.getConversationState(sessionId);
      final current = _submissionForTurn(state, turnId);
      if (current == null || _isTerminal(current.workState)) return;
      final terminal = current.copyWith(
        workState: switch (outcome.status) {
          TurnStatus.completed => ConversationWorkState.completed,
          TurnStatus.failed => ConversationWorkState.failed,
          TurnStatus.cancelled => ConversationWorkState.cancelled,
        },
        updatedAt: clock().toUtc(),
      );
      state = _retainToolOutcome(state, current, outcome);
      state = state.put(terminal);
      if (outcome.status != TurnStatus.completed || _stopping) state = _holdPending(state);
      await _writeWorkRecords(sessionId, terminal, allowUpdate: true);
      await _writeQueueRecords(sessionId, state);
      await _persist(sessionId, state, terminal, 'turn_settled');
      if (outcome.status == TurnStatus.completed) {
        if (!_stopping) unawaited(_trackWork(generateTitleAfterFirstExchange(sessionId)));
        final queued = state.queue.where((item) => item.workState == ConversationWorkState.queued).firstOrNull;
        if (queued != null && !_stopping) {
          final accepted = queued.copyWith(
            attemptId: ConversationService._uuid.v4(),
            workState: ConversationWorkState.accepted,
            updatedAt: clock().toUtc(),
          );
          state = state.put(accepted);
          await _writeWorkRecords(sessionId, accepted, allowUpdate: true);
          await _persist(sessionId, state, accepted, 'queue_release');
          await _dispatch(sessionId, state, accepted, replayed: false);
        }
      }
    });
  }

  Future<Map<String, dynamic>> _metadataFor(String sessionId, ConversationSubmissionClaim submission) async {
    final attachments = <Map<String, dynamic>>[];
    for (final manifest in submission.attachments) {
      attachments.add({...await resolveAttachment(sessionId, manifest.id), 'state': 'accepted'});
    }
    return metadataWithoutAttachmentContent({
      if (attachments.isNotEmpty) 'attachments': attachments,
      if (submission.references.isNotEmpty) 'references': submission.references,
      'submissionId': submission.submissionId,
      'revisionId': submission.revisionId,
      'payloadDigest': submission.payloadDigest,
    });
  }

  Future<void> _verifyCommittedSubmission(String sessionId, ConversationSubmissionClaim submission) async {
    if (submission.commitState != SubmissionCommitState.committed) {
      throw StateError('Submission ${submission.submissionId} is not committed');
    }
    final transcript = (await messages.getMessages(sessionId)).where((message) => message.id == submission.messageId);
    if (transcript.length != 1) throw StateError('Transcript message does not match ${submission.submissionId}');
    final message = transcript.single;
    if (message.role != 'user' || message.content != submission.message) {
      throw StateError('Transcript message does not match ${submission.submissionId}');
    }
    final metadata = message.metadata == null ? null : jsonDecode(message.metadata!);
    if (metadata is! Map<String, dynamic> ||
        metadata['submissionId'] != submission.submissionId ||
        metadata['revisionId'] != submission.revisionId ||
        metadata['payloadDigest'] != submission.payloadDigest) {
      throw StateError('Transcript metadata does not match ${submission.submissionId}');
    }

    for (final (kind, id) in <(String, String)>[
      if (submission.queueId != null) ('queue', submission.queueId!),
      if (submission.attemptId != null) ('attempt', submission.attemptId!),
    ]) {
      final file = File(p.join(sessions.baseDir, sessionId, 'conversation', '${kind}s', '$id.json'));
      if (!file.existsSync()) throw StateError('$kind record is missing for ${submission.submissionId}');
      final record = jsonDecode(await file.readAsString());
      if (record is! Map<String, dynamic> ||
          record['kind'] != kind ||
          record['id'] != id ||
          record['submissionId'] != submission.submissionId ||
          record['revisionId'] != submission.revisionId ||
          record['messageId'] != submission.messageId ||
          record['payloadDigest'] != submission.payloadDigest ||
          record['workState'] != submission.workState.name) {
        throw StateError('$kind record does not match ${submission.submissionId}');
      }
    }

    if (submission.attachments.isEmpty) return;
    final expectedManifest = <String, Object?>{
      'submissionId': submission.submissionId,
      'attachments': submission.attachments.map((attachment) => attachment.toJson()).toList(growable: false),
    };
    final manifestFile = File(
      p.join(sessions.baseDir, sessionId, 'conversation', 'manifests', '${submission.submissionId}.json'),
    );
    if (!manifestFile.existsSync() ||
        jsonEncode(jsonDecode(await manifestFile.readAsString())) != jsonEncode(expectedManifest)) {
      throw StateError('Accepted attachment manifest does not match ${submission.submissionId}');
    }
    for (final attachment in submission.attachments) {
      final resolved = await resolveAttachment(sessionId, attachment.id);
      if (resolved['filename'] != attachment.filename ||
          resolved['mediaType'] != attachment.mediaType ||
          resolved['size'] != attachment.size ||
          resolved['digest'] != attachment.digest) {
        throw StateError('Attachment does not match ${attachment.id}');
      }
      final metadataFile = File(p.join(messages.baseDir, sessionId, 'attachments', '${attachment.id}.json'));
      final attachmentMetadata = jsonDecode(await metadataFile.readAsString());
      if (attachmentMetadata is! Map<String, dynamic> || attachmentMetadata['owner'] != 'accepted') {
        throw StateError('Attachment ownership does not match ${attachment.id}');
      }
    }
  }

  Future<void> _ensureRecovered(String sessionId) {
    final existing = _recoveries[sessionId];
    if (existing != null) return existing;
    final recovery = recoverAfterRestart(sessionId);
    _recoveries[sessionId] = recovery;
    return recovery.catchError((Object error, StackTrace stackTrace) {
      _recoveries.remove(sessionId);
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<ConversationAdmission> _recoverExisting(
    String sessionId,
    ConversationState state,
    ConversationSubmissionClaim submission,
  ) async {
    var next = state;
    var current = submission;
    if (current.commitState == SubmissionCommitState.preparing) {
      final recovered = await _completeDurableSequence(sessionId, next, current);
      next = recovered.snapshot;
      current = recovered.submission;
    }
    if (current.commitState == SubmissionCommitState.integrityFailed) {
      throw ConversationMutationException(
        409,
        'SUBMISSION_INTEGRITY_FAILED',
        'Submission recovery failed integrity checks',
        current: next,
      );
    }
    if (current.workState == ConversationWorkState.dispatching ||
        current.workState == ConversationWorkState.running ||
        current.workState == ConversationWorkState.uncertain) {
      if (current.workState != ConversationWorkState.uncertain) {
        current = current.copyWith(workState: ConversationWorkState.uncertain, updatedAt: clock().toUtc());
        next = next.put(current);
        await _persist(sessionId, next, current, 'dispatch_uncertain');
      }
      return ConversationAdmission(submission: current, snapshot: next, replayed: true);
    }
    if (current.workState == ConversationWorkState.accepted && !turns.isActive(sessionId)) {
      return _dispatch(sessionId, next, current, replayed: true);
    }
    return ConversationAdmission(submission: current, snapshot: next, replayed: true);
  }

  Future<ConversationAdmission> _completeDurableSequence(
    String sessionId,
    ConversationState state,
    ConversationSubmissionClaim submission,
  ) async {
    for (final attachment in submission.attachments) {
      final dataFile = File(p.join(messages.baseDir, sessionId, 'attachments', '${attachment.id}.data'));
      final metadataFile = File(p.join(messages.baseDir, sessionId, 'attachments', '${attachment.id}.json'));
      final metadata = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final bytes = await dataFile.readAsBytes();
      final digest = 'sha256:${sha256.convert(bytes)}';
      if (metadata['digest'] != attachment.digest ||
          metadata['size'] != attachment.size ||
          bytes.length != attachment.size ||
          digest != attachment.digest) {
        throw StateError('Attachment manifest does not match ${attachment.id}');
      }
      await _hit('attachment_data', submission);
      metadata['owner'] = 'accepted';
      await atomicWriteJson(metadataFile, metadata);
      await _hit('attachment_metadata', submission);
    }
    if (submission.attachments.isNotEmpty) {
      final manifestFile = File(
        p.join(sessions.baseDir, sessionId, 'conversation', 'manifests', '${submission.submissionId}.json'),
      );
      await manifestFile.parent.create(recursive: true);
      final expectedManifest = <String, Object?>{
        'submissionId': submission.submissionId,
        'attachments': submission.attachments.map((attachment) => attachment.toJson()).toList(growable: false),
      };
      if (manifestFile.existsSync()) {
        final existing = jsonDecode(await manifestFile.readAsString());
        if (jsonEncode(existing) != jsonEncode(expectedManifest)) {
          throw StateError('Accepted attachment manifest does not match ${submission.submissionId}');
        }
      } else {
        await atomicWriteJson(manifestFile, expectedManifest);
      }
      await _hit('accepted_manifest', submission);
    }
    final metadata = await _metadataFor(sessionId, submission);
    if (submission.replacesRevisionId == null) {
      await messages.insertMessageWithIdentity(
        sessionId: sessionId,
        messageId: submission.messageId,
        role: 'user',
        content: submission.message,
        metadata: metadata.isEmpty ? null : jsonEncode(metadata),
        createdAt: submission.createdAt,
        notifyObserver: false,
      );
    } else {
      await messages.replaceMessageWithIdentity(
        sessionId: sessionId,
        messageId: submission.messageId,
        content: submission.message,
        metadata: metadata.isEmpty ? null : jsonEncode(metadata),
      );
    }
    await _hit('transcript_append', submission);
    await _writeWorkRecords(sessionId, submission, allowUpdate: submission.replacesRevisionId != null);
    await _hit(submission.queueId == null ? 'attempt_write' : 'queue_write', submission);
    final committed = submission.copyWith(commitState: SubmissionCommitState.committed, updatedAt: clock().toUtc());
    final next = state.put(committed);
    await _persist(sessionId, next, committed, 'committed_claim');
    return ConversationAdmission(submission: committed, snapshot: next, replayed: false);
  }

  Future<void> _writeWorkRecords(
    String sessionId,
    ConversationSubmissionClaim submission, {
    bool allowUpdate = false,
  }) async {
    final records = <(String, String)>[
      if (submission.queueId != null) ('queue', submission.queueId!),
      if (submission.attemptId != null) ('attempt', submission.attemptId!),
    ];
    for (final (kind, id) in records) {
      final file = File(p.join(sessions.baseDir, sessionId, 'conversation', '${kind}s', '$id.json'));
      await file.parent.create(recursive: true);
      final record = <String, Object?>{
        'kind': kind,
        'id': id,
        'submissionId': submission.submissionId,
        'revisionId': submission.revisionId,
        'messageId': submission.messageId,
        'payloadDigest': submission.payloadDigest,
        'workState': submission.workState.name,
        'updatedAt': submission.updatedAt.toUtc().toIso8601String(),
        if (submission.admittedContext != null) 'context': submission.admittedContext!.toJson(),
      };
      if (file.existsSync() && !allowUpdate) {
        final existing = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final key in const ['kind', 'id', 'submissionId', 'revisionId', 'messageId', 'payloadDigest']) {
          if (existing[key] != record[key]) throw StateError('$kind record does not match ${submission.submissionId}');
        }
        continue;
      }
      await atomicWriteJson(file, record);
    }
  }

  Future<void> _writeQueueRecords(String sessionId, ConversationState state) async {
    for (final item in state.queue) {
      await _writeWorkRecords(sessionId, item, allowUpdate: true);
    }
  }

  Future<void> _cleanupAttachmentPartials(String sessionId, ConversationState state) async {
    final directory = Directory(p.join(messages.baseDir, sessionId, 'attachments'));
    if (!directory.existsSync()) return;
    final claimed = {
      for (final submission in state.submissions)
        for (final attachment in submission.attachments) attachment.id,
    };
    final ids = <String>{};
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path);
      if (extension != '.data' && extension != '.json') continue;
      ids.add(p.basenameWithoutExtension(entity.path));
    }
    for (final id in ids) {
      if (claimed.contains(id)) continue;
      final data = File(p.join(directory.path, '$id.data'));
      final metadata = File(p.join(directory.path, '$id.json'));
      if (data.existsSync() == metadata.existsSync()) continue;
      if (data.existsSync()) await data.delete();
      if (metadata.existsSync()) await metadata.delete();
    }
  }

  Future<List<ConversationAttachmentManifest>> _attachmentManifests(
    String sessionId,
    List<Map<String, dynamic>> attachments,
  ) async {
    final result = <ConversationAttachmentManifest>[];
    for (final input in attachments) {
      final id = input['id'];
      if (id is! String || id.isEmpty) {
        throw const ConversationMutationException(400, 'UNKNOWN_ATTACHMENT', 'Attachment was not uploaded');
      }
      final metadata = await resolveAttachment(sessionId, id);
      result.add(
        ConversationAttachmentManifest(
          id: id,
          filename: metadata['filename'] as String,
          mediaType: metadata['mediaType'] as String,
          size: metadata['size'] as int,
          digest: metadata['digest'] as String,
        ),
      );
    }
    return result;
  }

  Future<void> _persist(
    String sessionId,
    ConversationState state,
    ConversationSubmissionClaim submission,
    String boundary,
  ) async {
    await sessions.updateConversationState(sessionId, state);
    _broadcast(sessionId, state.revision);
    await _hit(boundary, submission);
  }

  Future<void> _persistSnapshot(String sessionId, ConversationState state) async {
    await sessions.updateConversationState(sessionId, state);
    _broadcast(sessionId, state.revision);
  }

  Future<void> _hit(String boundary, ConversationSubmissionClaim submission) async {
    await failpoint?.call(boundary, submission);
  }

  void _broadcast(String sessionId, int revision) {
    updates?.broadcast('conversation_changed', {'session_id': sessionId, 'revision': revision});
  }

  ConversationSubmissionClaim _mutableQueueItem(ConversationState state, String queueId) {
    final current = state.findQueueItem(queueId);
    if (current == null) {
      throw ConversationMutationException(404, 'QUEUE_ITEM_NOT_FOUND', 'Queue item not found', current: state);
    }
    if (current.workState != ConversationWorkState.queued && current.workState != ConversationWorkState.held) {
      throw ConversationMutationException(409, 'QUEUE_ITEM_ALREADY_SENT', 'Already sent', current: state);
    }
    return current;
  }

  void _requireRevision(ConversationState state, int expected) {
    if (state.revision != expected) {
      throw ConversationMutationException(
        409,
        'STALE_CONVERSATION_REVISION',
        'Conversation state changed',
        current: state,
      );
    }
  }

  Future<ConversationState> _ensureContext(String sessionId, ConversationState state, {bool persist = true}) async {
    if (state.nextContext != null) return state;
    final session = await sessions.getSession(sessionId);
    if (session == null) {
      throw ConversationMutationException(404, 'SESSION_NOT_FOUND', 'Session not found', current: state);
    }
    final project = projects == null ? null : await projects!.defaultProject;
    final projectId = project?.id ?? '_local';
    final root = p.normalize(p.absolute(project?.localPath ?? Directory.current.path));
    final provider = session.provider?.trim().isNotEmpty == true ? session.provider!.trim() : defaultProvider;
    final context = await _validatedContext(projectId: projectId, directory: root, provider: provider);
    final initialized = ConversationState(
      revision: persist ? state.revision + 1 : state.revision,
      submissions: state.submissions,
      records: state.records,
      branches: state.branches,
      currentContext: state.currentContext,
      nextContext: context,
      telemetry: state.telemetry,
    );
    if (persist) {
      await sessions.updateConversationState(sessionId, initialized);
      _broadcast(sessionId, initialized.revision);
    }
    return initialized;
  }

  Future<EffectiveConversationContext> _validatedContext({
    required String projectId,
    required String directory,
    required String provider,
    String? model,
    String? effort,
  }) async {
    final project = projects == null
        ? projectId == '_local'
              ? null
              : throw const ConversationMutationException(403, 'PROJECT_FORBIDDEN', 'Project is not available')
        : await projects!.get(projectId);
    if (projects != null && project == null) {
      throw const ConversationMutationException(403, 'PROJECT_FORBIDDEN', 'Project is not available');
    }
    if (project != null && project.status != ProjectStatus.ready) {
      throw const ConversationMutationException(409, 'PROJECT_UNAVAILABLE', 'Project is not ready');
    }
    final root = _canonicalDirectory(project?.localPath ?? Directory.current.path);
    final chosen = _canonicalDirectory(directory);
    if (!p.equals(root, chosen) && !p.isWithin(root, chosen)) {
      throw const ConversationMutationException(403, 'DIRECTORY_FORBIDDEN', 'Directory is outside the project');
    }
    if (!Directory(chosen).existsSync()) {
      throw const ConversationMutationException(400, 'DIRECTORY_UNAVAILABLE', 'Directory does not exist');
    }
    final normalizedProvider = provider.trim();
    if (normalizedProvider.isEmpty ||
        contextCapabilities.isNotEmpty && !contextCapabilities.containsKey(normalizedProvider)) {
      throw const ConversationMutationException(403, 'PROVIDER_FORBIDDEN', 'Provider is not available');
    }
    final capabilities = contextCapabilities[normalizedProvider];
    final cleanModel = _trimToNull(model);
    final cleanEffort = _trimToNull(effort);
    if (cleanModel != null && !(capabilities?.model ?? contextCapabilities.isEmpty)) {
      throw const ConversationMutationException(
        400,
        'MODEL_UNSUPPORTED',
        'Provider does not transport a model override',
      );
    }
    if (cleanEffort != null && !(capabilities?.effort ?? contextCapabilities.isEmpty)) {
      throw const ConversationMutationException(
        400,
        'EFFORT_UNSUPPORTED',
        'Provider does not transport an effort override',
      );
    }
    return EffectiveConversationContext(
      projectId: projectId,
      directory: chosen,
      referenceRoot: root,
      provider: normalizedProvider,
      model: cleanModel,
      effort: cleanEffort,
    );
  }

  Future<void> _revalidateContext(EffectiveConversationContext context) async {
    await _validatedContext(
      projectId: context.projectId,
      directory: context.directory,
      provider: context.provider,
      model: context.model,
      effort: context.effort,
    );
  }

  Future<void> _validateReferences(EffectiveConversationContext context, List<Map<String, dynamic>> references) async {
    for (final reference in references) {
      final type = reference['type'];
      final id = reference['id'];
      if (type is! String || id is! String || id.isEmpty) {
        throw const ConversationMutationException(400, 'UNKNOWN_REFERENCE', 'Reference could not be resolved');
      }
      if (type == 'project' && id != context.projectId) {
        throw const ConversationMutationException(
          403,
          'REFERENCE_FORBIDDEN',
          'Project reference is outside the context',
        );
      }
      if (type == 'file') {
        final normalized = p.normalize(id);
        if (p.isAbsolute(normalized) || normalized == '..' || normalized.startsWith('..${p.separator}')) {
          throw const ConversationMutationException(
            403,
            'REFERENCE_FORBIDDEN',
            'File reference is outside the project',
          );
        }
        final target = File(p.join(context.referenceRoot, normalized));
        if (!target.existsSync()) {
          throw const ConversationMutationException(400, 'UNKNOWN_REFERENCE', 'File reference could not be resolved');
        }
        final canonical = p.normalize(target.resolveSymbolicLinksSync());
        if (!p.isWithin(context.referenceRoot, canonical) && !p.equals(context.referenceRoot, canonical)) {
          throw const ConversationMutationException(
            403,
            'REFERENCE_FORBIDDEN',
            'File reference is outside the project',
          );
        }
      }
    }
    await referenceValidator?.call(
      references.where((reference) => reference['type'] != 'file').toList(growable: false),
    );
  }

  // `uncertain` is deliberately absent: it is never retried and nothing
  // resolves it, so counting it parked the session for good after one crash.
  // Genuinely live work is in one of these states or in `turns.isActive`.
  bool _hasBlockingDispatch(ConversationState state) => state.submissions.any(
    (item) =>
        item.workState == ConversationWorkState.dispatching ||
        item.workState == ConversationWorkState.running ||
        item.workState == ConversationWorkState.stopping,
  );

  ConversationSubmissionClaim? _submissionForTurn(ConversationState state, String turnId) {
    for (final submission in state.submissions) {
      if (submission.turnId == turnId) return submission;
    }
    return null;
  }

  ConversationSubmissionClaim? _submissionForQueue(ConversationState state, String queueId) {
    for (final submission in state.submissions) {
      if (submission.queueId == queueId) return submission;
    }
    return null;
  }

  // Every `_dispatch` entry has already established that no turn is live for
  // this session, so an `uncertain` claim here is settled work with no outcome.
  Future<ConversationState> _settleUncertainDispatches(String sessionId, ConversationState state) async {
    var next = state;
    for (final item in state.submissions) {
      if (item.workState != ConversationWorkState.uncertain) continue;
      final settled = item.copyWith(
        workState: ConversationWorkState.failed,
        detail: 'Dispatch was never confirmed; its outcome is unknown',
        updatedAt: clock().toUtc(),
      );
      next = next.put(settled);
      await _writeWorkRecords(sessionId, settled, allowUpdate: true);
    }
    return next;
  }

  // Every refusal `cancelTurnById` raises is a pre-mutation guard, so no turn
  // was touched; a `stopping` marker left behind parks the session for good.
  Future<void> _restoreRefusedStop(String sessionId, ConversationState state, ConversationSubmissionClaim prior) async {
    await _writeWorkRecords(sessionId, prior, allowUpdate: true);
    await _persist(sessionId, state.put(prior), prior, 'stop_refused');
  }

  ConversationState _holdPending(ConversationState state) {
    var next = state;
    for (final item in state.queue) {
      if (item.workState == ConversationWorkState.queued) {
        next = next.put(item.copyWith(workState: ConversationWorkState.held, updatedAt: clock().toUtc()));
      }
    }
    return next;
  }

  ConversationState _retainToolOutcome(
    ConversationState state,
    ConversationSubmissionClaim submission,
    TurnOutcome outcome,
  ) {
    var next = state;
    for (var index = 0; index < outcome.toolCalls.length; index++) {
      final call = outcome.toolCalls[index];
      final id = call.id ?? '${outcome.turnId}:tool:$index';
      final existing = next.findRecord(id);
      if (existing != null && _isTerminalRecordState(existing.state)) continue;
      final now = outcome.completedAt.toUtc();
      final record = ConversationDisplayRecord(
        id: id,
        attemptId: submission.attemptId!,
        turnId: outcome.turnId,
        kind: ConversationRecordKind.tool,
        state: call.success ? ConversationRecordState.succeeded : ConversationRecordState.failed,
        label: _redactor.redact(call.name),
        arguments: call.arguments,
        result: call.result,
        isTruncated: call.isTruncated,
        elapsedMs: call.durationMs,
        createdAt: existing?.createdAt ?? now.subtract(Duration(milliseconds: call.durationMs)),
        updatedAt: now,
      );
      next = next.putRecord(record);
    }
    return next;
  }

  ({String text, bool truncated}) _displayPayload(Object value) {
    if (value is Map<String, dynamic>) {
      final serialized = DailyLogToolSerializer(_redactor).serializeInput(value);
      return (text: serialized.summary, truncated: serialized.truncated);
    }
    final redacted = _redactor.redact(value is String ? value : jsonEncode(value));
    if (redacted.length <= ConversationService._maxDisplayPayloadChars) return (text: redacted, truncated: false);
    return (
      text: '${redacted.substring(0, ConversationService._maxDisplayPayloadChars)}\n[Display payload truncated]',
      truncated: true,
    );
  }
}
