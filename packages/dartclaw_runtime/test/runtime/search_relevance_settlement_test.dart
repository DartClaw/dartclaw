import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'headless_runtime_test_support.dart';

void main() {
  test('a relevance result waits for worker release before the next sequential request', () async {
    final root = Directory.systemTemp.createTempSync('relevance_settlement_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final fixture = HeadlessRuntimeFixture(root);
    final workers = <_DelayedRelevanceDisposalHarness>[];
    final factory = HarnessFactory()
      ..register('claude', (config) {
        if (config.cwd == '/') return FakeAgentHarness(supportsNoWorkTools: true, supportsStructuredOutput: true);
        final worker = _DelayedRelevanceDisposalHarness();
        workers.add(worker);
        return worker;
      });
    final config = fixture.config(
      agent: const AgentConfig(provider: 'claude', model: 'fixture-model'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
    );
    final runtime = await fixture.runtime(config, harnessFactory: factory);
    addTearDown(() {
      for (final worker in workers) {
        if (!worker.allowDisposal.isCompleted) worker.allowDisposal.complete();
      }
    });
    const schema = {
      'type': 'object',
      'properties': {
        '0': {'type': 'boolean'},
      },
      'required': ['0'],
      'additionalProperties': false,
    };
    var returned = false;
    final first = runtime.requireSearchRelevanceTurn('judge', schema).then((value) {
      returned = true;
      return value;
    });
    await waitFor(() => workers.isNotEmpty && workers.first.hasPendingTurn);
    workers.first.completeSuccess(const TurnResult(structuredOutput: {'0': true}));
    await workers.first.disposalStarted.future;
    await pumpEventQueue();
    expect(returned, isFalse, reason: 'A terminal model reply does not make its capacity available yet.');
    workers.first.allowDisposal.complete();
    expect(await first, {'0': true});
    expect(runtime.requireExecutions.snapshot.availableWorkers, 1);

    final second = runtime.requireSearchRelevanceTurn('judge again', schema);
    await waitFor(() => workers.length == 2 && workers.last.hasPendingTurn);
    workers.last.completeSuccess(const TurnResult(structuredOutput: {'0': false}));
    workers.last.allowDisposal.complete();
    expect(await second, {'0': false});
    expect(runtime.requireExecutions.snapshot.availableWorkers, 1);
  });
}

final class _DelayedRelevanceDisposalHarness extends FakeAgentHarness {
  new() : super(supportsNoWorkTools: true, supportsStructuredOutput: true);
  final disposalStarted = Completer<void>();
  final allowDisposal = Completer<void>();

  @override
  Future<void> dispose() async {
    if (!disposalStarted.isCompleted) disposalStarted.complete();
    await allowDisposal.future;
    await super.dispose();
  }
}
