import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:test/test.dart';

import 'package:dartclaw_runtime/src/templates/chat.dart';
import 'package:dartclaw_runtime/src/templates/channel_detail.dart';
import 'package:dartclaw_runtime/src/web/channel_status.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  // Note: layoutTemplate, sidebarTemplate, topbarTemplate, messagesHtmlFragment,
  // chatAreaTemplate, bannerTemplate, emptyAppStateTemplate, and emptyStateTemplate
  // are covered by render_test.dart which tests the underlying .html templates directly.

  group('channelDetailTemplate', () {
    final sidebarData = (
      main: null,
      dmChannels: <SidebarSession>[],
      groupChannels: <SidebarSession>[],
      activeEntries: <SidebarSession>[],
      archivedEntries: <SidebarSession>[],
      activeTasks: <SidebarActiveTask>[],
      activeWorkflows: <SidebarActiveWorkflow>[],
      showChannels: true,
      tasksEnabled: false,
      activeSessionId: null,
    );
    const navItems = <NavItem>[];

    test('renders hero summary and pairing action', () {
      final html = channelDetailTemplate(
        channelType: 'whatsapp',
        channelLabel: 'WhatsApp',
        status: ChannelStatus.connected,
        phone: '15551234567@s.whatsapp.net',
        dmAccessMode: 'pairing',
        dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
        dmAllowlist: const ['alice@s.whatsapp.net'],
        groupAccessMode: 'allowlist',
        groupAccessModes: const ['allowlist', 'open', 'disabled'],
        groupAllowlist: const ['team@g.us'],
        requireMention: true,
        entryPlaceholder: 'jid',
        groupPlaceholder: 'group',
        sidebarData: sidebarData,
        navItems: navItems,
        pendingPairings: const [],
      );

      expect(html, contains('Channel access rules, pairing approvals, and session routing.'));
      expect(html, contains('Pairing / Registration'));
      expect(html, contains('Disconnect'));
      expect(html, contains('DM mode:'));
      expect(html, contains('Group mode:'));
      expect(html, contains('data-mode-select="dm_access"'));
      expect(html, contains('data-mode-select="group_access"'));
      expect(html, contains('class="content-area print-in"'));
      expect(html, contains('class="content-inner"'));
      expect(html, contains('class="well well-content channel-sub-card"'));
      expect(RegExp('class="well well-content channel-sub-card').allMatches(html), hasLength(4));
      expect(html, isNot(contains('class="well channel-sub-card"')));
      expect(html, contains('id="channel-restart-banner" class="banner banner-warning" hidden'));
      expect(html, contains('class="identicon" aria-hidden="true" data-identicon-id="whatsapp"'));
    });

    test('keys each channel hero identicon by channel type', () {
      String render(String channelType, String channelLabel) => channelDetailTemplate(
        channelType: channelType,
        channelLabel: channelLabel,
        status: ChannelStatus.connected,
        dmAccessMode: 'open',
        dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
        dmAllowlist: const [],
        groupAccessMode: 'open',
        groupAccessModes: const ['allowlist', 'open', 'disabled'],
        groupAllowlist: const [],
        requireMention: false,
        entryPlaceholder: 'entry',
        groupPlaceholder: 'group',
        sidebarData: sidebarData,
        navItems: navItems,
      );

      for (final channel in [('whatsapp', 'WhatsApp'), ('signal', 'Signal'), ('google_chat', 'Google Chat')]) {
        expect(
          render(channel.$1, channel.$2),
          contains('class="identicon" aria-hidden="true" data-identicon-id="${channel.$1}"'),
        );
      }
    });

    test('renders and polls the pairing queue only when mode is pairing', () {
      String renderWithDmMode(String dmAccessMode) => channelDetailTemplate(
        channelType: 'signal',
        channelLabel: 'Signal',
        status: ChannelStatus.pairingNeeded,
        dmAccessMode: dmAccessMode,
        dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
        dmAllowlist: const [],
        groupAccessMode: 'disabled',
        groupAccessModes: const ['allowlist', 'open', 'disabled'],
        groupAllowlist: const [],
        requireMention: false,
        entryPlaceholder: 'phone or uuid',
        groupPlaceholder: 'group',
        sidebarData: sidebarData,
        navItems: navItems,
        pendingPairings: const [
          {'senderId': '+1555', 'displayName': 'Bob', 'remainingLabel': '22m', 'code': 'abc'},
        ],
      );

      final pairingHtml = renderWithDmMode('pairing');
      expect(pairingHtml, contains('Pending Pairing Requests'));
      expect(pairingHtml, contains('data-section="pairing"'));
      expect(_pairingSectionTag(pairingHtml), isNot(contains('hidden')));
      expect(pairingHtml, contains('hx-trigger="every 5s"'));
      expect(pairingHtml, contains('Known DM Allowlist'));
      expect(pairingHtml, contains('Only meaningful when group access is enabled.'));

      final openHtml = renderWithDmMode('open');
      expect(openHtml, isNot(contains('data-section="pairing"')));
      expect(openHtml, isNot(contains('hx-trigger="every 5s"')));
    });

    test('binds labels and names for channel form controls', () {
      final html = channelDetailTemplate(
        channelType: 'signal',
        channelLabel: 'Signal',
        status: ChannelStatus.connected,
        dmAccessMode: 'open',
        dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
        dmAllowlist: const [],
        groupAccessMode: 'disabled',
        groupAccessModes: const ['allowlist', 'open', 'disabled'],
        groupAllowlist: const [],
        requireMention: false,
        entryPlaceholder: 'phone or uuid',
        groupPlaceholder: 'group',
        sidebarData: sidebarData,
        navItems: navItems,
      );

      expect(html, contains('id="channel-dm-access"'));
      expect(html, contains('name="dm_access"'));
      expect(html, contains('for="dm-allowlist-entry"'));
      expect(html, contains('name="dm_allowlist_entry"'));
      expect(html, contains('id="channel-group-access"'));
      expect(html, contains('name="group_access"'));
      expect(html, contains('for="require-mention"'));
      expect(html, contains('id="require-mention"'));
    });

    test('does not render task-trigger controls', () {
      final html = channelDetailTemplate(
        channelType: 'google_chat',
        channelLabel: 'Google Chat',
        status: ChannelStatus.connected,
        dmAccessMode: 'allowlist',
        dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
        dmAllowlist: const [],
        groupAccessMode: 'open',
        groupAccessModes: const ['allowlist', 'open', 'disabled'],
        groupAllowlist: const [],
        requireMention: false,
        entryPlaceholder: 'phone or uuid',
        groupPlaceholder: 'group',
        sidebarData: sidebarData,
        navItems: navItems,
      );

      expect(html, isNot(contains('Task Trigger')));
      expect(html, isNot(contains('task-trigger')));
    });
  });

  group('classifyMessage', () {
    test('user role returns MessageType.user', () {
      final m = classifyMessage(id: '1', role: 'user', content: 'Hello');
      expect(m.messageType, MessageType.user);
      expect(m.detail, isNull);
    });

    test('plain assistant returns MessageType.assistant', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: 'Hi there');
      expect(m.messageType, MessageType.assistant);
      expect(m.detail, isNull);
    });

    test('guard block pattern returns MessageType.guardBlock', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Blocked by guard: profanity]');
      expect(m.messageType, MessageType.guardBlock);
      expect(m.detail, 'profanity');
    });

    test('response blocked pattern returns MessageType.guardBlock', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Response blocked by guard: length]');
      expect(m.messageType, MessageType.guardBlock);
      expect(m.detail, 'length');
    });

    test('turn failed pattern returns MessageType.turnFailed', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Turn failed: timeout]');
      expect(m.messageType, MessageType.turnFailed);
      expect(m.detail, 'timeout');
    });

    test('turn failed without detail returns null detail', () {
      final m = classifyMessage(id: '1', role: 'assistant', content: '[Turn failed]');
      expect(m.messageType, MessageType.turnFailed);
      expect(m.detail, isNull);
    });
  });
}

/// Returns the opening tag of the pairing sub-card, so `hidden` is read off
/// that element rather than found anywhere in the page.
String _pairingSectionTag(String html) {
  final start = html.indexOf('<div class="well well-content channel-sub-card channel-pairing-card"');
  expect(start, isNot(-1), reason: 'pairing sub-card not rendered');
  return html.substring(start, html.indexOf('>', start) + 1);
}
