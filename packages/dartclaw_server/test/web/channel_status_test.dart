import 'dart:io';

import 'package:dartclaw_server/src/templates/channel_detail.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/settings.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/channel_status.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// One presentation record drives every channel status consumer. What these
/// tests protect is that three statuses sharing `status-badge-warning` cannot
/// collapse into one presentation — `Not running`, `Configured` and `Pairing
/// needed` differ in dot, banner and hint — and that `Disabled` is never
/// reported as merely "not running".
void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData sidebar = (
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

  // The full seven-row contract, restated so changing the enum has to be a
  // deliberate change to this table too.
  const contract = <ChannelStatus, ChannelStatusPresentation>{
    ChannelStatus.disabled: (
      label: 'Disabled',
      badgeClass: 'status-badge-muted',
      dotVariant: 'idle',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.notRunning: (
      label: 'Not running',
      badgeClass: 'status-badge-warning',
      dotVariant: 'idle',
      stateBannerVariant: 'warning',
      stateBannerText: 'Channel is not running. Policy changes apply when it starts.',
      dmPolicyHint: 'DM allowlist changes apply when the channel starts.',
      connected: false,
    ),
    ChannelStatus.configured: (
      label: 'Configured',
      badgeClass: 'status-badge-warning',
      dotVariant: 'warning',
      stateBannerVariant: 'warning',
      stateBannerText: 'Channel is configured but not running. Policy changes apply when it starts.',
      dmPolicyHint: 'DM allowlist changes apply when the channel starts.',
      connected: false,
    ),
    ChannelStatus.pairingNeeded: (
      label: 'Pairing needed',
      badgeClass: 'status-badge-warning',
      dotVariant: 'attention',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.connectionError: (
      label: 'Connection error',
      badgeClass: 'status-badge-error',
      dotVariant: 'error',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
    ChannelStatus.connected: (
      label: 'Connected',
      badgeClass: 'status-badge-success',
      dotVariant: 'live',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: 'DM allowlist changes take effect immediately.',
      connected: true,
    ),
    ChannelStatus.reconnecting: (
      label: 'Reconnecting',
      badgeClass: 'status-badge-warning',
      dotVariant: 'warning',
      stateBannerVariant: null,
      stateBannerText: null,
      dmPolicyHint: null,
      connected: false,
    ),
  };

  String renderDetail(
    ChannelStatus status, {
    String channelType = 'google_chat',
    String channelLabel = 'Google Chat',
    String dmAccessMode = 'allowlist',
    List<String> dmAllowlist = const [],
    List<String> groupAllowlist = const [],
  }) {
    return channelDetailTemplate(
      channelType: channelType,
      channelLabel: channelLabel,
      status: status,
      dmAccessMode: dmAccessMode,
      dmAccessModes: const ['pairing', 'allowlist', 'open', 'disabled'],
      dmAllowlist: dmAllowlist,
      groupAccessMode: 'allowlist',
      groupAccessModes: const ['allowlist', 'open', 'disabled'],
      groupAllowlist: groupAllowlist,
      requireMention: false,
      entryPlaceholder: 'users/123',
      groupPlaceholder: 'spaces/AAAA',
      sidebarData: sidebar,
      navItems: navItems,
    );
  }

  group('ChannelStatus.presentation', () {
    test('every value matches the contract field for field', () {
      expect(ChannelStatus.values.length, contract.length);
      for (final status in ChannelStatus.values) {
        final expected = contract[status];
        expect(expected, isNotNull, reason: '$status has no contract row');
        expect(status.presentation, expected, reason: '$status presentation drifted');
      }
    });

    test('the three warning-badge states stay distinguishable', () {
      final warning = ChannelStatus.values.where((s) => s.presentation.badgeClass == 'status-badge-warning');
      expect(warning, hasLength(4));
      // notRunning/configured/pairingNeeded/reconnecting share a badge but must
      // not share a dot-and-banner pair.
      final fingerprints = warning
          .map((s) => '${s.presentation.dotVariant}|${s.presentation.stateBannerText}|${s.presentation.dmPolicyHint}')
          .toSet();
      expect(fingerprints, hasLength(4));
    });

    test('disabled is neutral, and is never told it is merely not running', () {
      final p = ChannelStatus.disabled.presentation;
      expect(p.badgeClass, 'status-badge-muted');
      expect(p.dotVariant, 'idle');
      expect(p.stateBannerText, isNull);
      expect(p.dmPolicyHint, isNull);
    });

    test('only connected reports the immediate-change hint and the connected flag', () {
      for (final status in ChannelStatus.values) {
        final isConnected = status == ChannelStatus.connected;
        expect(status.presentation.connected, isConnected, reason: '$status');
        expect(
          status.presentation.dmPolicyHint == 'DM allowlist changes take effect immediately.',
          isConnected,
          reason: '$status',
        );
      }
    });

    test('the presentation getter has no wildcard or default arm', () {
      final source = File(_channelStatusPath()).readAsStringSync();
      final start = source.indexOf('ChannelStatusPresentation get presentation');
      expect(start, isNot(-1));
      final body = source.substring(start, source.indexOf('\n  };', start));

      expect(body, isNot(contains('_ =>')));
      expect(body, isNot(contains('default')));
      // One arm per value, so a new status is a compile error, not a fallback.
      for (final status in ChannelStatus.values) {
        expect(body, contains('ChannelStatus.${status.name} =>'), reason: '${status.name} arm missing');
      }
    });
  });

  group('emitted class names exist in the served stylesheet', () {
    late String css;

    setUpAll(() {
      css = File(_servedCssPath()).readAsStringSync();
    });

    test('every badge, dot and banner suffix resolves to a real selector', () {
      final badges = ChannelStatus.values.map((s) => s.presentation.badgeClass).toSet();
      final dots = ChannelStatus.values.map((s) => '.status-dot--${s.presentation.dotVariant}').toSet();
      final banners = ChannelStatus.values
          .map((s) => s.presentation.stateBannerVariant)
          .whereType<String>()
          .map((v) => '.banner-$v')
          .toSet();

      for (final selector in [...badges.map((b) => '.$b'), ...dots, ...banners]) {
        // Canon aligns some declarations, so allow padding before the brace —
        // but require the selector to end there, not merely appear somewhere.
        expect(
          css,
          matches(RegExp('${RegExp.escape(selector)}\\s*[{,]')),
          reason: '$selector is emitted but has no rule',
        );
      }
    });

    test('no consumer invents a muted dot or a dot-only badge', () {
      // S03 ships the neutral badge and deliberately keeps disabled's dot at
      // --idle; there is no --muted dot to adopt.
      expect(css, isNot(contains('.status-dot--muted')));
      final dotOnlySuffixes = ['live', 'idle', 'attention'];
      for (final suffix in dotOnlySuffixes) {
        expect(
          ChannelStatus.values.any((s) => s.presentation.badgeClass == 'status-badge-$suffix'),
          isFalse,
          reason: 'status-badge-$suffix is a dot suffix, not a badge variant',
        );
      }
    });
  });

  group('channel detail consumes the record', () {
    test('badge, dot and state banner all come from the same status', () {
      for (final status in ChannelStatus.values) {
        final p = status.presentation;
        final html = renderDetail(status);

        expect(html, contains('class="status-badge ${p.badgeClass}"'), reason: '$status badge');
        expect(html, contains('class="status-dot status-dot--${p.dotVariant}"'), reason: '$status dot');
        if (p.stateBannerText == null) {
          expect(html, isNot(contains('banner banner-${p.stateBannerVariant}"')), reason: '$status has no banner');
        } else {
          expect(html, contains(p.stateBannerText!), reason: '$status banner copy');
          expect(html, contains('banner banner-${p.stateBannerVariant}'), reason: '$status banner variant');
        }
        if (p.dmPolicyHint == null) {
          expect(html, isNot(contains('DM allowlist changes')), reason: '$status has no DM hint');
        } else {
          expect(html, contains(p.dmPolicyHint!), reason: '$status DM hint');
        }
      }
    });

    test('a not-running channel says so and keeps its policy panels editable', () {
      final html = renderDetail(ChannelStatus.notRunning);

      expect(html, contains('Channel is not running. Policy changes apply when it starts.'));
      expect(html, contains('DM allowlist changes apply when the channel starts.'));
      expect(html, isNot(contains('DM allowlist changes take effect immediately.')));
      // The panels stay usable: the banner explains when changes apply.
      expect(html, isNot(contains('aria-disabled')));
      expect(html, contains('class="allowlist-add-form"'));
      expect(html, contains('Add entry'));
    });

    test('configured gets its own banner copy, not the not-running one', () {
      final html = renderDetail(ChannelStatus.configured);

      expect(html, contains('Channel is configured but not running. Policy changes apply when it starts.'));
      expect(html, isNot(contains('Channel is not running. Policy changes apply when it starts.')));
    });

    test('a connection error gets the error badge and dot but no not-running story', () {
      final html = renderDetail(ChannelStatus.connectionError);

      expect(html, contains('class="status-badge status-badge-error"'));
      expect(html, contains('status-dot--error'));
      expect(html, isNot(contains('Policy changes apply when it starts.')));
      expect(html, isNot(contains('DM allowlist changes')));
    });

    test('disabled, pairing-needed and reconnecting get neither not-running copy nor the immediate hint', () {
      for (final status in [ChannelStatus.disabled, ChannelStatus.pairingNeeded, ChannelStatus.reconnecting]) {
        final html = renderDetail(status);
        expect(html, isNot(contains('Policy changes apply when it starts.')), reason: '$status');
        expect(html, isNot(contains('DM allowlist changes')), reason: '$status');
      }
    });

    test('google chat renders no pairing anchor, connected whatsapp renders both actions', () {
      final gchat = renderDetail(ChannelStatus.notRunning);
      expect(gchat, isNot(contains('Pairing / Registration')));
      expect(gchat, isNot(contains('Disconnect')));

      final whatsapp = renderDetail(ChannelStatus.connected, channelType: 'whatsapp', channelLabel: 'WhatsApp');
      expect(whatsapp, contains('Pairing / Registration'));
      expect(whatsapp, contains('Disconnect'));
      expect(whatsapp, contains('DM allowlist changes take effect immediately.'));

      // Not connected: the pairing route still exists, the disconnect does not.
      final notRunningWhatsapp = renderDetail(
        ChannelStatus.notRunning,
        channelType: 'whatsapp',
        channelLabel: 'WhatsApp',
      );
      expect(notRunningWhatsapp, contains('Pairing / Registration'));
      expect(notRunningWhatsapp, isNot(contains('Disconnect')));
    });

    test('the hero title is a heading below the topbar h1, at the display tier', () {
      final html = renderDetail(ChannelStatus.connected);

      expect(html, contains('<h2 class="t-display">Google Chat</h2>'));
      // The topbar owns the page's only h1.
      final heroStart = html.indexOf('channel-detail-hero-row');
      expect(html.substring(heroStart), isNot(contains('<h1')));
    });

    test('channel_detail.dart makes no status decision of its own', () {
      final source = File(_channelDetailPath()).readAsStringSync();

      expect(source, isNot(contains("statusLabel == 'Connected'")));
      expect(source, isNot(contains('isConnected')));
      // No second switch over the enum: the record is the only mapping.
      expect(source, isNot(contains('switch (status)')));
      expect(source, isNot(contains('ChannelStatus.connected')));
    });
  });

  group('empty allowlists render the same row the client path renders', () {
    test('an empty DM allowlist shows "No entries" on the first server render', () {
      final html = renderDetail(ChannelStatus.connected);

      // Two empty lists, two rows — the client path emits the same markup.
      expect(RegExp('class="text-muted">No entries<').allMatches(html), hasLength(2));
      expect(html, contains('class="allowlist-count-num">0<'));
    });

    test('a populated allowlist shows rows and the right count instead', () {
      final html = renderDetail(
        ChannelStatus.connected,
        dmAllowlist: const ['users/1', 'users/2'],
        groupAllowlist: const ['spaces/A'],
      );

      expect(html, isNot(contains('>No entries<')));
      expect(html, contains('users/1'));
      expect(html, contains('class="allowlist-count-num">2<'));
      expect(html, contains('class="allowlist-count-num">1<'));
    });
  });

  group('the settings summary uses the same record', () {
    test('each channel badge carries the record label and its own dot', () {
      final html = settingsTemplate(
        sidebarData: sidebar,
        navItems: navItems,
        uptimeSeconds: 60,
        sessionCount: 0,
        workerState: 'running',
        version: '0.0.0',
        whatsAppStatus: ChannelStatus.connected,
        signalStatus: ChannelStatus.notRunning,
        googleChatStatus: ChannelStatus.pairingNeeded,
      );

      expect(html, contains('class="status-badge status-badge-success"'));
      expect(html, contains('status-dot--live'));
      expect(html, contains('status-dot--idle'));
      expect(html, contains('status-dot--attention'));
      expect(html, contains('Not running'));
      expect(html, contains('Pairing needed'));
      // The retired ad-hoc fallbacks must not reappear.
      expect(html, isNot(contains('Not configured')));
      expect(html, isNot(contains('status-badge-warn"')));
    });
  });
}

String _channelStatusPath() => _pkgPath('lib/src/web/channel_status.dart');

String _channelDetailPath() => _pkgPath('lib/src/templates/channel_detail.dart');

String _servedCssPath() => _pkgPath('lib/src/static/design-system.css');

/// Resolves a package-relative path whether tests run from the package root or
/// the workspace root.
String _pkgPath(String relative) {
  if (File(relative).existsSync()) return relative;
  return 'packages/dartclaw_server/$relative';
}
