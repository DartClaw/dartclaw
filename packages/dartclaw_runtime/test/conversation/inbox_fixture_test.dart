import 'package:test/test.dart';

import 'inbox_test_fixture.dart';

void main() {
  test('fixture exposes 200 stable conversations through the production projection', () async {
    final fixture = await InboxTestFixture.create(count: InboxTestFixture.conversationCount);
    addTearDown(fixture.dispose);

    final first = await fixture.inbox.inbox(limit: 200);
    final second = await fixture.inbox.inbox(limit: 200);
    expect(first.entries.map((entry) => entry.session.id), second.entries.map((entry) => entry.session.id));
    expect(first.total, 200);
    expect(InboxTestFixture.now, DateTime.utc(2026, 9, 30, 12));
  });
}
