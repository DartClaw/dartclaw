@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'container_integration_support.dart' show repoRoot;

void main() {
  test(
    'submission commit failpoints converge without automatic replay',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      for (final boundary in const [
        'preparing_claim',
        'transcript_append',
        'attempt_write',
        'queue_write',
        'committed_claim',
        'dispatch_marker',
        'turn_reserved',
        'turn_execute',
        'before_response_ack',
        'after_response_ack',
      ]) {
        final fixture = await _Fixture.create();
        try {
          final admission = boundary == 'queue_write' ? 'queue' : 'dispatch';
          expect(await fixture.run(boundary, admission: admission), 86, reason: boundary);
          expect(fixture.acknowledgement.existsSync(), boundary == 'after_response_ack', reason: '$boundary ack');
          expect(await fixture.run('none', admission: admission), 0, reason: '$boundary retry');
          final state = await fixture.sessions.getConversationState(fixture.sessionId);
          final claim = state.findSubmission('stable-submission');
          expect(claim?.commitState, SubmissionCommitState.committed, reason: boundary);
          expect((await fixture.messages.getMessages(fixture.sessionId)).length, 1, reason: boundary);
          final expectedExecutions = const {
            'preparing_claim': 1,
            'transcript_append': 1,
            'attempt_write': 1,
            'queue_write': 0,
            'committed_claim': 1,
            'dispatch_marker': 0,
            'turn_reserved': 0,
            'turn_execute': 1,
            'before_response_ack': 1,
            'after_response_ack': 1,
          }[boundary];
          expect(fixture.invocationCount, expectedExecutions, reason: boundary);
          if (boundary == 'queue_write') {
            expect(claim?.queueId, isNotNull);
            expect(claim?.attemptId, isNull);
          }
          final workFile = claim?.queueId == null
              ? fixture.attemptRecord(claim!.attemptId!)
              : fixture.queueRecord(claim!.queueId!);
          final work = jsonDecode(workFile.readAsStringSync()) as Map<String, dynamic>;
          expect(work['submissionId'], claim.submissionId, reason: boundary);
          expect(work['revisionId'], claim.revisionId, reason: boundary);
          expect(work['messageId'], claim.messageId, reason: boundary);
          expect(work['payloadDigest'], claim.payloadDigest, reason: boundary);
          if (const {
            'dispatch_marker',
            'turn_reserved',
            'turn_execute',
            'before_response_ack',
            'after_response_ack',
          }.contains(boundary)) {
            expect(claim.workState, ConversationWorkState.uncertain, reason: boundary);
          }
        } finally {
          fixture.dispose();
        }
      }
    },
  );

  test(
    'attachment manifest protects accepted handles across every write crash',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      for (final boundary in const ['attachment_data', 'attachment_metadata', 'accepted_manifest']) {
        final fixture = await _Fixture.create(withAttachment: true, seedAttachment: boundary == 'accepted_manifest');
        try {
          expect(await fixture.run(boundary), 86, reason: boundary);
          if (boundary == 'attachment_data') {
            expect(fixture.attachmentData.existsSync(), isTrue);
            expect(fixture.attachmentMetadata.existsSync(), isFalse);
          } else if (boundary == 'attachment_metadata') {
            expect(fixture.attachmentData.existsSync(), isTrue);
            expect(fixture.attachmentMetadata.existsSync(), isTrue);
          } else {
            expect(fixture.acceptedManifest.existsSync(), isTrue);
          }
          expect(await fixture.run('none'), 0, reason: '$boundary retry');
          final metadata = jsonDecode(fixture.attachmentMetadata.readAsStringSync()) as Map<String, dynamic>;
          expect(metadata['owner'], 'accepted', reason: boundary);
          expect(metadata['submissionId'], 'stable-submission', reason: boundary);
          expect(fixture.attachmentData.readAsBytesSync(), utf8.encode('attachment bytes'), reason: boundary);
          expect(fixture.acceptedManifest.existsSync(), isTrue, reason: boundary);
          final manifest = jsonDecode(fixture.acceptedManifest.readAsStringSync()) as Map<String, dynamic>;
          expect(manifest['submissionId'], 'stable-submission', reason: boundary);
          expect((manifest['attachments'] as List<dynamic>).single, {
            'id': fixture.attachmentId,
            'filename': 'proof.txt',
            'mediaType': 'text/plain',
            'size': utf8.encode('attachment bytes').length,
            'digest': 'sha256:${sha256.convert(utf8.encode('attachment bytes'))}',
          });
          expect(fixture.invocationCount, 1, reason: boundary);
        } finally {
          fixture.dispose();
        }
      }

      for (final missingExtension in const ['json', 'data']) {
        final partial = await _Fixture.create();
        try {
          final attachmentDirectory = Directory(p.join(partial.directory.path, partial.sessionId, 'attachments'))
            ..createSync(recursive: true);
          final id = '00000000-0000-4000-8000-000000000099';
          File(p.join(attachmentDirectory.path, '$id.$missingExtension')).writeAsStringSync('partial', flush: true);
          expect(await partial.run('none'), 0);
          expect(attachmentDirectory.listSync(), isEmpty, reason: 'unclaimed $missingExtension-only pair');
        } finally {
          partial.dispose();
        }
      }

      final mismatched = await _Fixture.create(withAttachment: true);
      try {
        final metadata = jsonDecode(mismatched.attachmentMetadata.readAsStringSync()) as Map<String, dynamic>;
        metadata['digest'] = 'sha256:mismatch';
        mismatched.attachmentMetadata.writeAsStringSync(jsonEncode(metadata));
        expect(await mismatched.run('none'), isNot(0));
        expect(mismatched.invocationCount, 0);
        expect(await mismatched.messages.getMessages(mismatched.sessionId), isEmpty);
      } finally {
        mismatched.dispose();
      }

      final mismatchedBytes = await _Fixture.create(withAttachment: true);
      try {
        mismatchedBytes.attachmentData.writeAsStringSync('changed bytes', flush: true);
        expect(await mismatchedBytes.run('none'), isNot(0));
        expect(mismatchedBytes.invocationCount, 0);
        expect(await mismatchedBytes.messages.getMessages(mismatchedBytes.sessionId), isEmpty);
      } finally {
        mismatchedBytes.dispose();
      }

      for (final corrupt in const ['metadata', 'data']) {
        final claimed = await _Fixture.create(withAttachment: true);
        try {
          expect(await claimed.run('preparing_claim'), 86, reason: corrupt);
          if (corrupt == 'metadata') {
            final metadata = jsonDecode(claimed.attachmentMetadata.readAsStringSync()) as Map<String, dynamic>;
            metadata['digest'] = 'sha256:mismatch';
            claimed.attachmentMetadata.writeAsStringSync(jsonEncode(metadata), flush: true);
          } else {
            claimed.attachmentData.writeAsStringSync('changed after claim', flush: true);
          }
          expect(await claimed.run('none'), isNot(0), reason: corrupt);
          final state = await claimed.sessions.getConversationState(claimed.sessionId);
          expect(state.findSubmission('stable-submission')?.commitState, SubmissionCommitState.integrityFailed);
          expect(state.findSubmission('stable-submission')?.workState, ConversationWorkState.held);
          expect(claimed.invocationCount, 0);
        } finally {
          claimed.dispose();
        }
      }
    },
  );

  test(
    'only committed submissions dispatch and acknowledgement retry reuses the attempt',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final fixture = await _Fixture.create();
      try {
        expect(await fixture.run('before_response_ack'), 86);
        final before = await fixture.sessions.getConversationState(fixture.sessionId);
        final attemptId = before.findSubmission('stable-submission')?.attemptId;
        expect(attemptId, isNotNull);
        expect(await fixture.run('none'), 0);
        final after = await fixture.sessions.getConversationState(fixture.sessionId);
        expect(after.findSubmission('stable-submission')?.attemptId, attemptId);
        expect(after.findSubmission('stable-submission')?.workState, ConversationWorkState.uncertain);
        expect(fixture.invocationCount, 1);
        expect((await fixture.messages.getMessages(fixture.sessionId)).length, 1);
      } finally {
        fixture.dispose();
      }
    },
  );
}

