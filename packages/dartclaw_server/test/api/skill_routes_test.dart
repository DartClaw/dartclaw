import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show skillRoutes;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillRegistryImpl, SkillSource;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const dartclawSkillNames = <String>{
  'dartclaw-discover-project',
  'dartclaw-exec-spec',
  'dartclaw-plan',
  'dartclaw-quick-review',
  'dartclaw-refactor',
  'dartclaw-remediate-findings',
  'dartclaw-review',
  'dartclaw-review-code',
  'dartclaw-review-council',
  'dartclaw-review-doc',
  'dartclaw-review-gap',
  'dartclaw-spec',
  'dartclaw-spec-plan',
  'dartclaw-update-state',
  'dartclaw-validate',
};

void main() {
  late Directory tmpDir;
  late Directory workspaceDir;
  late Directory dataDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('skill_routes_test_');
    workspaceDir = Directory('${tmpDir.path}/workspace')..createSync();
    dataDir = Directory('${tmpDir.path}/data')..createSync();
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  SkillRegistryImpl makeRegistry({List<String> skillNames = const []}) {
    if (skillNames.isNotEmpty) {
      final wsSkills = Directory('${workspaceDir.path}/skills')..createSync(recursive: true);
      for (final name in skillNames) {
        final skillDir = Directory('${wsSkills.path}/$name')..createSync();
        File('${skillDir.path}/SKILL.md').writeAsStringSync('---\nname: $name\ndescription: $name description\n---\n');
      }
    }
    final registry = SkillRegistryImpl();
    registry.discover(
      workspaceDir: workspaceDir.path,
      dataDir: dataDir.path,
      userClaudeSkillsDir: '/nonexistent',
      userAgentsSkillsDir: '/nonexistent',
    );
    return registry;
  }

  group('GET /api/skills', () {
    test('returns discovered skills with metadata', () async {
      final registry = makeRegistry(skillNames: ['dartclaw-review-code', 'custom-implement']);
      final router = skillRoutes(registry);

      final response = await router.call(Request('GET', Uri.parse('http://localhost/api/skills')));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['count'], 2);

      final skills = (body['skills'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(skills, hasLength(2));

      final names = skills.map((s) => s['name'] as String).toSet();
      expect(names, containsAll(<String>['dartclaw-review-code', 'custom-implement']));

      // Each skill has required fields.
      for (final skill in skills) {
        expect(skill.containsKey('name'), isTrue);
        expect(skill.containsKey('description'), isTrue);
        expect(skill.containsKey('source'), isTrue);
      }
    });

    test('returns empty list when no skills discovered', () async {
      final registry = makeRegistry(); // no skills
      final router = skillRoutes(registry);

      final response = await router.call(Request('GET', Uri.parse('http://localhost/api/skills')));

      expect(response.statusCode, 200);

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['count'], 0);
      expect(body['skills'], isEmpty);
    });

    test('response includes count field matching skills length', () async {
      final registry = makeRegistry(skillNames: ['skill-a', 'skill-b', 'skill-c']);
      final router = skillRoutes(registry);

      final response = await router.call(Request('GET', Uri.parse('http://localhost/api/skills')));

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final skills = body['skills'] as List<dynamic>;
      expect(body['count'], skills.length);
      expect(body['count'], 3);
    });

    test('returns filesystem built-in skills when a built-in directory is present', () async {
      final builtInDir = Directory('${tmpDir.path}/built-ins')..createSync(recursive: true);
      for (final name in dartclawSkillNames) {
        final skillDir = Directory('${builtInDir.path}/$name')..createSync(recursive: true);
        File('${skillDir.path}/SKILL.md').writeAsStringSync('---\nname: $name\ndescription: $name description\n---\n');
      }

      final registry = makeRegistry();
      registry.discover(
        workspaceDir: workspaceDir.path,
        dataDir: dataDir.path,
        userClaudeSkillsDir: '/nonexistent',
        userAgentsSkillsDir: '/nonexistent',
        builtInSkillsDir: builtInDir.path,
      );
      final router = skillRoutes(registry);

      final response = await router.call(Request('GET', Uri.parse('http://localhost/api/skills')));
      expect(response.statusCode, 200);

      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final skills = (body['skills'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(body['count'], 15);
      expect(skills, hasLength(15));
      expect(skills.map((skill) => skill['name'] as String).toSet(), containsAll(dartclawSkillNames));
      expect(skills.every((skill) => skill['source'] == SkillSource.dartclaw.name), isTrue);
    });
  });
}
