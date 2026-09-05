import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/config_schema_artifact.dart';
import 'support/json_schema_walker.dart';

void main() {
  final schema = ConfigMeta.toJsonSchema(version: '0.25.1');
  late String repoRoot;

  setUpAll(() async => repoRoot = await resolveRepoRoot());

  String read(String relative) => File(p.join(repoRoot, relative)).readAsStringSync();

  List<String> diagnose(String yaml) => validateAgainstSchema(loadYaml(yaml) as Object?, schema);

  group('the shipped corpus', () {
    for (final relative in shippedConfigCorpus) {
      test('$relative validates clean', () {
        expect(diagnose(read(relative)), isEmpty);
      });
    }

    test('the walk reaches leaves only an items arm can reach', () {
      // Without descending `items`, jobs and rule lists are never looked at and
      // the corpus gate is green because it never got there.
      final jobs = loadYaml(read('dev/testing/profiles/plain/data/dartclaw.yaml')) as YamlMap;
      final task = (jobs['scheduling']['jobs'] as YamlList).firstWhere((job) => job['type'] == 'task');
      expect(task['task']['title'], isNotEmpty);

      final broken = read('dev/testing/profiles/plain/data/dartclaw.yaml')
          .replaceAll('title: Smoke-test fixture (does not run)', 'title: [not, a, string]');
      expect(diagnose(broken), [contains('scheduling.jobs[2].task.title')]);

      final rules = read('examples/production.yaml').replaceAll('level: no_access', 'level: no_such_level');
      expect(diagnose(rules), everyElement(contains('guards.file.extra_rules[')));
      expect(diagnose(rules), hasLength(2));
    });
  });

  group('a mistake an operator makes in the editor', () {
    late String dev;

    setUpAll(() async {
      repoRoot = await resolveRepoRoot();
      dev = read('examples/dev.yaml');
    });

    test('the unmodified document produces nothing', () {
      expect(diagnose(dev), isEmpty);
    });

    for (final mutation in [
      (name: 'a misspelled section', from: 'guards:', to: 'guardz:', path: 'guardz'),
      (name: 'a number above its maximum', from: 'port: 3333', to: 'port: 99999', path: 'port'),
      (name: 'a quoted number in an integer field', from: 'port: 3333', to: 'port: "3333"', path: 'port'),
      (name: 'a value outside its enum', from: 'level: FINE', to: 'level: TRACE', path: 'logging.level'),
    ]) {
      test('${mutation.name} is flagged, naming the path', () {
        final diagnostics = diagnose(dev.replaceAll(mutation.from, mutation.to));
        expect(diagnostics, isNotEmpty);
        expect(diagnostics, anyElement(contains(mutation.path)));
      });
    }

    test('an explicit null validates, because that is how a nullable field is unset', () {
      expect(diagnose('$dev\nagent:\n  execution:\n'), isEmpty);
    });

    test('a section left empty validates, because the loader reads it as absent', () {
      // Commenting a section's body out is routine authoring, and the loader
      // accepts it; flagging it would be a red squiggle on a file that loads.
      expect(diagnose('guards:\n'), isEmpty);
      expect(diagnose('logging:\nworkspace:\n  git_sync:\n'), isEmpty);
      // …and the section is still closed once it does carry a key.
      expect(diagnose('guards:\n  enabld: true\n'), [contains('guards.enabld')]);
    });
  });

  group('operator-named entries', () {
    test('an open container accepts a name it has never seen, and still types the entry', () {
      const yaml = '''
credentials:
  my-key:
    api_key: \${ANTHROPIC_API_KEY}
  github-main:
    type: github-token
    token: \${GITHUB_TOKEN}
    repository: DartClaw/workflow-test-todo-app
providers:
  codex:
    pool_size: 3
projects:
  workflow-test-todo-app:
    remote: git@github.com:DartClaw/workflow-test-todo-app.git
    pr:
      labels: [workflow-test]
  fetchCooldownMinutes: 10
agent:
  agents:
    search:
      tools: [WebSearch, WebFetch]
channels:
  some_future_channel:
    enabled: true
''';
      expect(diagnose(yaml), isEmpty);
    });

    test('an open container does not leak strictness away from its neighbours', () {
      expect(diagnose('guards:\n  enabld: true\n'), [contains('guards.enabld')]);
      expect(diagnose('providers:\n  codex:\n    pool_size: "three"\n'), [contains('providers.codex.pool_size')]);
    });
  });

  group('polymorphic authoring shapes', () {
    for (final accepted in [
      'channels:\n  google_chat:\n    typing_indicator: true\n',
      'channels:\n  google_chat:\n    typing_indicator: emoji\n',
      'scheduling:\n  jobs:\n    - id: a\n      schedule: 0 9 * * *\n',
      'scheduling:\n  jobs:\n    - id: a\n      schedule:\n        type: cron\n        expression: "0 10 * * 1"\n',
      'scheduling:\n  jobs:\n    - id: a\n      schedule:\n        type: interval\n        minutes: 30\n',
      'scheduling:\n  jobs:\n    - id: a\n      type: task\n      task:\n        title: t\n        description: d\n',
      'governance:\n  rate_limits:\n    global:\n      window: 1\n',
      'governance:\n  rate_limits:\n    global:\n      window: 5m\n',
    ]) {
      test('accepted: ${accepted.replaceAll('\n', ' ⏎ ').trim()}', () {
        expect(diagnose(accepted), isEmpty);
      });
    }

    for (final rejected in [
      (yaml: 'channels:\n  google_chat:\n    typing_indicator: maybe\n', path: 'channels.google_chat.typing_indicator'),
      (
        yaml: 'scheduling:\n  jobs:\n    - id: a\n      schedule:\n        type: hourly\n',
        path: 'scheduling.jobs[0].schedule.type',
      ),
      (
        yaml: 'scheduling:\n  jobs:\n    - id: a\n      schedule:\n        expresion: "0 9 * * *"\n',
        path: 'scheduling.jobs[0].schedule.expresion',
      ),
      (
        yaml: 'scheduling:\n  jobs:\n    - id: a\n      schedule:\n        minutes: "30"\n',
        path: 'scheduling.jobs[0].schedule.minutes',
      ),
      (
        yaml: 'governance:\n  rate_limits:\n    global:\n      window:\n        minutes: 5\n',
        path: 'governance.rate_limits.global.window',
      ),
      (yaml: 'scheduling:\n  jobs:\n    - id: a\n      promtp: hi\n', path: 'scheduling.jobs[0].promtp'),
    ]) {
      test('flagged: ${rejected.path}', () {
        expect(diagnose(rejected.yaml), [contains(rejected.path)]);
      });
    }

    test('the union widens which types are accepted; it never opens the object', () {
      expect(diagnose('scheduling:\n  jobs:\n    - id: a\n      schedule: {type: cron, nope: 1}\n'), [
        contains('scheduling.jobs[0].schedule.nope'),
      ]);
    });
  });

  group('describing a field is not permission to write it', () {
    test('a read-only field is a legal config file and a refused API write', () {
      expect(diagnose('guards:\n  enabled: false\n'), isEmpty);
      expect(diagnose(read('examples/dev.yaml')), isEmpty);
      expect(ConfigMeta.isWritable('guards.enabled'), isFalse);
    });

    test('an open container is not a way round the refusal of the read-only fields inside it', () {
      // An object-valued field is written wholesale, so a settable `channels`
      // would carry the Google Chat service account and audience claim past
      // their own read-only refusal.
      expect(diagnose('channels:\n  google_chat:\n    service_account: sa.json\n'), isEmpty);
      expect(ConfigMeta.isWritable('channels'), isFalse);
      expect(ConfigMeta.isWritable('channels.google_chat.service_account'), isFalse);
    });

    test('a tolerated-legacy key is not emitted, so an editor flags what the loader would only warn about', () {
      for (final legacy in ConfigMeta.toleratedLegacyKeys.keys) {
        expect(ConfigMeta.isKnown(legacy), isFalse, reason: legacy);
      }
      expect(diagnose('delegation:\n  enabled: true\n'), [contains('delegation')]);

      // …and none of them is in a file operators copy from.
      for (final relative in shippedConfigCorpus) {
        expect(diagnose(read(relative)), isEmpty, reason: relative);
      }
    });

    test('no shipped config raises a load advisory for a key removed from the supported surface', () {
      // Schema-clean is not load-clean: the loader also runs the accept-set
      // sweep and every parser's own unknown-key sweep. Scoped to the keys this
      // removal owns — the corpus carries other advisories no more.
      const removed = [
        'automation.scheduled_tasks',
        'guard_audit.max_entries',
        'container.mounts',
        'container.extra_args',
      ];

      for (final relative in shippedConfigCorpus) {
        final yaml = read(relative);
        final config = DartclawConfig.load(
          configPath: 'dartclaw.yaml',
          fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
          env: const {'HOME': '/home/user'},
        );
        for (final key in removed) {
          expect(
            config.warnings.where((w) => w.contains(key)),
            isEmpty,
            reason: '$relative raises an advisory for $key',
          );
        }
      }
    });
  });
}
