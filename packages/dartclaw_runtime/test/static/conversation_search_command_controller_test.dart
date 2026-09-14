import 'dart:io';

import 'package:test/test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File('packages/dartclaw_runtime/lib/src/static/controllers/dc_conversation_command_controller.js')
        .readAsStringSync();
  });

  test('keyboard handling preserves browser Find and ignores IME composition', () {
    expect(source, contains('if (event.isComposing) return'));
    expect(source, contains("event.key.toLowerCase() === 'k'"));
    expect(source, isNot(contains("event.key.toLowerCase() === 'f'")));
  });

  test('latest response token, dialog focus trap, and fragment-safe delegation are explicit', () {
    expect(source, contains('const generation = ++this.searchGeneration'));
    expect(source, contains('this.refreshDialog(queryInput.closest(\'dialog\'), generation)'));
    expect(source, contains('if (!dialog?.open || generation !== this.searchGeneration) return'));
    expect(source, contains('generation !== this.searchGeneration'));
    expect(source, contains('data.request_token !== String(generation)'));
    expect(source, contains('trapFocus(event, dialog)'));
    expect(source, contains("document.addEventListener('click', this.handleClick)"));
    expect(source, contains("document.removeEventListener('click', this.handleClick)"));
  });

  test('query navigation preserves draft and reauthorizes the selected target', () {
    expect(source, contains("sessionStorage.setItem('dartclaw-search-return'"));
    expect(source, contains("draft: this.textarea()?.value || ''"));
    expect(source, contains("'/api/conversation-search/target'"));
  });

  test('search highlights are built from text nodes rather than result HTML', () {
    expect(source, contains("document.createElement('mark')"));
    expect(source, contains('highlight.textContent = snippet.slice(start, end)'));
    expect(source, contains('document.createTextNode(snippet.slice(end)'));
  });

  test('native skill selection crosses the typed action route before mutating the composer', () {
    expect(source, isNot(contains('dataset.nativeInvocation')));
    expect(source, contains("if (data.action === 'send_provider')"));
    expect(source, contains('textarea.value = data.message'));
    expect(source, contains("this.apiUrl('/api/command-actions')"));
  });
}
