part of 'conversation_service.dart';

extension _ConversationServiceBranching on ConversationService {
  Future<EffectiveConversationContext> _branchDestinationContext(
    Session source,
    ConversationState state,
    ConversationSubmissionClaim? claim,
    ConversationBranchLink? branch,
  ) async {
    if (branch != null && await sessions.getSession(branch.destinationSessionId) != null) {
      final destination = await sessions.getConversationState(branch.destinationSessionId);
      final retained = destination.nextContext;
      if (retained != null) {
        await _revalidateContext(retained);
        return retained;
      }
    }
    late final ResolvedConversationDestination resolved;
    try {
      resolved = turns.resolveConversationDestination(source);
    } catch (_) {
      throw const ConversationMutationException(
        409,
        'BRANCH_DESTINATION_UNAVAILABLE',
        'The configured destination is no longer available. Create a new conversation to use the current workspace.',
      );
    }
    final context = claim?.admittedContext ?? state.currentContext ?? state.nextContext;
    return _validatedContext(
      projectId: context?.projectId,
      directory: context?.directory ?? ownerWorkspaceDir,
      provider: resolved.provider,
      model: context?.provider == resolved.provider ? context?.model : null,
      effort: context?.provider == resolved.provider ? context?.effort : null,
    );
  }

  Future<Map<String, Object?>> _continueBranch({
    required EffectiveConversationContext destinationContext,
    required Session sourceSession,
    required ConversationState sourceState,
    required List<Message> sourceMessages,
    required ConversationSubmissionClaim? sourceClaim,
    required List<ConversationSubmissionClaim> copiedClaims,
    required int copyThrough,
    required String? editedMessage,
    required ConversationBranchLink branch,
  }) async {
    var destination = await sessions.getSession(branch.destinationSessionId);
    if (destination == null) {
      late final ResolvedConversationDestination resolved;
      try {
        resolved = turns.resolveConversationDestination(sourceSession);
      } catch (_) {
        throw const ConversationMutationException(
          409,
          'BRANCH_DESTINATION_UNAVAILABLE',
          'The configured destination is no longer available. Create a new conversation to use the current workspace.',
        );
      }
      destination = await sessions.createSessionWithIdentity(
        id: branch.destinationSessionId,
        retention: sourceSession.retention,
        provider: resolved.provider,
        securityProfile: resolved.securityProfile,
        executionMode: resolved.executionMode,
        workspace: resolved.workspace,
      );
    }
    final destinationStateBeforeCopy = await sessions.getConversationState(destination.id);
    if (destinationStateBeforeCopy.nextContext == null) {
      await _persistSnapshot(destination.id, destinationStateBeforeCopy.stageContext(destinationContext));
    }
    await branchFailpoint?.call('branch_destination', branch);
    final manifests = branch.kind == ConversationBranchKind.edit
        ? sourceClaim?.attachments ?? const <ConversationAttachmentManifest>[]
        : copiedClaims.expand((claim) => claim.attachments).toSet().toList(growable: false);
    await _copyAcceptedAttachments(sourceSession.id, destination.id, manifests);
    for (var index = 0; index <= copyThrough; index++) {
      final message = sourceMessages[index];
      if (!sourceState.includesMessage(message.id)) continue;
      await messages.insertMessageWithIdentity(
        sessionId: destination.id,
        messageId: message.id,
        role: message.role,
        content: message.content,
        metadata: message.metadata,
        createdAt: message.createdAt,
      );
    }
    await branchFailpoint?.call('branch_history_copied', branch);
    late final String destinationMessageId;
    String? destinationAttemptId;
    if (branch.kind == ConversationBranchKind.edit) {
      final existing = (await sessions.getConversationState(destination.id)).findSubmission(branch.mutationId);
      if (existing != null) {
        destinationMessageId = existing.messageId;
        destinationAttemptId = existing.attemptId;
      } else {
        final admission = await submit(
          sessionId: destination.id,
          submissionId: branch.mutationId,
          revisionId: '${branch.mutationId}-edit',
          message: editedMessage!,
          attachments: manifests.map((attachment) => {'id': attachment.id}).toList(growable: false),
          references: sourceClaim?.references ?? const [],
        );
        destinationMessageId = admission.submission.messageId;
        destinationAttemptId = admission.submission.attemptId;
        await branchFailpoint?.call('branch_edit_admitted', branch);
      }
    } else {
      final copied = await messages.getMessages(destination.id);
      destinationMessageId = copied.last.id;
    }
    final link = branch.copyWith(
      destinationMessageId: destinationMessageId,
      destinationAttemptId: destinationAttemptId,
      completed: true,
    );
    var destinationState = await sessions.getConversationState(destination.id);
    destinationState = destinationState.putBranch(link);
    await _persistSnapshot(destination.id, destinationState);
    await branchFailpoint?.call('branch_destination_linked', link);
    sourceState = sourceState.putBranch(link);
    await _persistSnapshot(sourceSession.id, sourceState);
    return link.toJson();
  }

  Future<void> _copyAcceptedAttachments(
    String sourceSessionId,
    String destinationSessionId,
    List<ConversationAttachmentManifest> attachments,
  ) async {
    if (attachments.isEmpty) return;
    final destination = Directory(p.join(messages.baseDir, destinationSessionId, 'attachments'));
    await destination.create(recursive: true);
    for (final attachment in attachments) {
      final source = p.join(messages.baseDir, sourceSessionId, 'attachments');
      await File(p.join(source, '${attachment.id}.data')).copy(p.join(destination.path, '${attachment.id}.data'));
      final metadata = jsonDecode(await File(p.join(source, '${attachment.id}.json')).readAsString());
      if (metadata is! Map<String, dynamic>) throw StateError('Attachment metadata is invalid');
      metadata['state'] = 'ready';
      metadata.remove('owner');
      metadata.remove('submissionId');
      await atomicWriteJson(File(p.join(destination.path, '${attachment.id}.json')), metadata);
    }
  }
}