final class _Fixture {
  new _(this.directory, this.helper, this.sessions, this.messages, this.sessionId, this.attachmentId);

  final Directory directory;
  final File helper;
  final SessionService sessions;
  final MessageService messages;
  final String sessionId;
  final String? attachmentId;

  File get attachmentData => File(p.join(directory.path, sessionId, 'attachments', '$attachmentId.data'));
  File get attachmentMetadata => File(p.join(directory.path, sessionId, 'attachments', '$attachmentId.json'));
  File get acceptedManifest =>
      File(p.join(directory.path, sessionId, 'conversation', 'manifests', 'stable-submission.json'));
  File get acknowledgement => File(p.join(directory.path, 'ack.json'));

  File attemptRecord(String attemptId) =>
      File(p.join(directory.path, sessionId, 'conversation', 'attempts', '$attemptId.json'));
  File queueRecord(String queueId) =>
      File(p.join(directory.path, sessionId, 'conversation', 'queues', '$queueId.json'));

  int get invocationCount {
    final file = File(p.join(directory.path, 'invocations.ndjson'));
    return file.existsSync() ? file.readAsLinesSync().where((line) => line.trim().isNotEmpty).length : 0;
  }

  static Future<_Fixture> create({bool withAttachment = false, bool seedAttachment = true}) async {
    final directory = Directory.systemTemp.createTempSync('dartclaw_conversation_crash_');
    final sessions = SessionService(baseDir: directory.path);
    final messages = MessageService(baseDir: directory.path);
    final sessionId = (await sessions.createSession()).id;
    final helper = File(
      p.join(
        await repoRoot(),
        'packages',
        'dartclaw_runtime',
        'test',
        'integration',
        '_fixtures',
        'conversation_loop_process.dart',
      ),
    );
    String? attachmentId;
    if (withAttachment) {
      attachmentId = '00000000-0000-4000-8000-000000000001';
    }
    if (attachmentId != null && seedAttachment) {
      final data = utf8.encode('attachment bytes');
      final attachmentDirectory = Directory(p.join(directory.path, sessionId, 'attachments'))..createSync();
      File(p.join(attachmentDirectory.path, '$attachmentId.data')).writeAsBytesSync(data, flush: true);
      File(p.join(attachmentDirectory.path, '$attachmentId.json')).writeAsStringSync(
        jsonEncode({
          'id': attachmentId,
          'filename': 'proof.txt',
          'mediaType': 'text/plain',
          'size': data.length,
          'digest': 'sha256:${sha256.convert(data)}',
          'state': 'ready',
          'owner': 'draft',
        }),
        flush: true,
      );
    }
    return _Fixture._(directory, helper, sessions, messages, sessionId, attachmentId);
  }

  Future<int> run(String boundary, {String admission = 'dispatch'}) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      helper.path,
      directory.path,
      sessionId,
      boundary,
      attachmentId ?? 'none',
      admission,
    ], workingDirectory: Directory.current.path);
    if (result.exitCode != 0 && result.exitCode != 86 && result.stderr.toString().isEmpty) {
      fail('$boundary failed without diagnostics');
    }
    return result.exitCode;
  }

  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
