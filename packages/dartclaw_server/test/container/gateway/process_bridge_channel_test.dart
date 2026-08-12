import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('retains a bounded tail of bridge stderr for the exit diagnostic', () async {
    final records = <LogRecord>[];
    final subscription = Logger('ProcessBridgeChannel').onRecord.listen(records.add);
    addTearDown(subscription.cancel);

    final process = FakeProcess();
    ProcessBridgeChannel(process, label: 'authority/provider');

    // A container-controlled stream: what it writes must not grow host memory.
    for (var i = 0; i < 200; i++) {
      process.emitStderr('x' * 1000);
    }
    process.emitStderr('loader: cannot execute bridge');
    await pumpEventQueue();
    process.exit(127);
    await pumpEventQueue();

    final warning = records.single.message;
    expect(warning, contains('exited with code 127'));
    expect(warning, contains('loader: cannot execute bridge'), reason: 'the fatal error is the last thing written');
    expect(warning.length, lessThan(ProcessBridgeChannel.stderrRetainedChars + 200));
  });
}
