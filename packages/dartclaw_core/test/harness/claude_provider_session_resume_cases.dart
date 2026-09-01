part of 'claude_code_harness_test.dart';

void registerClaudeProviderSessionResumeTests() {
  group('provider-session resume', () {
    test('a provider session resumes in a freshly constructed harness', () async {
      final bootstrapSpawns = <List<String>>[];
      final bootstrapHarness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          systemInitSessionId: 'claude-session-x',
          result: const {'session_id': 'claude-session-x'},
          onSpawn: (spawn) => bootstrapSpawns.add(spawn.args),
        ),
      );
      addTeardownAsync(() => bootstrapHarness.dispose());
      await bootstrapHarness.start();
      final bootstrapResult = await bootstrapHarness.turn(
        sessionId: 'bootstrap',
        messages: const [
          {'role': 'user', 'content': 'start durable'},
        ],
        systemPrompt: '',
        requestProviderSessionResume: true,
      );
      expect(bootstrapSpawns.last, isNot(contains('--no-session-persistence')));
      expect(bootstrapSpawns.last, isNot(contains('--resume')));
      expect(bootstrapResult.providerSessionId, 'claude-session-x');
      await bootstrapHarness.dispose();

      final resumeSpawns = <List<String>>[];
      final resumeHarness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          systemInitSessionId: 'claude-session-x',
          result: const {'session_id': 'claude-session-x'},
          onSpawn: (spawn) => resumeSpawns.add(spawn.args),
        ),
      );
      addTeardownAsync(() => resumeHarness.dispose());
      await resumeHarness.start();
      final resumedResult = await resumeHarness.turn(
        sessionId: 'resume',
        messages: const [
          {'role': 'user', 'content': 'continue'},
        ],
        systemPrompt: '',
        providerSessionId: 'claude-session-x',
      );
      expect(resumeSpawns.last, containsAllInOrder(['--resume', 'claude-session-x']));
      expect(resumeSpawns.last, isNot(contains('--no-session-persistence')));
      expect(resumedResult.providerSessionId, 'claude-session-x');
    });

    test('ordinary turn keeps no-session-persistence and reports no provider id', () async {
      final spawns = <List<String>>[];
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          systemInitSessionId: 'unusable-session',
          onSpawn: (spawn) => spawns.add(spawn.args),
        ),
      );
      addTeardownAsync(() => harness.dispose());
      await harness.start();
      final result = await harness.turn(
        sessionId: 'ordinary',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      expect(spawns, hasLength(1));
      expect(spawns.single, contains('--no-session-persistence'));
      expect(spawns.single, isNot(contains('--resume')));
      expect(result.providerSessionId, isNull);
    });

    test('changing provider session id causes one restart', () async {
      final spawns = <List<String>>[];
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          systemInitSessionId: 'reported-session',
          onSpawn: (spawn) => spawns.add(spawn.args),
        ),
      );
      addTeardownAsync(() => harness.dispose());
      await harness.start();
      for (final providerSessionId in ['session-a', 'session-b']) {
        await harness.turn(
          sessionId: 'resume',
          messages: const [
            {'role': 'user', 'content': 'continue'},
          ],
          systemPrompt: '',
          providerSessionId: providerSessionId,
        );
      }
      expect(spawns, hasLength(3));
      expect(spawns[1], containsAllInOrder(['--resume', 'session-a']));
      expect(spawns[2], containsAllInOrder(['--resume', 'session-b']));
    });

    test('unknown provider session surfaces the Claude error message', () async {
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          result: const {
            'is_error': true,
            'subtype': 'error_during_execution',
            'num_turns': 0,
            'errors': ['No conversation found with session ID: missing'],
          },
        ),
      );
      addTeardownAsync(() => harness.dispose());
      await harness.start();
      final result = await harness.turn(
        sessionId: 'missing',
        messages: const [
          {'role': 'user', 'content': 'continue'},
        ],
        systemPrompt: '',
        providerSessionId: 'missing',
      );
      expect(result.isError, isTrue);
      expect(result.error, contains('No conversation found with session ID: missing'));
    });
  });
}
