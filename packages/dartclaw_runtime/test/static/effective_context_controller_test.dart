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

  // Two triggers, two popovers, but one payload: an Apply in either one has to
  // state the whole next-turn context, so the handler reads every control on
  // the page rather than only its own form's.
  test('one apply path reads both popovers and posts the current revision', () async {
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
    for (final field in const [
      'effective-context-project',
      'effective-context-directory',
      'effective-context-provider',
      'effective-context-model-input',
      'effective-context-effort-input',
    ]) {
      expect(method, contains(field), reason: field);
    }
    // The message the popover shows is its own, so a rejection reaches the
    // reader in the surface they pressed Apply in.
    expect(method, contains("form.querySelector('.pop-validation')"));
    expect(method, isNot(contains('this.textarea.value')));
  });

  test('a trigger opens only the popover it names, and opening one closes the other', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    expect(source, contains("trigger?.getAttribute?.('aria-controls')"));
    final open = source.substring(
      source.indexOf('openContextPopover(event) {'),
      source.indexOf('closeContextPopover() {'),
    );
    expect(open, contains('this.closeContextPopover()'));
    expect(source, contains("this.element.querySelector('[aria-controls=\"' + popover.id + '\"]')"));
  });

  test('authoritative reconciliation updates controls and projections before absorbing revision', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    final method = source.substring(
      source.indexOf('reconcileContext(snapshot)'),
      source.indexOf('updateContinuityWarning() {'),
    );
    expect(method, contains('snapshot.effective_context'));
    for (final field in const ['project.value', 'directory.value', 'provider.value']) {
      expect(method, contains(field), reason: field);
    }
    // Model and effort are rebuilt from the applied provider's own catalogue,
    // not assigned into whatever options the previous provider left behind.
    expect(method, contains("this.renderContextOptions(\n      'effective-context-model-input',"));
    expect(method, contains("this.renderContextOptions(\n      'effective-context-effort-input',"));
    expect(
      method.indexOf('project.value = view.projectId'),
      lessThan(method.indexOf('this.conversationRevision = nextRevision')),
    );
    expect(method, isNot(contains('this.textarea')));
  });

  // A picker that cannot name a YAML- or API-set value silently unsets it the
  // next time anything else is applied.
  test('the model picker keeps a staged value the adapter does not list', () async {
    final source = (await controllerAsset('dc_chat_controller.js')).readAsStringSync();
    final method = source.substring(
      source.indexOf('renderContextOptions(id, catalogue, editable, staged) {'),
      source.indexOf('contextFieldValue(id) {'),
    );
    expect(method, contains("new Option('Provider default', '')"));
    expect(method, contains('if (value && !values.includes(value)) select.append(new Option(value, value));'));
    expect(method, contains('select.disabled = !enabled;'));
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
