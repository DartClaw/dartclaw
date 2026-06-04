import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  test('parses line-delimited skill names without retaining completed probes', () async {
    final calls = <({String executable, List<String> arguments})>[];
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        calls.add((executable: executable, arguments: arguments));
        return ProcessResult(1, 0, 'andthen:review\n\ndartclaw-validate-workflow\n', '');
      },
    );

    final first = await introspector.listAvailable(provider: 'claude', executable: '/bin/claude');
    final second = await introspector.listAvailable(provider: 'claude', executable: '/bin/claude');

    expect(first, {'andthen:review', 'dartclaw-validate-workflow'});
    expect(second, first);
    expect(calls, hasLength(2));
    expect(calls.every((call) => call.executable == '/bin/claude'), isTrue);
    expect(calls.every((call) => call.arguments.contains(skillIntrospectionPrompt)), isTrue);
  });

  test('coalesces concurrent probes for the same provider executable', () async {
    final completer = Completer<ProcessResult>();
    var calls = 0;
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) {
        calls++;
        return completer.future;
      },
    );

    final first = introspector.listAvailable(provider: 'codex', executable: 'codex-a');
    final second = introspector.listAvailable(provider: 'codex', executable: 'codex-a');
    completer.complete(ProcessResult(1, 0, 'dartclaw-discover-andthen-spec\n', ''));

    expect(await first, {'dartclaw-discover-andthen-spec'});
    expect(await second, {'dartclaw-discover-andthen-spec'});
    expect(calls, 1);
  });

  test('parses claude json result output when present', () async {
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        return ProcessResult(1, 0, '{"result":"andthen:review\\nandthen:plan\\n"}', '');
      },
    );

    expect(await introspector.listAvailable(provider: 'claude'), {'andthen:review', 'andthen:plan'});
  });

  test('uses supported Codex noninteractive probe flags', () async {
    late List<String> capturedArguments;
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        capturedArguments = arguments;
        return ProcessResult(1, 0, 'andthen-review\n', '');
      },
    );

    expect(await introspector.listAvailable(provider: 'codex', executable: '/bin/codex'), {'andthen-review'});
    expect(capturedArguments, containsAll(['exec', '--skip-git-repo-check', '--ephemeral', '--sandbox', 'read-only']));
    expect(capturedArguments, isNot(contains('--full-auto')));
    expect(capturedArguments, contains(skillIntrospectionPrompt));
  });

  test('uses restricted Claude probe flags', () async {
    late List<String> capturedArguments;
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        capturedArguments = arguments;
        return ProcessResult(1, 0, 'andthen:review\n', '');
      },
    );

    expect(await introspector.listAvailable(provider: 'claude', executable: '/bin/claude'), {'andthen:review'});
    expect(capturedArguments, containsAll(['--permission-mode', 'plan', '-p', skillIntrospectionPrompt]));
    expect(capturedArguments, isNot(contains('--setting-sources')));
  });

  test('uses project-only Claude probe when user settings inheritance is disabled', () async {
    late List<String> capturedArguments;
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        capturedArguments = arguments;
        return ProcessResult(1, 0, 'andthen:review\n', '');
      },
    );

    expect(
      await introspector.listAvailable(
        provider: 'claude',
        executable: '/bin/claude',
        providerOptions: const {'inherit_user_settings': false},
      ),
      {'andthen:review'},
    );
    expect(capturedArguments, containsAll(['--setting-sources', 'project']));
    expect(capturedArguments.indexOf('--setting-sources'), lessThan(capturedArguments.indexOf('-p')));
  });

  test('does not coalesce probes with different Claude setting-source policies', () async {
    final calls = <List<String>>[];
    final completers = [Completer<ProcessResult>(), Completer<ProcessResult>()];
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) {
        calls.add(arguments);
        return completers[calls.length - 1].future;
      },
    );

    final defaultProbe = introspector.listAvailable(provider: 'claude', executable: '/bin/claude');
    final projectProbe = introspector.listAvailable(
      provider: 'claude',
      executable: '/bin/claude',
      providerOptions: const {'inherit_user_settings': false},
    );
    completers[0].complete(ProcessResult(1, 0, 'andthen:review\n', ''));
    completers[1].complete(ProcessResult(2, 0, 'andthen:review\n', ''));

    expect(await defaultProbe, {'andthen:review'});
    expect(await projectProbe, {'andthen:review'});
    expect(calls, hasLength(2));
    expect(calls.first, isNot(contains('--setting-sources')));
    expect(calls.last, contains('--setting-sources'));
  });

  test('passes provider-specific probe environment to runner', () async {
    late Map<String, String>? capturedEnvironment;
    final introspector = CliSkillIntrospector(
      environmentForProvider: (provider) => {'PROVIDER': provider, 'PATH': '/bin'},
      runner: (executable, arguments, {environment}) async {
        capturedEnvironment = environment;
        return ProcessResult(1, 0, 'dartclaw-discover-andthen-spec\n', '');
      },
    );

    expect(await introspector.listAvailable(provider: 'codex', executable: '/bin/codex'), {
      'dartclaw-discover-andthen-spec',
    });
    expect(capturedEnvironment, {'PROVIDER': 'codex', 'PATH': '/bin'});
  });

  test('probes noncanonical provider IDs by configured family', () async {
    late List<String> capturedArguments;
    late Map<String, String>? capturedEnvironment;
    final introspector = CliSkillIntrospector(
      environmentForProvider: (provider) => {'PROVIDER_ID': provider},
      runner: (executable, arguments, {environment}) async {
        capturedArguments = arguments;
        capturedEnvironment = environment;
        return ProcessResult(1, 0, 'andthen-review\n', '');
      },
    );

    expect(
      await introspector.listAvailable(
        provider: 'my_agent',
        executable: '/opt/bin/custom-agent',
        providerOptions: const {'family': 'codex'},
      ),
      {'andthen-review'},
    );
    expect(capturedArguments, containsAll(['exec', '--skip-git-repo-check']));
    expect(capturedEnvironment, {'PROVIDER_ID': 'my_agent'});
  });

  test('infers probe family from executable for noncanonical provider IDs', () async {
    late List<String> capturedArguments;
    final introspector = CliSkillIntrospector(
      runner: (executable, arguments, {environment}) async {
        capturedArguments = arguments;
        return ProcessResult(1, 0, 'andthen-review\n', '');
      },
    );

    expect(await introspector.listAvailable(provider: 'my_agent', executable: '/opt/codex-wrapper'), {
      'andthen-review',
    });
    expect(capturedArguments, containsAll(['exec', '--skip-git-repo-check']));
  });
}
