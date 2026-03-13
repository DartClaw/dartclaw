import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveProfile', () {
    test('maps research to restricted', () {
      expect(resolveProfile(TaskType.research), 'restricted');
    });

    test('maps coding to workspace', () {
      expect(resolveProfile(TaskType.coding), 'workspace');
    });

    test('maps writing to workspace', () {
      expect(resolveProfile(TaskType.writing), 'workspace');
    });

    test('maps analysis to workspace', () {
      expect(resolveProfile(TaskType.analysis), 'workspace');
    });

    test('maps automation to workspace', () {
      expect(resolveProfile(TaskType.automation), 'workspace');
    });

    test('maps custom to workspace', () {
      expect(resolveProfile(TaskType.custom), 'workspace');
    });
  });
}
