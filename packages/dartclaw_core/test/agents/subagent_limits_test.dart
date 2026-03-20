import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('SubagentLimits', () {
    test('canSpawn allows when below all limits', () {
      final limits = SubagentLimits(maxConcurrent: 3, maxSpawnDepth: 2, maxChildrenPerAgent: 2);
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isTrue);
    });

    test('canSpawn denies when at maxConcurrent', () {
      final limits = SubagentLimits(maxConcurrent: 2);
      limits.recordSpawn('main');
      limits.recordSpawn('main');
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isFalse);
    });

    test('canSpawn denies when at maxSpawnDepth', () {
      final limits = SubagentLimits(maxSpawnDepth: 1);
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 1), isFalse);
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isTrue);
    });

    test('canSpawn denies when at maxChildrenPerAgent', () {
      final limits = SubagentLimits(maxChildrenPerAgent: 1, maxConcurrent: 10);
      limits.recordSpawn('main');
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isFalse);
      // Different parent still ok
      expect(limits.canSpawn(parentAgentId: 'other', currentDepth: 0), isTrue);
    });

    test('recordComplete frees slot', () {
      final limits = SubagentLimits(maxConcurrent: 1, maxChildrenPerAgent: 1);
      limits.recordSpawn('main');
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isFalse);

      limits.recordComplete('main');
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isTrue);
      expect(limits.totalActive, 0);
    });

    test('reset clears all state', () {
      final limits = SubagentLimits(maxConcurrent: 2);
      limits.recordSpawn('main');
      limits.recordSpawn('main');
      expect(limits.totalActive, 2);

      limits.reset();
      expect(limits.totalActive, 0);
      expect(limits.canSpawn(parentAgentId: 'main', currentDepth: 0), isTrue);
    });

    test('totalActive does not go negative', () {
      final limits = SubagentLimits();
      limits.recordComplete('main');
      expect(limits.totalActive, 0);
    });
  });
}
