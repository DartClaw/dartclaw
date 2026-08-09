import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/channel_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-wiring-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('channel dispatch selects the conversational prompt scope', () async {
    final turns = FakeTurnManager(
      onWaitForOutcome: (sessionId, turnId) async => TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        responseText: 'reply',
        completedAt: DateTime.now(),
      ),
    );

    final response = await dispatchChannelTurn(
      sessions: SessionService(baseDir: tempDir.path),
      messages: MessageService(baseDir: tempDir.path),
      turnManagerGetter: () => turns,
      sessionKey: 'signal:dm:alice',
      message: 'hello',
    );

    expect(response, 'reply');
    expect(turns.startedTurns, hasLength(1));
    final turn = turns.startedTurns.single;
    expect(turn.source, 'channel');
    expect(turn.isHumanInput, isTrue);
    expect(turn.promptScope, PromptScope.conversational);
  });
}
