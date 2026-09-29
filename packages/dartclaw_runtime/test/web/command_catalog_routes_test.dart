import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/conversation/human_command_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('one catalog projects the exact built-ins with equal descriptions to both surfaces', () async {
    final catalog = HumanCommandCatalog(harnessFactory: HarnessFactory());
    const context = HumanCommandContext(
      principal: 'owner',
      provider: 'claude',
      revision: 7,
      sessionId: 'session',
      modelEditable: true,
      effortEditable: true,
      turnActive: true,
      forkAvailable: true,
      settleAvailable: true,
    );

    final slash = await catalog.entries(context, HumanCommandSurface.slash);
    final global = await catalog.entries(context, HumanCommandSurface.global);
    const expected = {'/new', '/reset', '/stop', '/status', '/fork', '/settle', '/model', '/effort', '/help'};
    expect(slash.map((entry) => entry.label).toSet(), expected);
    expect(global.map((entry) => entry.label).toSet(), expected);
    expect(
      {for (final entry in slash) entry.id: entry.description},
      {for (final entry in global) entry.id: entry.description},
    );
  });

  test('sessionless and read-only contexts expose only actions whose authority can execute', () async {
    final catalog = HumanCommandCatalog(harnessFactory: HarnessFactory());
    final sessionless = await catalog.entries(
      const HumanCommandContext(principal: 'owner', provider: 'claude', revision: 0),
      HumanCommandSurface.global,
    );
    expect(sessionless.where((entry) => entry.enabled).map((entry) => entry.label), ['/new', '/help']);

    final readOnly = await catalog.entries(
      const HumanCommandContext(
        principal: 'owner',
        provider: 'claude',
        revision: 4,
        sessionId: 'archive',
        readOnly: true,
      ),
      HumanCommandSurface.global,
    );
    expect(readOnly.map((entry) => entry.label), ['/new', '/status', '/help']);
  });

  test('identity token changes with every dispatch-relevant fact', () async {
    final catalog = HumanCommandCatalog(harnessFactory: HarnessFactory());
    const base = HumanCommandContext(principal: 'owner', provider: 'claude', revision: 1, sessionId: 'session');
    const changed = HumanCommandContext(
      principal: 'owner',
      provider: 'claude',
      revision: 1,
      sessionId: 'session',
      turnActive: true,
    );
    final baseSnapshot = await catalog.resolve(base, HumanCommandSurface.global);
    final changedSnapshot = await catalog.resolve(changed, HumanCommandSurface.global);
    expect(baseSnapshot.identityToken, isNot(changedSnapshot.identityToken));
  });
}
