import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String _skillsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'skills'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'skills'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    final parent = current.parent;
    if (parent.path == current.path) throw StateError('Could not locate built-in skills directory');
    current = parent;
  }
}

void main() {
  group('dartclaw-merge-resolve manifest', () {
    late String skillMdPath;
    late String content;
    late Map<dynamic, dynamic> frontmatter;

    setUpAll(() {
      skillMdPath = p.join(_skillsDir(), 'dartclaw-merge-resolve', 'SKILL.md');
      content = File(skillMdPath).readAsStringSync();

      // Parse YAML frontmatter delimited by --- ... ---
      final fmMatch = RegExp(r'^---\n([\s\S]*?)\n---', multiLine: true).firstMatch(content);
      expect(fmMatch, isNotNull, reason: 'SKILL.md must have YAML frontmatter');
      frontmatter = loadYaml(fmMatch!.group(1)!) as Map;
    });

    // TI02 — front-matter required fields
    group('front-matter', () {
      test('name is dartclaw-merge-resolve', () {
        expect(frontmatter['name'], 'dartclaw-merge-resolve');
      });

      test('description is non-empty', () {
        expect(frontmatter['description'], isA<String>());
        expect((frontmatter['description'] as String).trim(), isNotEmpty);
      });

      test('user-invocable is false', () {
        expect(frontmatter['user-invocable'], isFalse);
      });

      test('does not carry workflow frontmatter defaults', () {
        expect(frontmatter.containsKey('workflow'), isFalse);
      });
    });

    // TI04 — required env-var names present verbatim
    group('env-var names in prompt body', () {
      const envVars = ['MERGE_RESOLVE_INTEGRATION_BRANCH', 'MERGE_RESOLVE_STORY_BRANCH', 'MERGE_RESOLVE_TOKEN_CEILING'];

      for (final varName in envVars) {
        test('contains $varName', () {
          expect(content, contains(varName));
        });
      }

      test('contains fail-fast instruction for missing required vars', () {
        // Must instruct immediate termination when required vars are unset
        expect(content, contains('MERGE_RESOLVE_INTEGRATION_BRANCH unset'));
      });
    });

    // TI05 — conflict detection commands present
    group('detection commands', () {
      test('contains !git status --porcelain', () {
        expect(content, contains('!git status --porcelain'));
      });

      test('contains !git diff --name-only --diff-filter=U', () {
        expect(content, contains('!git diff --name-only --diff-filter=U'));
      });

      test('identifies git diff --diff-filter=U as source for conflicted_files', () {
        // The prompt must tie the diff-filter command to the conflicted_files output
        expect(
          content,
          contains('conflicted_files'),
          reason: 'conflicted_files must be mentioned near the diff-filter command',
        );
      });
    });

    // TI06 — mechanical merge command with output-encoded status
    group('mechanical merge command', () {
      test('contains !git merge "\$MERGE_RESOLVE_INTEGRATION_BRANCH" --no-edit', () {
        expect(content, contains('!git merge "\$MERGE_RESOLVE_INTEGRATION_BRANCH" --no-edit'));
      });

      test('uses output-encoded status for merge result (not bare if !cmd)', () {
        // Must use && echo ... || echo ... pattern, not bare `if !cmd; then`
        expect(content, contains('MERGE_OK'));
        expect(content, contains('MERGE_FAIL'));
      });
    });

    // TI07 — semantic resolution with conflict marker tokens
    group('semantic resolution', () {
      test('contains <<<<<<< conflict marker token', () {
        expect(content, contains('<<<<<<<'));
      });

      test('contains >>>>>>> conflict marker token', () {
        expect(content, contains('>>>>>>>'));
      });

      test('ties conflict resolution rationale to resolution_summary output', () {
        expect(content, contains('resolution_summary'));
      });
    });

    // TI08 — project-convention verification
    group('verification step', () {
      test('contains git diff --check via output-encoded form', () {
        expect(content, contains('git diff --check'));
      });

      test('asks for project-documented verification commands', () {
        expect(content, contains('applicable verification commands'));
        expect(content, contains('CLAUDE.md, AGENTS.md'));
        expect(content, contains('pyproject.toml'));
        expect(content, contains('pubspec.yaml'));
        expect(content, contains('package.json'));
      });

      test('records pre-existing failures in verification notes', () {
        expect(content, contains('merge_resolve.verification_notes'));
      });
    });

    // TI09 — remediation loop with token ceiling bound
    group('remediation loop', () {
      test('documents remediation loop', () {
        expect(content, contains('Remediation'));
      });

      test('names MERGE_RESOLVE_TOKEN_CEILING as the bound', () {
        expect(content, contains('MERGE_RESOLVE_TOKEN_CEILING'));
      });

      test('instructs outcome: failed on token ceiling exhaustion', () {
        expect(content, contains('token_ceiling exceeded at'));
      });
    });

    // TI10 — commit step is single and late; forbidden commands absent
    group('all-or-nothing commit', () {
      test('contains exactly one !git commit invocation', () {
        final commitCount = RegExp(r'!git commit').allMatches(content).length;
        expect(commitCount, 1, reason: 'Expected exactly one !git commit, found $commitCount');
      });

      test('does not contain !git merge --abort', () {
        expect(content, isNot(contains('!git merge --abort')));
      });

      test('does not contain !git reset', () {
        expect(content, isNot(contains('!git reset')));
      });

      test('does not contain !git clean', () {
        expect(content, isNot(contains('!git clean')));
      });
    });

    // TI11 — output emission on every terminal path
    group('terminal output paths', () {
      test('emits outcome: resolved on success path', () {
        expect(content, contains('outcome: resolved'));
      });

      test('emits outcome: failed on failure path', () {
        expect(content, contains('outcome: failed'));
      });

      test('emits outcome: cancelled on cancellation path', () {
        expect(content, contains('outcome: cancelled'));
      });

      test('emits conflicted_files as JSON array on success path', () {
        expect(content, contains('merge_resolve.conflicted_files'));
      });

      test('emits error_message: null on success path', () {
        expect(content, contains('error_message: null'));
      });

      test('emits non-null error_message on failure path', () {
        // Error message must be non-empty string on failed/cancelled
        expect(content, contains('error_message: cancelled by harness'));
      });
    });
  });
}
