import 'package:dartclaw_server/src/mcp/delegate_to_agent_tool.dart';
import 'package:test/test.dart';

import 'delegate_to_agent_test_support.dart';

void main() {
  test('DelegateToAgentTool rate limit returns structured error without acquisition', () async {
    final pool = FakeDelegationPool({'goose': FakeDelegationRunner(providerId: 'goose')});
    final tool = DelegateToAgentTool(config: delegationConfig(rateLimit: 1), pool: pool, workspaceDir: '/tmp/ws');

    expect((await callDelegate(tool, {'agent_id': 'goose', 'task': 'first'}))['status'], 'completed');
    final second = await callDelegate(tool, {'agent_id': 'goose', 'task': 'second'});

    expect(second['status'], 'error');
    expect(second['message'], contains('rate limit'));
    expect(pool.acquisitions, ['goose']);
  });
}
