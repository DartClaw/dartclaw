import 'dart:io';

import 'package:dartclaw_runtime/src/workspace/workspace_path_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspacePathGuard.resolveFile', () {
    late Directory tempRoot;
    late Directory workspace;
    late Directory outside;
    late String resolvedWorkspace;
    late WorkspacePathGuard guard;

    setUp(() {
      // The workspace is a subdirectory so `..` has somewhere real to land and
      // the sibling `outside/` is genuinely outside the resolved root.
      tempRoot = Directory.systemTemp.createTempSync('workspace_path_guard_');
      workspace = Directory(p.join(tempRoot.path, 'workspace'))..createSync();
      outside = Directory(p.join(tempRoot.path, 'outside'))..createSync();

      Directory(p.join(workspace.path, 'reports')).createSync();
      File(p.join(workspace.path, 'reports', 'q3.pdf')).writeAsStringSync('quarterly report');
      File(p.join(tempRoot.path, 'secrets.env')).writeAsStringSync('TOKEN=shh');
      File(p.join(outside.path, 'vault.env')).writeAsStringSync('VAULT=shh');

      // Real links on disk: a containment check that only compares path strings
      // admits the escaping one, so a synthesized path would not prove anything.
      Link(p.join(workspace.path, 'link.pdf')).createSync(p.join(outside.path, 'vault.env'));
      Link(p.join(workspace.path, 'inside-link.pdf')).createSync(p.join(workspace.path, 'reports', 'q3.pdf'));

      resolvedWorkspace = workspace.resolveSymbolicLinksSync();
      guard = WorkspacePathGuard(workspace.path);
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('a workspace-relative file resolves to its absolute, symlink-resolved path', () {
      final verdict = guard.resolveFile('reports/q3.pdf');

      expect(verdict.refusal, isNull);
      expect(verdict.file!.path, p.join(resolvedWorkspace, 'reports', 'q3.pdf'));
      expect(p.isAbsolute(verdict.file!.path), isTrue);
      expect(verdict.file!.readAsStringSync(), 'quarterly report');
    });

    test('an absolute path naming the same in-workspace file resolves too', () {
      final verdict = guard.resolveFile(p.join(workspace.path, 'reports', 'q3.pdf'));

      expect(verdict.refusal, isNull);
      expect(verdict.file!.path, p.join(resolvedWorkspace, 'reports', 'q3.pdf'));
    });

    test('a symlink inside the workspace pointing inside it resolves to its target', () {
      final verdict = guard.resolveFile('inside-link.pdf');

      expect(verdict.refusal, isNull, reason: 'the rule refuses escape, not links');
      expect(verdict.file!.path, p.join(resolvedWorkspace, 'reports', 'q3.pdf'));
    });

    test('a traversal path reaching a real file above the workspace is refused for containment', () {
      final verdict = guard.resolveFile('../secrets.env');

      expect(verdict.file, isNull);
      expect(verdict.refusal, '"../secrets.env" is not inside the workspace and cannot be sent');
    });

    test('an absolute path to a real file outside the workspace is refused for containment', () {
      final candidate = p.join(outside.path, 'vault.env');

      final verdict = guard.resolveFile(candidate);

      expect(verdict.file, isNull);
      expect(verdict.refusal, '"$candidate" is not inside the workspace and cannot be sent');
    });

    test('a symlink inside the workspace pointing outside it is refused for containment', () {
      final verdict = guard.resolveFile('link.pdf');

      expect(verdict.file, isNull);
      expect(
        verdict.refusal,
        '"link.pdf" is not inside the workspace and cannot be sent',
        reason: 'the link is stored inside the workspace; only resolving it exposes the escape',
      );
    });

    test('every out-of-workspace candidate answers the same message, whatever is actually there', () {
      // Containment refusals must not distinguish a real file from a directory
      // from nothing at all, or the tool is a host filesystem existence-and-type
      // oracle a model can enumerate one path at a time.
      final missing = p.join(outside.path, 'not-there.env');

      for (final candidate in [p.join(outside.path, 'vault.env'), outside.path, missing]) {
        final verdict = guard.resolveFile(candidate);
        expect(verdict.file, isNull, reason: candidate);
        expect(
          verdict.refusal,
          '"$candidate" is not inside the workspace and cannot be sent',
          reason: 'an out-of-workspace answer must not reveal whether the path exists or what it is',
        );
      }
    });

    test('a file reached through a symlinked intermediate directory that escapes is refused', () {
      final outsideNested = Directory(p.join(outside.path, 'nested'))..createSync();
      File(p.join(outsideNested.path, 'leak.pdf')).writeAsStringSync('leak');
      Link(p.join(workspace.path, 'shortcut')).createSync(outsideNested.path);

      final verdict = guard.resolveFile('shortcut/leak.pdf');

      expect(verdict.file, isNull);
      expect(verdict.refusal, '"shortcut/leak.pdf" is not inside the workspace and cannot be sent');
    });

    test('a dangling symlink is judged where it sits, and its target is never echoed', () {
      Link(p.join(workspace.path, 'dangling.pdf')).createSync(p.join(outside.path, 'never-created.env'));

      final verdict = guard.resolveFile('dangling.pdf');

      expect(verdict.file, isNull);
      expect(verdict.refusal, '"dangling.pdf" is not a regular file');
      expect(verdict.refusal, isNot(contains('never-created')));
    });

    test('a non-existent path is refused for absence, not containment', () {
      final verdict = guard.resolveFile('reports/missing.pdf');

      expect(verdict.file, isNull);
      expect(verdict.refusal, 'no file exists at "reports/missing.pdf"');
    });

    test('a directory inside the workspace is refused for not being a regular file', () {
      final verdict = guard.resolveFile('reports');

      expect(verdict.file, isNull);
      expect(verdict.refusal, '"reports" is not a regular file');
    });

    test('a blank path is refused before anything touches the filesystem', () {
      final verdict = guard.resolveFile('   ');

      expect(verdict.file, isNull);
      expect(verdict.refusal, 'path must not be blank');
    });

    test('the root is the symlink-resolved workspace directory', () {
      expect(guard.root, resolvedWorkspace);
    });
  });
}
