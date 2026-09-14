import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('accepted inbox and attention wireframes remain linked accessible fixtures', () async {
    final inbox = File(
      await resolveWorkspacePath('dev', 'bundle', 'docs/wireframes/session-sidebar-control-plane.html'),
    ).readAsStringSync();
    final attention = File(await resolveWorkspacePath('dev', 'bundle', 'docs/wireframes/notification-center.html'))
        .readAsStringSync();
    expect(inbox, contains('data-accepted-state="desktop-inbox"'));
    expect(inbox, contains('data-state-count="8"'));
    expect(inbox, contains('Drafts on this device'));
    expect(inbox, contains('settled remotely'));
    expect(inbox, contains('role="separator"'));
    expect(inbox, contains('aria-live="polite"'));
    expect(attention, contains('data-accepted-state="paged-attention"'));
    expect(attention, contains('data-event-id="record:req-1"'));
    expect(attention, contains('data-attention-action="approve"'));
    expect(attention, contains('data-outage-state'));
    expect(attention, contains('data-recovery-state'));
  });
}
