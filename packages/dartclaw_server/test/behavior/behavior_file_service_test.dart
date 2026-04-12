import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show PromptScope;
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory globalDir;
  late Directory projectDir;

  setUp(() {
    globalDir = Directory.systemTemp.createTempSync('behavior_test_global');
    projectDir = Directory.systemTemp.createTempSync('behavior_test_project');
  });

  tearDown(() {
    globalDir.deleteSync(recursive: true);
    projectDir.deleteSync(recursive: true);
  });

  test('returns hardcoded default when no files exist', () async {
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    // Use task scope to suppress compact instructions and test core default
    expect(await service.composeSystemPrompt(scope: PromptScope.task), BehaviorFileService.defaultPrompt);
  });

  test('missing optional files do not emit warning logs', () async {
    final warnings = <String>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger('BehaviorFileService').onRecord.listen((record) {
      if (record.level >= Level.WARNING) {
        warnings.add(record.message);
      }
    });
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = previousLevel;
    });

    final service = BehaviorFileService(workspaceDir: globalDir.path);
    await service.composeSystemPrompt();

    expect(warnings, isEmpty);
  });

  test('returns global SOUL.md content', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('You are a pirate.');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(scope: PromptScope.task), 'You are a pirate.');
  });

  test('project SOUL.md is not included (deprecated)', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global soul');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
    final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
    final result = await service.composeSystemPrompt(scope: PromptScope.task);
    expect(result, 'Global soul');
    expect(result, isNot(contains('Project soul')));
  });

  test('task scope: SOUL.md + TOOLS.md, no MEMORY', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global soul');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
    File('${globalDir.path}/MEMORY.md').writeAsStringSync('Memory');
    final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
    final result = await service.composeSystemPrompt(scope: PromptScope.task);
    expect(result, 'Global soul');
    expect(result, isNot(contains('Memory')));
    expect(result, isNot(contains('Project soul')));
  });

  test('includes MEMORY.md in prompt', () async {
    File('${globalDir.path}/MEMORY.md').writeAsStringSync('Remember: user likes Dart');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, contains('Remember: user likes Dart'));
  });

  test('skips non-UTF-8 file gracefully', () async {
    File('${globalDir.path}/SOUL.md').writeAsBytesSync([0xFF, 0xFE]);
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(scope: PromptScope.task), BehaviorFileService.defaultPrompt);
  });

  test('skips file with permission error', () async {
    final soulFile = File('${globalDir.path}/SOUL.md')..writeAsStringSync('content');
    Process.runSync('chmod', ['000', soulFile.path]);
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(scope: PromptScope.task), BehaviorFileService.defaultPrompt);
    Process.runSync('chmod', ['644', soulFile.path]);
  }, testOn: 'mac-os || linux');

  test('only reads workspace SOUL.md (project SOUL.md never included)', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global only');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Should not appear');
    // Even with projectDir set, project SOUL.md is not included
    final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
    expect(await service.composeSystemPrompt(scope: PromptScope.task), 'Global only');
  });

  test('re-reads files on each call (live editing)', () async {
    final soulFile = File('${globalDir.path}/SOUL.md')..writeAsStringSync('Version 1');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(scope: PromptScope.task), 'Version 1');
    soulFile.writeAsStringSync('Version 2');
    expect(await service.composeSystemPrompt(scope: PromptScope.task), 'Version 2');
  });

  test('includes USER.md in prompt when present', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
    File('${globalDir.path}/USER.md').writeAsStringSync('Timezone: UTC+2');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, contains('## User Context'));
    expect(result, contains('Timezone: UTC+2'));
  });

  test('includes TOOLS.md in prompt when present', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
    File('${globalDir.path}/TOOLS.md').writeAsStringSync('SSH: server.local');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, contains('## Environment Notes'));
    expect(result, contains('SSH: server.local'));
  });

  test('prompt ordering: SOUL > USER > TOOLS > errors > learnings > MEMORY', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
    File('${globalDir.path}/USER.md').writeAsStringSync('USER');
    File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
    File('${globalDir.path}/errors.md').writeAsStringSync('## [2025-01-01] TEST\n');
    File('${globalDir.path}/learnings.md').writeAsStringSync('- [2025-01-01] lesson\n');
    File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    final soulIdx = result.indexOf('SOUL');
    final userIdx = result.indexOf('## User Context');
    final toolsIdx = result.indexOf('## Environment Notes');
    final errorsIdx = result.indexOf('## Recent Errors');
    final learningsIdx = result.indexOf('## Learnings');
    final memIdx = result.lastIndexOf('MEMORY');
    expect(soulIdx, lessThan(userIdx));
    expect(userIdx, lessThan(toolsIdx));
    expect(toolsIdx, lessThan(errorsIdx));
    expect(errorsIdx, lessThan(learningsIdx));
    expect(learningsIdx, lessThan(memIdx));
  });

  test('includes errors.md with header in system prompt', () async {
    File('${globalDir.path}/errors.md').writeAsStringSync('## [2025-01-01] GUARD_BLOCK\n- Session: s1\n');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, contains('## Recent Errors'));
    expect(result, contains('GUARD_BLOCK'));
  });

  test('includes learnings.md with header in system prompt', () async {
    File('${globalDir.path}/learnings.md').writeAsStringSync('- [2025-01-01] Always validate input\n');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, contains('## Learnings'));
    expect(result, contains('Always validate input'));
  });

  test('omits errors.md header when file is empty', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, isNot(contains('## Recent Errors')));
    expect(result, isNot(contains('## Learnings')));
  });

  test('missing USER.md and TOOLS.md do not error', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    // Use task scope to suppress compact instructions and user context for exact match
    final result = await service.composeSystemPrompt(scope: PromptScope.task);
    expect(result, 'Soul');
    expect(result, isNot(contains('## User Context')));
    expect(result, isNot(contains('## Environment Notes')));
  });

  group('compact instructions', () {
    test('interactive scope includes default compact instructions', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt();
      expect(result, contains('# Compact instructions'));
      expect(result, contains('When compacting context, preserve:'));
    });

    test('interactive scope includes custom compact instructions', () async {
      final service = BehaviorFileService(
        workspaceDir: globalDir.path,
        compactInstructions: 'Custom instructions here',
      );
      final result = await service.composeSystemPrompt();
      expect(result, contains('Custom instructions here'));
      expect(result, isNot(contains('When compacting context, preserve:')));
    });

    test('task scope skips compact instructions', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.task);
      expect(result, isNot(contains('# Compact instructions')));
    });

    test('restricted scope skips compact instructions', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.restricted);
      expect(result, isNot(contains('# Compact instructions')));
    });

    test('evaluator scope skips compact instructions', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.evaluator);
      expect(result, isNot(contains('# Compact instructions')));
    });

    test('no-arg call (interactive) includes compact instructions', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt();
      expect(result, contains('# Compact instructions'));
    });

    test('compact instructions appear after MEMORY.md', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul content');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('Memory content');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt();
      final memIdx = result.indexOf('Memory content');
      final compactIdx = result.indexOf('# Compact instructions');
      expect(memIdx, lessThan(compactIdx));
    });

    group('identifier preservation', () {
      test('strict mode appends default identifier preservation text', () async {
        final service = BehaviorFileService(workspaceDir: globalDir.path, identifierPreservation: 'strict');
        final result = await service.composeSystemPrompt();
        expect(result, contains(BehaviorFileService.defaultIdentifierPreservationText));
      });

      test('strict is the default — identifier text present when not specified', () async {
        final service = BehaviorFileService(workspaceDir: globalDir.path);
        final result = await service.composeSystemPrompt();
        expect(result, contains(BehaviorFileService.defaultIdentifierPreservationText));
      });

      test('off mode omits identifier preservation text', () async {
        final service = BehaviorFileService(workspaceDir: globalDir.path, identifierPreservation: 'off');
        final result = await service.composeSystemPrompt();
        expect(result, isNot(contains(BehaviorFileService.defaultIdentifierPreservationText)));
      });

      test('custom mode appends custom identifier instructions', () async {
        const customText = 'Preserve all order IDs and SKUs verbatim.';
        final service = BehaviorFileService(
          workspaceDir: globalDir.path,
          identifierPreservation: 'custom',
          identifierInstructions: customText,
        );
        final result = await service.composeSystemPrompt();
        expect(result, contains(customText));
        expect(result, isNot(contains(BehaviorFileService.defaultIdentifierPreservationText)));
      });

      test('custom mode with null identifierInstructions omits identifier text', () async {
        final service = BehaviorFileService(
          workspaceDir: globalDir.path,
          identifierPreservation: 'custom',
          // identifierInstructions: null (default)
        );
        final result = await service.composeSystemPrompt();
        expect(result, isNot(contains(BehaviorFileService.defaultIdentifierPreservationText)));
      });

      test('identifier text appended to compact instructions, not a standalone section', () async {
        const customText = 'Keep IDs intact.';
        final service = BehaviorFileService(
          workspaceDir: globalDir.path,
          identifierPreservation: 'custom',
          identifierInstructions: customText,
        );
        final result = await service.composeSystemPrompt();
        // Both appear, and custom text appears after compact instructions header
        final compactIdx = result.indexOf('# Compact instructions');
        final customIdx = result.indexOf(customText);
        expect(compactIdx, lessThan(customIdx));
      });

      test('identifier text not included for task scope', () async {
        final service = BehaviorFileService(workspaceDir: globalDir.path, identifierPreservation: 'strict');
        final result = await service.composeSystemPrompt(scope: PromptScope.task);
        expect(result, isNot(contains(BehaviorFileService.defaultIdentifierPreservationText)));
      });
    });
  });

  group('composeAppendPrompt', () {
    test('returns AGENTS.md content for interactive scope', () async {
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Safety Rules\n- Do not harm');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(), '## Safety Rules\n- Do not harm');
    });

    test('returns AGENTS.md content for task scope', () async {
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Safety Rules\n- Do not harm');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(scope: PromptScope.task), '## Safety Rules\n- Do not harm');
    });

    test('returns empty string for restricted scope', () async {
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Safety Rules\n- Do not harm');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(scope: PromptScope.restricted), isEmpty);
    });

    test('returns empty string for evaluator scope', () async {
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Safety Rules\n- Do not harm');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(scope: PromptScope.evaluator), isEmpty);
    });

    test('returns empty string when AGENTS.md is missing', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(), isEmpty);
    });
  });

  group('composeStaticPrompt', () {
    test('includes SOUL, USER, TOOLS, AGENTS but not MEMORY', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul content');
      File('${globalDir.path}/USER.md').writeAsStringSync('User prefs');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('Tool info');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Agent rules');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('Secret memory data');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt();
      expect(result, contains('Soul content'));
      expect(result, contains('User prefs'));
      expect(result, contains('Tool info'));
      expect(result, contains('## Agent rules'));
      expect(result, isNot(contains('Secret memory data')));
      expect(result, contains('memory_read tool'));
    });

    test('uses default prompt when no SOUL.md exists', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt();
      expect(result, contains(BehaviorFileService.defaultPrompt));
      expect(result, contains('memory_read tool'));
    });

    test('uses only workspace SOUL.md (project SOUL.md not included)', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Global');
      File('${projectDir.path}/SOUL.md').writeAsStringSync('Project');
      final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
      final result = await service.composeStaticPrompt();
      expect(result, contains('Global'));
      expect(result, isNot(contains('Project soul')));
    });

    test('includes errors.md and learnings.md in static prompt', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
      File('${globalDir.path}/errors.md').writeAsStringSync('## [2025-01-01] ERR\n');
      File('${globalDir.path}/learnings.md').writeAsStringSync('- [2025-01-01] lesson\n');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt();
      expect(result, contains('## Recent Errors'));
      expect(result, contains('## Learnings'));
    });

    test('works with only SOUL.md (no optional files)', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Minimal soul');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt();
      expect(result, contains('Minimal soul'));
      expect(result, isNot(contains('## User Context')));
      expect(result, isNot(contains('## Environment Notes')));
      expect(result, contains('memory_read tool'));
    });

    test('task scope includes SOUL, TOOLS, AGENTS, and memory hint but excludes user state and recent notes', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul prompt');
      File('${globalDir.path}/USER.md').writeAsStringSync('User prompt');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('Tool prompt');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Agent prompt');
      File('${globalDir.path}/errors.md').writeAsStringSync('## Recent error');
      File('${globalDir.path}/learnings.md').writeAsStringSync('## Recent learning');

      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt(scope: PromptScope.task);

      expect(result, contains('Soul prompt'));
      expect(result, contains('Tool prompt'));
      expect(result, contains('## Agent prompt'));
      expect(result, contains('memory_read tool'));
      expect(result, isNot(contains('User prompt')));
      expect(result, isNot(contains('## Recent error')));
      expect(result, isNot(contains('## Recent learning')));
    });

    test('task scope orders SOUL before TOOLS before AGENTS before memory hint', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul prompt');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('Tool prompt');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Agent prompt');

      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt(scope: PromptScope.task);

      final soulIdx = result.indexOf('Soul prompt');
      final toolsIdx = result.indexOf('Tool prompt');
      final agentsIdx = result.indexOf('## Agent prompt');
      final memoryIdx = result.indexOf('memory_read tool');

      expect(soulIdx, lessThan(toolsIdx));
      expect(toolsIdx, lessThan(agentsIdx));
      expect(agentsIdx, lessThan(memoryIdx));
    });

    test('restricted scope includes TOOLS and memory hint only', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul prompt');
      File('${globalDir.path}/USER.md').writeAsStringSync('User prompt');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('Tool prompt');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Agent prompt');

      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt(scope: PromptScope.restricted);

      expect(result, contains('Tool prompt'));
      expect(result, contains('memory_read tool'));
      expect(result, isNot(contains('Soul prompt')));
      expect(result, isNot(contains('User prompt')));
      expect(result, isNot(contains('## Agent prompt')));
    });

    test('evaluator scope includes only the default prompt and memory hint', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul prompt');
      File('${globalDir.path}/USER.md').writeAsStringSync('User prompt');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('Tool prompt');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Agent prompt');
      File('${globalDir.path}/errors.md').writeAsStringSync('## Recent error');
      File('${globalDir.path}/learnings.md').writeAsStringSync('## Recent learning');

      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeStaticPrompt(scope: PromptScope.evaluator);

      expect(result, contains(BehaviorFileService.defaultPrompt));
      expect(result, contains('memory_read tool'));
      expect(result, isNot(contains('Soul prompt')));
      expect(result, isNot(contains('User prompt')));
      expect(result, isNot(contains('Tool prompt')));
      expect(result, isNot(contains('## Agent prompt')));
      expect(result, isNot(contains('## Recent error')));
      expect(result, isNot(contains('## Recent learning')));
    });
  });

  group('scope-aware composition', () {
    test('interactive scope includes SOUL, USER, TOOLS, errors, learnings, MEMORY, compact instructions', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
      File('${globalDir.path}/USER.md').writeAsStringSync('USER');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
      File('${globalDir.path}/errors.md').writeAsStringSync('## [2025-01-01] ERR\n');
      File('${globalDir.path}/learnings.md').writeAsStringSync('- [2025-01-01] lesson\n');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.interactive);
      expect(result, contains('SOUL'));
      expect(result, contains('## User Context'));
      expect(result, contains('## Environment Notes'));
      expect(result, contains('## Recent Errors'));
      expect(result, contains('## Learnings'));
      expect(result, contains('MEMORY'));
      expect(result, contains('# Compact instructions'));
    });

    test('task scope includes SOUL + TOOLS, excludes USER, errors, learnings, MEMORY, compact instructions', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
      File('${globalDir.path}/USER.md').writeAsStringSync('USER');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
      File('${globalDir.path}/errors.md').writeAsStringSync('## [2025-01-01] ERR\n');
      File('${globalDir.path}/learnings.md').writeAsStringSync('- [2025-01-01] lesson\n');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.task);
      expect(result, contains('SOUL'));
      expect(result, contains('## Environment Notes'));
      expect(result, isNot(contains('## User Context')));
      expect(result, isNot(contains('## Recent Errors')));
      expect(result, isNot(contains('## Learnings')));
      expect(result, isNot(contains('MEMORY')));
      expect(result, isNot(contains('# Compact instructions')));
    });

    test('restricted scope includes only TOOLS.md, no SOUL, no MEMORY', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
      File('${globalDir.path}/USER.md').writeAsStringSync('USER');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.restricted);
      expect(result, contains('## Environment Notes'));
      expect(result, isNot(contains('SOUL')));
      expect(result, isNot(contains('MEMORY')));
      expect(result, isNot(contains('## User Context')));
      expect(result, isNot(contains('# Compact instructions')));
    });

    test('restricted scope returns default prompt when TOOLS.md is missing', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.restricted);
      expect(result, BehaviorFileService.defaultPrompt);
    });

    test('evaluator scope returns only default prompt regardless of workspace files', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
      File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('AGENTS');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final result = await service.composeSystemPrompt(scope: PromptScope.evaluator);
      expect(result, BehaviorFileService.defaultPrompt);
    });

    test('no-arg call produces identical output to explicit interactive scope', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
      File('${globalDir.path}/MEMORY.md').writeAsStringSync('Memory');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      final noArg = await service.composeSystemPrompt();
      final explicit = await service.composeSystemPrompt(scope: PromptScope.interactive);
      expect(noArg, explicit);
    });
  });

  group('project SOUL.md deprecation', () {
    test('logs deprecation warning when project SOUL.md exists', () async {
      File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
      final warnings = <String>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger('BehaviorFileService').onRecord.listen((record) {
        if (record.level >= Level.WARNING) warnings.add(record.message);
      });
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = previousLevel;
      });
      final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
      await service.composeSystemPrompt();
      expect(warnings.any((w) => w.contains('SOUL.md') && w.contains('no longer read')), isTrue);
    });

    test('project SOUL.md content is not included in any scope', () async {
      File('${globalDir.path}/SOUL.md').writeAsStringSync('Workspace soul');
      File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul — must not appear');
      final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
      for (final scope in PromptScope.values) {
        final result = await service.composeSystemPrompt(scope: scope);
        expect(result, isNot(contains('Project soul')), reason: 'scope=$scope should not include project SOUL.md');
      }
    });

    test('deprecation warning logged at most once per service instance', () async {
      File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
      final warnings = <String>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger('BehaviorFileService').onRecord.listen((record) {
        if (record.level >= Level.WARNING && record.message.contains('SOUL.md')) {
          warnings.add(record.message);
        }
      });
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = previousLevel;
      });
      final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
      await service.composeSystemPrompt();
      await service.composeSystemPrompt();
      await service.composeSystemPrompt();
      expect(warnings.length, 1);
    });
  });

  group('memory truncation', () {
    test('MEMORY.md under cap — returned in full', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        final content = '## Entry 1\nSome memory content\n';
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: 10000);
        final prompt = await service.composeSystemPrompt();
        expect(prompt, contains(content.trim()));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md over cap with ## headers — truncated at header boundary', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        // Create content with multiple sections; \n## boundary requires leading newline
        final section1 = '## Old Entry\nThis is old content that should be truncated.\n';
        final section2 = '## Recent Entry\nThis is recent content that should be kept.\n';
        final content = '$section1$section2';
        memFile.writeAsStringSync(content);

        // Cap smaller than total but larger than section2
        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: section2.length + 5);
        final prompt = await service.composeSystemPrompt();
        expect(prompt, contains('## Recent Entry'));
        expect(prompt, isNot(contains('## Old Entry')));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md over cap without headers — truncated at raw byte offset', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        final content = 'A' * 200;
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: 100);
        final prompt = await service.composeSystemPrompt();
        // Default prompt is prepended (no SOUL.md), so check the A's portion
        expect(prompt, contains('A' * 100));
        expect(prompt, isNot(contains('A' * 200)));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md exactly at cap — not truncated', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        final content = '## Entry\nExact size content\n';
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: utf8.encode(content).length);
        final prompt = await service.composeSystemPrompt();
        expect(prompt, contains(content.trim()));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md with emoji content — no RangeError on truncation', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        // Each emoji is 4 UTF-8 bytes but 2 UTF-16 code units
        final content = '🎉' * 100; // 400 UTF-8 bytes, 200 code units
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(
          workspaceDir: dir.path,
          maxMemoryBytes: 80, // keep ~20 emoji
        );
        // Use task scope to suppress compact instructions for precise byte check
        final prompt = await service.composeSystemPrompt(scope: PromptScope.task);
        // Should not throw, and result should be within bounds
        final resultBytes = utf8.encode(prompt).length;
        expect(resultBytes, lessThanOrEqualTo(utf8.encode(BehaviorFileService.defaultPrompt).length + 2 + 80));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md with CJK content — truncates without corruption', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        // CJK chars are 3 UTF-8 bytes each
        final content = '漢字テスト' * 50; // 750 UTF-8 bytes
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: 150);
        final prompt = await service.composeSystemPrompt();
        // Verify the truncated portion is valid UTF-8 (no decode errors)
        expect(() => utf8.encode(prompt), returnsNormally);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('MEMORY.md with mixed ASCII/emoji and ## headers — boundary-aware', () async {
      final dir = Directory.systemTemp.createTempSync('dartclaw_behavior_trunc_');
      try {
        final memFile = File('${dir.path}/MEMORY.md');
        final section1 = '## Old 🎉\nOld emoji content 🌍🌎🌏\n';
        final section2 = '## New ✨\nNew sparkle content\n';
        final content = '$section1$section2';
        memFile.writeAsStringSync(content);

        final service = BehaviorFileService(workspaceDir: dir.path, maxMemoryBytes: utf8.encode(section2).length + 10);
        final prompt = await service.composeSystemPrompt();
        expect(prompt, contains('## New'));
        expect(prompt, isNot(contains('## Old')));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
