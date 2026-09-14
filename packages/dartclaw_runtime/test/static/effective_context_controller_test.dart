import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';
import 'controller_test_support.dart';

void main() {
  test('context dialog traps and restores focus through the lifecycle controller', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('openContextDialog(event)'));
    expect(source, contains('dialog.showModal()'));
    expect(source, contains('handleContextDialogKeydown(event)'));
    expect(source, contains("event.key !== 'Tab'"));
    expect(source, contains('this.contextDialogReturnFocus?.focus()'));
    expect(source, contains("event.key === 'Escape'"));
  });

  test('context mutation posts the current revision and leaves the draft outside reconciliation', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('async applyContext(event)'));
    expect(source, contains('conversation_revision: this.conversationRevision'));
    expect(source, contains("'/context'"));
    expect(source, contains("result.error?.message || 'Context change was rejected'"));
    final method = source.substring(
      source.indexOf('async applyContext(event)'),
      source.indexOf('reconcileContext(snapshot)'),
    );
    expect(method, isNot(contains('this.textarea.value')));
  });

  test('authoritative reconciliation updates controls and projections before absorbing revision', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    final method = source.substring(
      source.indexOf('reconcileContext(snapshot)'),
      source.indexOf('handleContextDialogKeydown', source.indexOf('reconcileContext(snapshot)')),
    );
    expect(method, contains('snapshot.effective_context'));
    for (final field in const [
      'project.value',
      'directory.value',
      'provider.value',
      'model.disabled',
      'effort.disabled',
    ]) {
      expect(method, contains(field), reason: field);
    }
    for (final selector in const [
      '#effective-context-current',
      '#effective-context-next',
      '#effective-context-telemetry',
      '#effective-context-behavior',
      '#effective-context-memory',
    ]) {
      expect(method, contains(selector), reason: selector);
    }
    expect(
      method.indexOf('project.value = view.projectId'),
      lessThan(method.indexOf('this.conversationRevision = nextRevision')),
    );
    expect(method, isNot(contains('this.textarea')));
  });

  test('browser profile gates every S05 wireframe comparison by mismatch percentage', () async {
    final script = File(await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/run.sh'))
        .readAsStringSync();
    final comparison = File(
      await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/visual_comparison.sh'),
    ).readAsStringSync();
    expect(comparison, contains('compare_current_to_wireframe()'));
    expect(comparison, contains("find(result, 'mismatchPercentage')"));
    expect(comparison, contains("find(result, 'differentPixels')"));
    expect(comparison, contains("find(result, 'dimensionMismatch')"));
    final q9 = script.substring(
      script.indexOf('run_q9_effective_context()'),
      script.indexOf('run_e11_effective_context()'),
    );
    final e11 = script.substring(script.indexOf('run_e11_effective_context()'), script.lastIndexOf(r'case "${CASE}"'));
    for (final wireframe in const ['chat-conversation-cards', 'session-info-panel', 'new-session']) {
      expect(RegExp('compare_current_to_wireframe $wireframe').allMatches(q9).length, 1, reason: 'Q9 $wireframe');
      expect(RegExp('compare_current_to_wireframe $wireframe').allMatches(e11).length, 1, reason: 'E11 $wireframe');
    }
  });
}
