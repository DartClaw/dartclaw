import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../test_utils.dart';

/// Every page template that owns a `#main-content` swap root, named so a
/// template gained or lost here fails by name rather than by count.
const _entryMotionTemplates = {
  'channel_detail.html',
  'chat.html',
  'components.html',
  'health_dashboard.html',
  'kg_timeline.html',
  'knowledge_hub.html',
  'memory_dashboard.html',
  'projects.html',
  'scheduling.html',
  'session_info.html',
  'settings.html',
  'signal_pairing.html',
  'task_detail.html',
  'tasks.html',
  'whatsapp_pairing.html',
  'wiki_document.html',
  'workflow_detail.html',
  'workflow_list.html',
};

void main() {
  test('every main content swap root uses print-in', () async {
    final templatesDir = Directory(await resolveTemplatesDir());
    final templates = templatesDir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.html'))
        .where((file) => file.readAsStringSync().contains('id="main-content"'))
        .toList();

    expect(templates.map((file) => p.basename(file.path)).toSet(), _entryMotionTemplates);
    for (final template in templates) {
      final main = RegExp(r'<main[^>]*id="main-content"[^>]*>').firstMatch(template.readAsStringSync())?.group(0);
      expect(main, isNotNull, reason: template.path);
      expect(main, contains('print-in'), reason: template.path);
    }
  });
}
