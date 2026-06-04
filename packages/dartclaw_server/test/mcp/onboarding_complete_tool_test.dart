import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/onboarding_complete_tool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late OnboardingCompleteTool tool;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('onboarding_complete_tool_test_');
    tool = OnboardingCompleteTool(workspaceDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('removes active ONBOARDING.md', () async {
    final sentinel = File(p.join(tempDir.path, 'ONBOARDING.md'))..writeAsStringSync('onboarding');

    final result = await tool.call({});

    expect(result, isA<ToolResultText>());
    expect((result as ToolResultText).content, contains('Onboarding complete'));
    expect(sentinel.existsSync(), isFalse);
  });

  test('returns descriptive no-op when ONBOARDING.md is absent', () async {
    final result = await tool.call({});

    expect(result, isA<ToolResultText>());
    expect((result as ToolResultText).content, contains('already complete'));
    expect(Directory(tempDir.path).listSync(), isEmpty);
  });

  group('S-02 onboarding scope gate', () {
    test('refuses to act when onboardingActive is false', () async {
      final sentinel = File(p.join(tempDir.path, 'ONBOARDING.md'))..writeAsStringSync('onboarding');
      final inactiveTool = OnboardingCompleteTool(workspaceDir: tempDir.path, onboardingActive: false);

      final result = await inactiveTool.call({});

      expect(result, isA<ToolResultText>());
      expect(
        (result as ToolResultText).content,
        contains('not available'),
        reason: 'tool must refuse when not in an onboarding-eligible context',
      );
      // Sentinel must not have been deleted.
      expect(sentinel.existsSync(), isTrue, reason: 'ONBOARDING.md must survive a refused call');
    });

    test('onboardingActive defaults to true for backward-compatibility', () async {
      File(p.join(tempDir.path, 'ONBOARDING.md')).writeAsStringSync('onboarding');
      final defaultTool = OnboardingCompleteTool(workspaceDir: tempDir.path);
      final result = await defaultTool.call({});
      expect((result as ToolResultText).content, contains('Onboarding complete'));
    });

    test('onboardingActive false blocks even when ONBOARDING.md absent', () async {
      final inactiveTool = OnboardingCompleteTool(workspaceDir: tempDir.path, onboardingActive: false);
      final result = await inactiveTool.call({});
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('not available'));
    });
  });
}
