import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  group('DelegateToAgentTool security modes', () {
    test('rejects relay or unverified ACP when guard mediation required', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(
          acp: const AcpConfig(
            agents: {'goose': AcpAgentConfig(binary: 'goose', topology: AcpAgentTopology.relay)},
          ),
        ),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});
      expect(result['status'], 'error');
      expect(result['code'], 'AGENT_SECURITY_MODE_UNAVAILABLE');
    });

    test('permits explicit container-only ACP with enforceable container boundary', () async {
      final tool = DelegateToAgentTool(
        config: delegationConfig(
          agents: const [DelegationAgentConfig(id: 'goose')],
          acp: const AcpConfig(
            agents: {
              'goose': AcpAgentConfig(
                binary: 'goose',
                topology: AcpAgentTopology.relay,
                containerIsolationRequired: true,
                containerProfile: AcpContainerProfile.restricted,
              ),
            },
          ),
        ),
        pool: FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')}),
        workspaceDir: '/tmp/ws',
      );

      final result = await callDelegate(tool, {'agent_id': 'goose', 'task': 'x'});
      expect(result['status'], 'completed');
      expect(result['security_mode'], 'container_isolation_only');
    });

    test('Codex requires provider approval mode with approval and sandbox configured', () async {
      final failing = DelegateToAgentTool(
        config: delegationConfig(
          agents: const [DelegationAgentConfig(id: 'codex', requireGuardMediation: true)],
          providers: const {
            'codex': ProviderEntry(
              executable: 'codex',
              options: {'approval': 'on-request', 'sandbox': 'workspace-write'},
            ),
          },
        ),
        pool: FakeDelegationPool({'codex': FakeDelegationRunner(providerId: 'codex')}),
        workspaceDir: '/tmp/ws',
      );
      expect(
        (await callDelegate(failing, {'agent_id': 'codex', 'task': 'x'}))['code'],
        'AGENT_SECURITY_MODE_UNAVAILABLE',
      );

      final passing = DelegateToAgentTool(
        config: delegationConfig(
          agents: const [DelegationAgentConfig(id: 'codex')],
          providers: const {
            'codex': ProviderEntry(
              executable: 'codex',
              options: {'approval': 'on-request', 'sandbox': 'workspace-write'},
            ),
          },
        ),
        pool: FakeDelegationPool({'codex': FakeDelegationRunner(providerId: 'codex')}),
        workspaceDir: '/tmp/ws',
      );
      final result = await callDelegate(passing, {'agent_id': 'codex', 'task': 'x'});
      expect(result['status'], 'completed');
      expect(result['security_mode'], 'provider_approval');
    });

    test('Codex rejects approval bypass and full-access sandbox modes', () async {
      Future<Map<String, dynamic>> run({required String approval, required String sandbox}) {
        final tool = DelegateToAgentTool(
          config: delegationConfig(
            agents: const [DelegationAgentConfig(id: 'codex')],
            providers: {
              'codex': ProviderEntry(executable: 'codex', options: {'approval': approval, 'sandbox': sandbox}),
            },
          ),
          pool: FakeDelegationPool({'codex': FakeDelegationRunner(providerId: 'codex')}),
          workspaceDir: '/tmp/ws',
        );
        return callDelegate(tool, {'agent_id': 'codex', 'task': 'x'});
      }

      expect((await run(approval: 'full-auto', sandbox: 'workspace-write'))['code'], 'AGENT_SECURITY_MODE_UNAVAILABLE');
      expect((await run(approval: 'never', sandbox: 'workspace-write'))['code'], 'AGENT_SECURITY_MODE_UNAVAILABLE');
      expect(
        (await run(approval: 'on-request', sandbox: 'danger-full-access'))['code'],
        'AGENT_SECURITY_MODE_UNAVAILABLE',
      );
    });
  });
}
