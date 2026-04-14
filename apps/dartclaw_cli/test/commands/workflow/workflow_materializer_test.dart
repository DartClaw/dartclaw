import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow_materializer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _workflowDefinitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('workflow_materializer_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('materializes three workflow yaml files into an empty workspace and skips them on the second run', () async {
    final copied = await WorkflowMaterializer.materialize(
      workspaceDir: tempDir.path,
      sourceDir: _workflowDefinitionsDir(),
    );

    expect(copied, 3);

    final targetDir = Directory(p.join(tempDir.path, 'workflows'));
    expect(targetDir.existsSync(), isTrue);
    final names = targetDir.listSync().whereType<File>().map((file) => p.basename(file.path)).toList()..sort();
    expect(names, equals(['code-review.yaml', 'plan-and-implement.yaml', 'spec-and-implement.yaml']));

    final copiedAgain = await WorkflowMaterializer.materialize(
      workspaceDir: tempDir.path,
      sourceDir: _workflowDefinitionsDir(),
    );
    expect(copiedAgain, 0);
  });

  test('does not overwrite a pre-existing workflow file', () async {
    final targetDir = Directory(p.join(tempDir.path, 'workflows'))..createSync(recursive: true);
    final existingFile = File(p.join(targetDir.path, 'code-review.yaml'));
    existingFile.writeAsStringSync('name: code-review\ndescription: local override\n');

    final copied = await WorkflowMaterializer.materialize(
      workspaceDir: tempDir.path,
      sourceDir: _workflowDefinitionsDir(),
    );

    expect(copied, 2);
    expect(existingFile.readAsStringSync(), 'name: code-review\ndescription: local override\n');
  });
}
