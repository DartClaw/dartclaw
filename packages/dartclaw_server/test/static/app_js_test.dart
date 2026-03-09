import 'dart:io';

import 'package:test/test.dart';

void main() {
  final baseDir = File('packages/dartclaw_server/lib/src/static/app.js')
          .existsSync()
      ? 'packages/dartclaw_server/lib/src/static'
      : 'lib/src/static';

  final scriptPath = '$baseDir/app.js';

  group('app.js HTMX SSE lifecycle', () {
    test('defines initSseLifecycle function', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('function initSseLifecycle()'));
    });

    test('listens for htmx:sseClose event', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('htmx:sseClose'));
    });

    test('defines dartclaw.handleTurnError', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('dartclaw.handleTurnError'));
    });

    test('finalizeTurn is shared by done and turn_error paths', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('function finalizeTurn()'));
      // Both htmx:sseClose handler and handleTurnError call finalizeTurn
      final calls = 'finalizeTurn()'.allMatches(source).length;
      expect(calls,
          greaterThanOrEqualTo(3)); // definition + sseClose + handleTurnError
    });

    test('handles failed HTMX requests by re-enabling input', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('htmx:afterRequest'));
      expect(source, contains('if (event.detail.successful)'));
      expect(source, contains('enableInput();'));
    });

    test(
        'manual rename marks session as titled to prevent auto-title overwrite',
        () {
      final source = File(scriptPath).readAsStringSync();
      final matches =
          RegExp(r"dataset\.hasTitle\s*=\s*'true'").allMatches(source).length;
      expect(matches, greaterThanOrEqualTo(2));
    });
  });

  group('app.js no legacy EventSource code', () {
    test('does not contain native EventSource management', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, isNot(contains('activeSource')));
      expect(source, isNot(contains('parseSsePayload')));
      expect(source, isNot(contains('initSseConnectorHandling')));
      expect(source, isNot(contains('startStream(')));
      expect(source, isNot(contains('closeActiveStream')));
    });
  });

  group('app.js init idempotency guards', () {
    test('initThemeToggle checks dataset.themeInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('btn.dataset.themeInit'));
    });

    test('initSidebar guards menuToggle and closeBtn listeners', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('menuToggle.dataset.sidebarInit'));
      expect(source, contains('closeBtn.dataset.sidebarInit'));
    });

    test('initTextareaResize checks dataset.resizeInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('textarea.dataset.resizeInit'));
    });

    test('initSendButtonState checks dataset.sendInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('btn.dataset.sendInit'));
    });

    test('initInlineRename checks dataset.renameInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('input.dataset.renameInit'));
    });

    test('initKeyboardSubmit checks dataset.keyboardInit', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains('textarea.dataset.keyboardInit'));
    });

    test('initSettingsForm checks dataset.settingsInit (in settings.js)', () {
      final source = File('$baseDir/settings.js').readAsStringSync();
      expect(source, contains('form.dataset.settingsInit'));
    });
  });

  group('app.js delete confirmation uses safe DOM API', () {
    test(
        'confirmDeleteJob uses createElement not innerHTML for job name (in scheduling.js)',
        () {
      final source = File('$baseDir/scheduling.js').readAsStringSync();
      // Should use textContent and dataset for safe attribute assignment
      expect(source, contains("msg.textContent = \"Delete '\" + jobName"));
      expect(source, contains('confirmBtn.dataset.jobName = jobName'));
    });
  });

  group('memory dashboard (in memory.js)', () {
    test('initMemoryDefaultTab auto-loads active tab', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains('function initMemoryDefaultTab()'));
      expect(source, contains('switchMemoryTab(activeTab, tabId)'));
    });

    test('prune success uses htmx.ajax for immediate refresh', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains("htmx.ajax('GET', '/memory/content'"));
    });
  });

  group('app.js module split', () {
    test('page-specific module files exist', () {
      expect(File('$baseDir/settings.js').existsSync(), isTrue);
      expect(File('$baseDir/scheduling.js').existsSync(), isTrue);
      expect(File('$baseDir/memory.js').existsSync(), isTrue);
      expect(File('$baseDir/whatsapp.js').existsSync(), isTrue);
    });

    test('app.js does not contain extracted function bodies', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, isNot(contains('function initSettingsForm')));
      expect(source, isNot(contains('function toggleJobForm')));
      expect(source, isNot(contains('function switchMemoryTab')));
      expect(source, isNot(contains('function initQrFallback')));
    });

    test('settings.js contains settings functions', () {
      final source = File('$baseDir/settings.js').readAsStringSync();
      expect(source, contains('function initSettingsForm'));
      expect(source, contains('function activateSettingsTab'));
      expect(source, contains('function populateSettingsForm'));
      expect(source, contains('function handleFormSave'));
    });

    test('scheduling.js contains scheduling functions', () {
      final source = File('$baseDir/scheduling.js').readAsStringSync();
      expect(source, contains('function toggleJobForm'));
      expect(source, contains('function submitJobForm'));
      expect(source, contains('function editJob'));
      expect(source, contains('function confirmDeleteJob'));
      expect(source, contains('function cancelDeleteJob'));
    });

    test('memory.js contains memory functions', () {
      final source = File('$baseDir/memory.js').readAsStringSync();
      expect(source, contains('function initMemoryDefaultTab'));
      expect(source, contains('function switchMemoryTab'));
      expect(source, contains('function applyMemoryViewMode'));
      expect(source, contains('function toggleMemoryView'));
      expect(source, contains('function confirmPrune'));
      expect(source, contains('function initMemoryViewToggle'));
    });

    test('whatsapp.js contains WhatsApp functions', () {
      final source = File('$baseDir/whatsapp.js').readAsStringSync();
      expect(source, contains('function initQrFallback'));
      expect(source, contains('function initQrCountdown'));
    });

    test('app.js uses typeof guards for page-specific init calls', () {
      final source = File(scriptPath).readAsStringSync();
      expect(source, contains("typeof initSettingsForm === 'function'"));
      expect(source, contains("typeof initQrFallback === 'function'"));
      expect(source, contains("typeof initQrCountdown === 'function'"));
      expect(source, contains("typeof initMemoryDefaultTab === 'function'"));
      expect(source, contains("typeof initMemoryViewToggle === 'function'"));
      expect(source, contains("typeof toggleJobForm === 'function'"));
      expect(source, contains("typeof switchMemoryTab === 'function'"));
      expect(source, contains("typeof confirmPrune === 'function'"));
    });
  });
}
