import 'package:dartclaw_core/src/harness/codex_settings.dart';
import 'package:test/test.dart';

void main() {
  group('CodexSettings', () {
    test('translateSandbox maps documented YAML values to Codex values', () {
      expect(CodexSettings.translateSandbox('workspace-write'), 'workspaceWrite');
      expect(CodexSettings.translateSandbox('danger-full-access'), 'dangerFullAccess');
      expect(CodexSettings.translateSandbox(' workspace-write '), 'workspaceWrite');
      expect(CodexSettings.translateSandbox(null), isNull);
      expect(CodexSettings.translateSandbox('   '), isNull);
      expect(CodexSettings.translateSandbox('unknown-value'), isNull);
    });

    test('translateApproval maps documented YAML values to Codex values', () {
      expect(CodexSettings.translateApproval('on-request'), 'on-request');
      expect(CodexSettings.translateApproval('unless-allow-listed'), 'granular');
      expect(CodexSettings.translateApproval('never'), 'never');
      expect(CodexSettings.translateApproval(' on-request '), 'on-request');
      expect(CodexSettings.translateApproval(null), isNull);
      expect(CodexSettings.translateApproval('   '), isNull);
      expect(CodexSettings.translateApproval('unknown-value'), isNull);
    });

    test('buildDynamicSettings includes only non-null fields', () {
      expect(CodexSettings.buildDynamicSettings(model: 'gpt-5', cwd: '/tmp/workspace'), {
        'model': 'gpt-5',
        'cwd': '/tmp/workspace',
      });
    });

    test('buildDynamicSettings applies sandbox and approval translation', () {
      expect(
        CodexSettings.buildDynamicSettings(
          model: 'gpt-5',
          cwd: '/tmp/workspace',
          sandbox: 'workspace-write',
          approval: 'on-request',
        ),
        {'model': 'gpt-5', 'cwd': '/tmp/workspace', 'sandbox': 'workspaceWrite', 'approval_policy': 'on-request'},
      );
    });

    test('buildDynamicSettings filters blank and unknown values', () {
      expect(
        CodexSettings.buildDynamicSettings(model: '  ', cwd: '\t', sandbox: 'unknown-value', approval: 'not-real'),
        isEmpty,
      );
    });
  });
}
