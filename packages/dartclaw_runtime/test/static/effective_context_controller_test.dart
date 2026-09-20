import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';
import 'controller_test_support.dart';

void main() {
  test('the context popover traps and restores focus through the lifecycle controller', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('openContextPopover(event)'));
    expect(source, contains('handleContextDialogKeydown(event)'));
    expect(source, contains("event.key !== 'Tab'"));
    expect(source, contains('this.contextPopoverReturnFocus?.focus()'));
    expect(source, contains("event.key === 'Escape'"));
    // Anchored to the chip, not a modal: a modal steals the transcript behind it
    // for a read-and-edit surface the reader is comparing against that transcript.
    final start = source.indexOf('openContextPopover(event) {');
    final open = source.substring(start, source.indexOf('closeContextPopover() {', start));
    expect(open, isNot(contains('showModal')));
  });

  test('context mutation posts the current revision and leaves the draft outside reconciliation', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains('async applyContext(event)'));
    expect(source, contains('conversation_revision: this.conversationRevision'));
    expect(source, contains("attachments: this.attachments.filter((item) => item.state === 'ready')"));
    expect(source, contains("references: this.references.filter((item) => item.state === 'resolved')"));
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
      '#effective-context-current-row',
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

  test('the Q9 and E11 browser cases run the layout gate on the chat and session-info surfaces', () async {
    final script = File(await resolveWorkspacePath('dev', 'testing', 'profiles/conversation-loop/run.sh'))
        .readAsStringSync();
    final q9 = script.substring(
      script.indexOf('run_q9_effective_context()'),
      script.indexOf('run_e11_effective_context()'),
    );
    final e11 = script.substring(script.indexOf('run_e11_effective_context()'), script.lastIndexOf(r'case "${CASE}"'));
    for (final section in {'Q9': q9, 'E11': e11}.entries) {
      expect(section.value, contains('assert_layout_tiers'), reason: '${section.key} chat surface');
      expect(section.value, contains('assert_layout_canon'), reason: '${section.key} session-info surface');
    }
  });
}
