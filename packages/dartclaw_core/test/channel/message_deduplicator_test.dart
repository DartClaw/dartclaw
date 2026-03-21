import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    hierarchicalLoggingEnabled = true;
  });
  group('MessageDeduplicator', () {
    group('tryProcess', () {
      test('returns true on first call for a resource name', () {
        final dedup = MessageDeduplicator();
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
      });

      test('returns false on duplicate resource name', () {
        final dedup = MessageDeduplicator();
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
        expect(dedup.tryProcess('spaces/A/messages/1'), isFalse);
      });

      test('returns true for different resource names', () {
        final dedup = MessageDeduplicator();
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
        expect(dedup.tryProcess('spaces/A/messages/2'), isTrue);
        expect(dedup.tryProcess('spaces/B/messages/1'), isTrue);
      });

      test('tracks length correctly', () {
        final dedup = MessageDeduplicator();
        expect(dedup.length, 0);
        dedup.tryProcess('spaces/A/messages/1');
        expect(dedup.length, 1);
        dedup.tryProcess('spaces/A/messages/2');
        expect(dedup.length, 2);
        // Duplicate does not increase length
        dedup.tryProcess('spaces/A/messages/1');
        expect(dedup.length, 2);
      });

      test('first-seen wins — duplicate returns false regardless of timing', () {
        final dedup = MessageDeduplicator();
        // Simulate webhook arriving first
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
        // Simulate Pub/Sub arriving second
        expect(dedup.tryProcess('spaces/A/messages/1'), isFalse);
        // And again
        expect(dedup.tryProcess('spaces/A/messages/1'), isFalse);
      });
    });

    group('LRU eviction', () {
      test('evicts oldest entry when capacity exceeded', () {
        final dedup = MessageDeduplicator(capacity: 3);
        dedup.tryProcess('spaces/A/messages/1');
        dedup.tryProcess('spaces/A/messages/2');
        dedup.tryProcess('spaces/A/messages/3');
        expect(dedup.length, 3);

        // Adding a 4th entry should evict the oldest (messages/1)
        expect(dedup.tryProcess('spaces/A/messages/4'), isTrue);
        expect(dedup.length, 3);

        // messages/1 was evicted — it's now seen as new
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
        // messages/2 was evicted to make room for messages/1
        expect(dedup.tryProcess('spaces/A/messages/2'), isTrue);
      });

      test('maintains exactly capacity entries', () {
        final dedup = MessageDeduplicator(capacity: 5);
        for (var i = 0; i < 100; i++) {
          dedup.tryProcess('spaces/A/messages/$i');
        }
        expect(dedup.length, 5);
      });

      test('eviction order is insertion order (oldest first)', () {
        final dedup = MessageDeduplicator(capacity: 3);
        dedup.tryProcess('spaces/A/messages/1'); // oldest
        dedup.tryProcess('spaces/A/messages/2');
        dedup.tryProcess('spaces/A/messages/3');
        // State: [1, 2, 3]

        // Duplicate of messages/2 does NOT promote it — still insertion order
        dedup.tryProcess('spaces/A/messages/2');

        // Adding messages/4 evicts messages/1 (oldest by insertion): state=[2,3,4]
        dedup.tryProcess('spaces/A/messages/4');

        // messages/1 was evicted — new addition evicts messages/2: state=[3,4,1]
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
        // messages/3 is still present
        expect(dedup.tryProcess('spaces/A/messages/3'), isFalse);
      });

      test('capacity of 1 allows only the most recent entry', () {
        final dedup = MessageDeduplicator(capacity: 1);
        dedup.tryProcess('spaces/A/messages/1');
        expect(dedup.length, 1);
        expect(dedup.tryProcess('spaces/A/messages/1'), isFalse);

        dedup.tryProcess('spaces/A/messages/2');
        expect(dedup.length, 1);
        // messages/1 was evicted
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
      });
    });

    group('capacity', () {
      test('default capacity is 1000', () {
        final dedup = MessageDeduplicator();
        expect(dedup.capacity, 1000);
      });

      test('custom capacity is respected', () {
        final dedup = MessageDeduplicator(capacity: 50);
        expect(dedup.capacity, 50);
      });

      test('capacity less than 1 is clamped to 1', () {
        final dedup = MessageDeduplicator(capacity: 0);
        expect(dedup.capacity, 1);
        final dedupNeg = MessageDeduplicator(capacity: -5);
        expect(dedupNeg.capacity, 1);
      });
    });

    group('clear', () {
      test('removes all tracked entries', () {
        final dedup = MessageDeduplicator();
        dedup.tryProcess('spaces/A/messages/1');
        dedup.tryProcess('spaces/A/messages/2');
        expect(dedup.length, 2);

        dedup.clear();
        expect(dedup.length, 0);
      });

      test('after clear, previously seen entries are treated as new', () {
        final dedup = MessageDeduplicator();
        dedup.tryProcess('spaces/A/messages/1');
        expect(dedup.tryProcess('spaces/A/messages/1'), isFalse);

        dedup.clear();
        expect(dedup.tryProcess('spaces/A/messages/1'), isTrue);
      });
    });

    group('logging', () {
      test('logs at fine level on duplicate detection', () {
        final dedup = MessageDeduplicator();
        final logs = <LogRecord>[];
        final sub = Logger('MessageDeduplicator').onRecord.listen(logs.add);
        addTearDown(sub.cancel);

        // Enable fine-level logging for the test
        final logger = Logger('MessageDeduplicator');
        final previousLevel = logger.level;
        logger.level = Level.FINE;
        addTearDown(() => logger.level = previousLevel);

        dedup.tryProcess('spaces/A/messages/1');
        expect(logs, isEmpty); // No log on first-seen

        dedup.tryProcess('spaces/A/messages/1');
        expect(logs, hasLength(1));
        expect(logs.first.level, Level.FINE);
        expect(logs.first.message, contains('spaces/A/messages/1'));
        expect(logs.first.message, contains('Duplicate'));
      });

      test('does not log on first-seen entries', () {
        final dedup = MessageDeduplicator();
        final logs = <LogRecord>[];
        final sub = Logger('MessageDeduplicator').onRecord.listen(logs.add);
        addTearDown(sub.cancel);

        final logger = Logger('MessageDeduplicator');
        final previousLevel = logger.level;
        logger.level = Level.FINE;
        addTearDown(() => logger.level = previousLevel);

        dedup.tryProcess('spaces/A/messages/1');
        dedup.tryProcess('spaces/A/messages/2');
        dedup.tryProcess('spaces/A/messages/3');
        expect(logs, isEmpty);
      });
    });
  });
}
