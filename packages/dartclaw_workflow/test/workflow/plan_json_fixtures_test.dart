import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('plan.json fixtures', () {
    test('synthetic pending-story fixture has one null FIS story', () {
      final plan = _loadJson('packages/dartclaw_workflow/test/fixtures/plan_json_with_pending_story.json');

      expect(plan['schemaVersion'], '1');
      final stories = plan['stories'] as List<dynamic>;
      expect(stories, hasLength(3));
      expect(stories.where((story) => (story as Map<String, dynamic>)['fis'] == null), hasLength(1));
      expect((plan['metadata'] as Map<String, dynamic>)['immutableDigest'], startsWith('sha256:'));
    });

    test('synthetic parallel-story fixture carries all optional story_specs fields', () {
      final plan = _loadJson('packages/dartclaw_workflow/test/fixtures/plan_json_with_parallel_story.json');

      expect(plan['schemaVersion'], '1');
      final stories = plan['stories'] as List<dynamic>;
      final parallelStory = stories.cast<Map<String, dynamic>>().singleWhere((story) => story['parallel'] == true);
      expect(
        parallelStory,
        allOf(
          containsPair('wave', 'W1'),
          containsPair('phase', 'P1'),
          containsPair('risk', 'medium'),
          containsPair('status', 'spec-ready'),
          containsPair('fis', 'fis/s01-parallel-foundation.md'),
        ),
      );
      expect((plan['metadata'] as Map<String, dynamic>)['immutableDigest'], startsWith('sha256:'));
    });

    test('sample plan beside the FIS parses with expected story IDs', () {
      final plan = _loadJson('packages/dartclaw_workflow/test/fixtures/s-plan-json-adoption-sample-plan.json');

      expect(plan['schemaVersion'], '1');
      final stories = (plan['stories'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(stories.map((story) => story['id']), ['S01', 'S02', 'S04', 'S05']);
      expect(stories.every((story) => story['fis'] is String), isTrue);
    });
  });
}

Map<String, dynamic> _loadJson(String repoRelativePath) {
  final file = File(p.join(_repoRoot(), repoRelativePath));
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

String _repoRoot() {
  var current = Directory.current;
  while (true) {
    if (File(p.join(current.path, 'AGENTS.md')).existsSync() &&
        Directory(p.join(current.path, 'packages', 'dartclaw_workflow')).existsSync()) {
      return current.path;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate repository root');
    }
    current = parent;
  }
}
