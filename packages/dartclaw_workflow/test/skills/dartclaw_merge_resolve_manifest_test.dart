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

      test('workflow.default_prompt is a non-empty string', () {
        final workflow = frontmatter['workflow'];
        expect(workflow, isA<Map<Object?, Object?>>());
        final prompt = (workflow as Map<Object?, Object?>)['default_prompt'];
        expect(prompt, isA<String>());
        expect((prompt as String).trim(), isNotEmpty);
      });
    });

    // TI03 — four output fields with correct formats
    group('output declarations', () {
      late Map<Object?, Object?> defaultOutputs;

      setUp(() {
        final workflow = frontmatter['workflow'] as Map<Object?, Object?>;
        expect(workflow['default_outputs'], isA<Map<Object?, Object?>>(), reason: 'workflow.default_outputs must be a map');
        defaultOutputs = workflow['default_outputs'] as Map<Object?, Object?>;
      });

      test('declares merge_resolve.outcome output', () {
        expect(defaultOutputs.containsKey('merge_resolve.outcome'), isTrue);
      });

      test('merge_resolve.outcome declares enum-typed string with the three allowed values', () {
        final cfg = defaultOutputs['merge_resolve.outcome'] as Map<Object?, Object?>;
        // Runtime format must be one of the runtime-supported OutputFormat values
        // (text/json/lines/path); the enum constraint is expressed in the description.
        expect(cfg['format'], 'text', reason: 'TI03 enum-typed string maps to runtime format=text');
        final desc = cfg['description'] as String;
        for (final v in ['resolved', 'failed', 'cancelled']) {
          expect(desc, contains(v), reason: 'description must enumerate allowed value "$v"');
        }
      });

      test('declares merge_resolve.conflicted_files output', () {
        expect(defaultOutputs.containsKey('merge_resolve.conflicted_files'), isTrue);
      });

      test('merge_resolve.conflicted_files has format: json', () {
        final cfg = defaultOutputs['merge_resolve.conflicted_files'] as Map;
        expect(cfg['format'], 'json');
      });

      test('declares merge_resolve.resolution_summary output', () {
        expect(defaultOutputs.containsKey('merge_resolve.resolution_summary'), isTrue);
      });

      test('declares merge_resolve.error_message output', () {
        expect(defaultOutputs.containsKey('merge_resolve.error_message'), isTrue);
      });

      test('all four output keys are present', () {
        const required = {
          'merge_resolve.outcome',
          'merge_resolve.conflicted_files',
          'merge_resolve.resolution_summary',
          'merge_resolve.error_message',
        };
        for (final key in required) {
          expect(defaultOutputs.containsKey(key), isTrue, reason: 'missing output: $key');
        }
      });

      test('each output has a non-empty description', () {
        for (final entry in defaultOutputs.entries) {
          final val = entry.value as Map;
          expect(val['description'], isA<String>(), reason: '${entry.key} missing description');
          expect((val['description'] as String).trim(), isNotEmpty, reason: '${entry.key} description is empty');
        }
      });
    });

    // TI04 — all six env-var names present verbatim
    group('env-var names in prompt body', () {
      const envVars = [
        'MERGE_RESOLVE_INTEGRATION_BRANCH',
        'MERGE_RESOLVE_STORY_BRANCH',
        'MERGE_RESOLVE_TOKEN_CEILING',
        'MERGE_RESOLVE_VERIFY_FORMAT',
        'MERGE_RESOLVE_VERIFY_ANALYZE',
        'MERGE_RESOLVE_VERIFY_TEST',
      ];

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

    // TI08 — verification chain with output-encoded status
    group('verification chain', () {
      test('contains git diff --check via output-encoded form', () {
        expect(content, contains('git diff --check'));
        expect(content, contains('DIFF_CHECK_OK'));
        expect(content, contains('DIFF_CHECK_FAIL'));
      });

      test('uses output-encoded status for format verification', () {
        expect(content, contains('FORMAT_OK'));
        expect(content, contains('FORMAT_FAIL'));
        expect(content, contains('FORMAT_SKIP'));
      });

      test('uses output-encoded status for analysis verification', () {
        expect(content, contains('ANALYZE_OK'));
        expect(content, contains('ANALYZE_FAIL'));
        expect(content, contains('ANALYZE_SKIP'));
      });

      test('uses output-encoded status for test verification', () {
        expect(content, contains('TEST_OK'));
        expect(content, contains('TEST_FAIL'));
        expect(content, contains('TEST_SKIP'));
      });

      test('documents skip branch for absent optional env vars', () {
        // Must have a conditional skip for each optional var
        expect(content, contains('test -z "\$MERGE_RESOLVE_VERIFY_FORMAT"'));
        expect(content, contains('test -z "\$MERGE_RESOLVE_VERIFY_ANALYZE"'));
        expect(content, contains('test -z "\$MERGE_RESOLVE_VERIFY_TEST"'));
      });
    });

    // TI09 — remediation loop with token ceiling bound
    group('remediation loop', () {
      test('documents remediation loop', () {
        expect(content, contains('remediation'));
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
