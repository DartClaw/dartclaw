import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/api/session_routes.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../session_turn_manager_test_support.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) {
    stderr.writeln(
      'usage: conversation_loop_process.dart <data-dir> <session-id> <boundary|none> <attachment-id|none> <dispatch|queue>',
    );
    exitCode = 64;
    return;
  }
  final [dataDirectory, sessionId, boundary, attachmentId, admission] = arguments;
  final sessions = SessionService(baseDir: dataDirectory);
  final messages = MessageService(baseDir: dataDirectory);
  final worker = FakeAgentHarness();
  final turns = _LedgerTurnManager(messages, worker, File(p.join(dataDirectory, 'invocations.ndjson')));
  if (attachmentId != 'none') {
    final directory = p.join(dataDirectory, sessionId, 'attachments');
    final dataFile = File(p.join(directory, '$attachmentId.data'));
    final metadataFile = File(p.join(directory, '$attachmentId.json'));
    if (boundary == 'attachment_data' ||
        boundary == 'attachment_metadata' ||
        !dataFile.existsSync() ||
        !metadataFile.existsSync()) {
      final uploadHandler = sessionRoutes(
        sessions,
        messages,
        turns,
        worker,
        attachmentIdFactory: () => attachmentId,
        attachmentWriteFailpoint: (name, id) {
          if (name != boundary) return;
          File(p.join(dataDirectory, 'failpoint.json'))
              .writeAsStringSync(jsonEncode({'boundary': name, 'attachmentId': id}), flush: true);
          exit(86);
        },
      ).call;
      final upload = await uploadHandler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/$sessionId/attachments'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'filename': 'proof.txt',
            'mediaType': 'text/plain',
            'size': utf8.encode('attachment bytes').length,
            'contentBase64': base64Encode(utf8.encode('attachment bytes')),
          }),
        ),
      );
      if (upload.statusCode != 201) {
        stderr.writeln(await upload.readAsString());
        exitCode = 1;
        return;
      }
    }
  }
  if (admission == 'queue') await turns.reserveTurn(sessionId);
  final service = ConversationService(
    sessions: sessions,
    messages: messages,
    turns: turns,
    mutations: SessionMutationCoordinator(),
    clock: () => DateTime.utc(2026, 9, 14, 12),
    failpoint: (name, submission) {
      if (name != boundary) return;
      File(p.join(dataDirectory, 'failpoint.json'))
          .writeAsStringSync(jsonEncode({'boundary': name, 'submissionId': submission.submissionId}), flush: true);
      exit(86);
    },
  );

  final result = await service.submit(
    sessionId: sessionId,
    submissionId: 'stable-submission',
    revisionId: 'stable-revision',
    message: 'Crash-safe message',
    attachments: attachmentId == 'none'
        ? const []
        : [
            {'id': attachmentId},
          ],
    references: const [],
  );
  if (boundary == 'before_response_ack') exit(86);
  File(p.join(dataDirectory, 'ack.json')).writeAsStringSync(jsonEncode(result.toJson()), flush: true);
  if (boundary == 'after_response_ack') exit(86);
}

final class _LedgerTurnManager extends FakeTurnManager {
  new(super.messages, super.worker, this.ledger);

  final File ledger;

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    ledger.writeAsStringSync(
      '${jsonEncode({'sessionId': sessionId, 'turnId': turnId, 'messageIds': messages.map((item) => item['id']).toList()})}\n',
      mode: FileMode.append,
      flush: true,
    );
    super.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
  }
}
