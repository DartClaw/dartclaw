import 'package:dartclaw_runtime/src/runtime/reserved_command_handler.dart';
import 'package:test/test.dart';

void main() {
  group('isReservedChannelCommand', () {
    const reserved = [
      '/stop',
      '/STOP',
      '  /stop  ',
      '/stop now',
      'stop!',
      '/pause',
      '/pause please',
      '/resume',
      '/resume now',
      '/bind t-1',
      '/unbind',
      '/unbind t-1',
    ];

    for (final text in reserved) {
      test('admits "$text" ahead of rate limiting', () {
        expect(isReservedChannelCommand(text), isTrue);
      });
    }

    const ordinary = [
      '@advisor please review this',
      '@Advisor what do you think?',
      'hello',
      'task: fix login',
      'accept',
      '/stopwatch',
      '/bind',
      '/status',
      // A prefix match here skips per-sender rate limiting and pause queueing
      // while nothing consumes the message.
      '/statusreport dump everything',
      '/statuses',
      '/status dump everything',
      '/pauser',
      '/resumes',
    ];

    for (final text in ordinary) {
      test('treats "$text" as ordinary rate-limited text', () {
        expect(isReservedChannelCommand(text), isFalse);
      });
    }
  });
}
