import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
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
    expect(await service.composeSystemPrompt(), BehaviorFileService.defaultPrompt);
  });

  test('returns global SOUL.md content', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('You are a pirate.');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(), 'You are a pirate.');
  });

  test('concatenates global and project SOUL.md', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global soul');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
    final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
    expect(await service.composeSystemPrompt(), 'Global soul\n\nProject soul');
  });

  test('composes all files in correct order', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global soul');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Project soul');
    File('${globalDir.path}/MEMORY.md').writeAsStringSync('Memory');
    final service = BehaviorFileService(workspaceDir: globalDir.path, projectDir: projectDir.path);
    expect(await service.composeSystemPrompt(), 'Global soul\n\nProject soul\n\nMemory');
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
    expect(await service.composeSystemPrompt(), BehaviorFileService.defaultPrompt);
  });

  test('skips file with permission error', () async {
    final soulFile = File('${globalDir.path}/SOUL.md')..writeAsStringSync('content');
    Process.runSync('chmod', ['000', soulFile.path]);
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(), BehaviorFileService.defaultPrompt);
    Process.runSync('chmod', ['644', soulFile.path]);
  }, testOn: 'mac-os || linux');

  test('only reads global files when projectDir is null', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Global only');
    File('${projectDir.path}/SOUL.md').writeAsStringSync('Should not appear');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(), 'Global only');
  });

  test('re-reads files on each call (live editing)', () async {
    final soulFile = File('${globalDir.path}/SOUL.md')..writeAsStringSync('Version 1');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    expect(await service.composeSystemPrompt(), 'Version 1');
    soulFile.writeAsStringSync('Version 2');
    expect(await service.composeSystemPrompt(), 'Version 2');
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

  test('prompt ordering: SOUL > USER > TOOLS > MEMORY', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('SOUL');
    File('${globalDir.path}/USER.md').writeAsStringSync('USER');
    File('${globalDir.path}/TOOLS.md').writeAsStringSync('TOOLS');
    File('${globalDir.path}/MEMORY.md').writeAsStringSync('MEMORY');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    final soulIdx = result.indexOf('SOUL');
    final userIdx = result.indexOf('## User Context');
    final toolsIdx = result.indexOf('## Environment Notes');
    final memIdx = result.lastIndexOf('MEMORY');
    expect(soulIdx, lessThan(userIdx));
    expect(userIdx, lessThan(toolsIdx));
    expect(toolsIdx, lessThan(memIdx));
  });

  test('missing USER.md and TOOLS.md do not error', () async {
    File('${globalDir.path}/SOUL.md').writeAsStringSync('Soul');
    final service = BehaviorFileService(workspaceDir: globalDir.path);
    final result = await service.composeSystemPrompt();
    expect(result, 'Soul');
    expect(result, isNot(contains('## User Context')));
    expect(result, isNot(contains('## Environment Notes')));
  });

  group('composeAppendPrompt', () {
    test('returns AGENTS.md content when present', () async {
      File('${globalDir.path}/AGENTS.md').writeAsStringSync('## Safety Rules\n- Do not harm');
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(), '## Safety Rules\n- Do not harm');
    });

    test('returns empty string when AGENTS.md is missing', () async {
      final service = BehaviorFileService(workspaceDir: globalDir.path);
      expect(await service.composeAppendPrompt(), isEmpty);
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
        final prompt = await service.composeSystemPrompt();
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
