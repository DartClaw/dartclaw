import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/conversation/human_command_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('authorized native skills preserve descriptions, spelling, and built-in precedence', () async {
    var discoveryCalls = 0;
    var available = const [
      NativeSkillCatalogItem(name: 'review', description: 'Review the current change'),
      NativeSkillCatalogItem(name: 'help', description: 'Workspace-specific help'),
    ];
    final catalog = HumanCommandCatalog(
      harnessFactory: HarnessFactory(),
      nativeSkills: ({required provider, required workspaceDir}) async {
        discoveryCalls++;
        return available.toList();
      },
    );
    const context = HumanCommandContext(
      principal: 'owner',
      provider: 'claude',
      revision: 2,
      sessionId: 'session',
      workspaceDir: '/workspace',
    );

    final first = await catalog.resolve(context, HumanCommandSurface.slash);
    final second = await catalog.resolve(context, HumanCommandSurface.global);

    expect(discoveryCalls, 2);
    expect(first.entries.where((entry) => entry.id == 'built-in:help').single.label, '/help');
    final collision = first.entries.where((entry) => entry.id == 'skill:help').single;
    expect(
      (collision.label, collision.description, collision.nativeInvocation),
      ('/help (skill)', 'Workspace-specific help', '/help'),
    );
    expect(first.entries.where((entry) => entry.id == 'skill:review').single.nativeInvocation, '/review');
    expect(first.identityToken, second.identityToken);

    available = const [NativeSkillCatalogItem(name: 'help', description: 'Workspace-specific help')];
    final changed = await catalog.resolve(context, HumanCommandSurface.slash);
    expect(discoveryCalls, 3);
    expect(changed.entries.where((entry) => entry.id == 'skill:review'), isEmpty);
    expect(changed.identityToken, isNot(first.identityToken));
  });

  test('Codex adapter owns dollar-prefixed activation and read-only hides native skills', () async {
    final catalog = HumanCommandCatalog(
      harnessFactory: HarnessFactory(),
      nativeSkills: ({required provider, required workspaceDir}) async => const [
        NativeSkillCatalogItem(name: 'review', description: 'Review'),
      ],
    );
    final entries = await catalog.entries(
      const HumanCommandContext(principal: 'owner', provider: 'codex', revision: 1, sessionId: 'session'),
      HumanCommandSurface.global,
    );
    expect(entries.where((entry) => entry.id == 'skill:review').single.nativeInvocation, r'$review');
    final archived = await catalog.entries(
      const HumanCommandContext(
        principal: 'owner',
        provider: 'codex',
        revision: 2,
        sessionId: 'session',
        readOnly: true,
      ),
      HumanCommandSurface.global,
    );
    expect(archived.where((entry) => entry.id.startsWith('skill:')), isEmpty);
  });
}
