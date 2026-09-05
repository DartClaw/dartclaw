import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';

import '../../config/channel_config_resolver.dart';
import '../../api/channel_access_service.dart';
import '../../api/guard_editor_service.dart';
import '../../api/api_helpers.dart';
import '../../auth/request_auth_context.dart';
import '../../health/health_service.dart';
import '../../provider_status_service.dart';
import '../../restart_service.dart';
import '../../templates/guard_config_summary.dart';
import '../../templates/channel_detail.dart';
import '../../templates/error_page.dart';
import '../../templates/helpers.dart';
import '../../templates/settings.dart';
import '../../templates/restart_banner.dart';
import '../../templates/sidebar.dart' show SidebarData;
import '../dashboard_page.dart';
import '../channel_status.dart';
import '../page_support.dart';
import '../settings/settings_surface.dart';
import '../web_utils.dart';

const channelPurposeBuiltConfigFields = {
  'dm_access',
  'dm_allowlist',
  'group_access',
  'group_allowlist',
  'require_mention',
};

const guardEditorConfigFields = {
  'guards.command.extra_blocked_patterns',
  'guards.command.extra_blocked_pipe_targets',
  'guards.file.extra_rules',
  'guards.network.extra_allowed_domains',
  'guards.network.extra_exfil_patterns',
};

List<FieldMeta> channelRegistryFields(String type) => [
  for (final meta in ConfigMeta.fields.values)
    if ((meta.yamlPath.startsWith('channels.$type.') &&
            !channelPurposeBuiltConfigFields.contains(meta.yamlPath.substring('channels.$type.'.length))) ||
        (type == 'whatsapp' &&
            meta.yamlPath.startsWith('channels.') &&
            !meta.yamlPath.startsWith('channels.$type.') &&
            !meta.yamlPath.startsWith('channels.signal.') &&
            !meta.yamlPath.startsWith('channels.google_chat.')))
      meta,
];

List<FieldMeta> guardRegistryFields() => [
  for (final meta in ConfigMeta.fields.values)
    if (meta.yamlPath.startsWith('guards.') && !guardEditorConfigFields.contains(meta.yamlPath)) meta,
];

typedef _ChannelDetailData = ({
  String type,
  String label,
  ChannelStatus status,
  String? phone,
  String dmAccessMode,
  List<String> dmAllowlist,
  String groupAccessMode,
  List<String> groupAllowlist,
  bool requireMention,
  String entryPlaceholder,
  String groupPlaceholder,
  List<Map<String, dynamic>> pendingPairings,
});

/// Renders the runtime-settings dashboard page.
class SettingsPage extends DashboardPage {
  new({
    this.healthService,
    this.workerStateGetter,
    this.whatsAppChannel,
    this.signalChannel,
    this.googleChatChannel,
    this.guardChain,
    this.providerStatus,
    this.settingsSurface,
    this.channelAccessService,
    this.guardEditorService,
  });

  final HealthService? healthService;
  final WorkerState? Function()? workerStateGetter;
  final WhatsAppChannel? whatsAppChannel;
  final SignalChannel? signalChannel;
  final GoogleChatChannel? googleChatChannel;
  final GuardChain? guardChain;
  final ProviderStatusService? providerStatus;

  /// The editable half of this page, shared with `POST /settings`.
  ///
  /// Absent on a server with no writable config: the form panels then render
  /// the shared empty state instead of controls.
  final SettingsSurface? settingsSurface;
  final ChannelAccessService? channelAccessService;
  final GuardEditorService? guardEditorService;

  @override
  String get route => '/settings';

  @override
  String get title => 'Settings';

  @override
  String? get icon => 'settings';

  @override
  String get navGroup => 'system';

  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'GET', path: '/settings/channels/<type>'),
    (method: 'POST', path: '/settings/channels/<type>/access'),
    (method: 'POST', path: '/settings/channels/<type>/<list>-allowlist/<action>'),
    (method: 'GET', path: '/settings/channels/<type>/pairings'),
    (method: 'POST', path: '/settings/channels/<type>/pairings/<action>'),
    (method: 'POST', path: '/settings/channels/<type>/fields'),
    (method: 'GET', path: '/settings/guards/<guard>'),
    (method: 'POST', path: '/settings/guards/<guard>/add'),
    (method: 'POST', path: '/settings/guards/<guard>/<field>/<index>/update'),
    (method: 'POST', path: '/settings/guards/<guard>/<field>/<index>/delete'),
    (method: 'GET', path: '/settings/guards/<guard>/<field>/<index>/edit'),
    (method: 'POST', path: '/settings/guards/fields'),
  ];

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final segments = request.url.pathSegments;
    if (segments.length >= 3 && segments[0] == 'settings' && segments[1] == 'channels') {
      final type = segments[2];
      if (segments.length == 3) return _handleChannelDetail(type, context);
      if (segments.length == 4 && segments[3] == 'access') return _handleChannelAccess(type, request, context);
      if (segments.length == 4 && segments[3] == 'pairings') {
        return _handleChannelDetail(type, context, fragment: 'pairings');
      }
      if (segments.length == 5 && segments[3] == 'pairings') {
        return _handlePairing(type, segments[4], request, context);
      }
      if (segments.length == 5 && segments[3].endsWith('-allowlist')) {
        return _handleAllowlist(type, segments[3].split('-').first, segments[4], request, context);
      }
      if (segments.length == 4 && segments[3] == 'fields') return _handleChannelFields(type, request);
    }
    if (segments.length >= 3 && segments[0] == 'settings' && segments[1] == 'guards') {
      if (segments.length == 3 && segments[2] == 'fields') return _handleGuardFields(request);
      if (segments.length == 3) return _guardEditorResponse(segments[2]);
      if (segments.length == 4 && segments[3] == 'add') return _handleGuardAdd(segments[2], request);
      if (segments.length == 6 && segments[5] == 'edit') {
        return _handleGuardEdit(segments[2], segments[3], int.tryParse(segments[4]));
      }
      if (segments.length == 6 && segments[5] == 'delete') {
        return _handleGuardDelete(segments[2], segments[3], int.tryParse(segments[4]), request);
      }
      if (segments.length == 6 && segments[5] == 'update') {
        return _handleGuardUpdate(segments[2], segments[3], int.tryParse(segments[4]), request);
      }
    }
    final allSessions = await context.sessions.listSessions();
    final sidebarData = await context.sidebar.build();
    final status = await getStatus(healthService, workerStateGetter, allSessions.length);
    final gc = guardChain;
    final guardsEnabled = gc != null;
    final security = context.config?.security ?? const SecurityConfig();
    final guardConfigs = extractGuardConfigs(
      gc,
      security: security,
      apiKeyConfigured: context.contentGuardApiKeyConfigured,
      failOpen: context.contentGuardFailOpen,
    );
    final providerCards = _buildProviderCards(providerStatus?.all ?? const <ProviderStatus>[]);
    final providerSummary = _buildProviderSummary(providerStatus?.summary);
    final waStatus = await whatsAppChannelStatus(whatsAppChannel);
    final sigStatus = await signalChannelStatus(signalChannel);
    final pageConfig = context.config;
    final googleChatConfig = pageConfig == null
        ? const GoogleChatConfig.disabled()
        : resolveChannelConfig<GoogleChatConfig>(pageConfig, ChannelType.googlechat);
    final googleChatConfigured = googleChatConfig.enabled;

    final page = settingsTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      uptimeSeconds: status['uptime_s'] as int? ?? 0,
      sessionCount: status['session_count'] as int? ?? 0,
      status: status['status'] as String,
      version: status['version'] as String? ?? '',
      providers: providerCards,
      providerConfiguredCount: providerSummary.configured,
      providerHealthyCount: providerSummary.healthy,
      providerDegradedCount: providerSummary.degraded,
      whatsAppEnabled: whatsAppChannel != null,
      whatsAppStatus: waStatus,
      whatsAppPhone: jidToPhone(whatsAppChannel?.gowa.pairedJid),
      whatsAppPendingCount: whatsAppChannel?.dmAccess.pendingPairings.length ?? 0,
      signalEnabled: signalChannel != null,
      signalPhone: signalChannel?.sidecar.registeredPhone,
      signalStatus: sigStatus,
      signalPendingCount: signalChannel?.dmAccess.pendingPairings.length ?? 0,
      googleChatEnabled: googleChatConfigured,
      googleChatStatus: googleChatChannelStatus(googleChatChannel, enabledInConfig: googleChatConfigured),
      googleChatPendingCount: googleChatChannel?.dmAccess?.pendingPairings.length ?? 0,
      guardsEnabled: guardsEnabled,
      guardFailOpen: gc?.failOpen ?? false,
      guardConfigs: guardConfigs,
      workspacePath: context.config?.workspaceDir,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
      sectionHtml: settingsSurface?.renderPanels() ?? const {},
      guardEditorState: guardEditorService?.readState() ?? const {},
      guardFieldsHtml: _guardFieldsHtml(),
    );

    return Response.ok(page, headers: htmlHeaders);
  }

  Future<Response> _handleChannelDetail(
    String type,
    PageContext context, {
    String? fragment,
    String? dmError,
    String? dmValue,
    String? groupError,
    String? groupValue,
    String? accessError,
    String? accessErrorField,
    Map<String, String>? extraHeaders,
    bool includeDmOob = false,
    bool includeRestartOob = false,
  }) async {
    if (!const {'whatsapp', 'signal', 'google_chat'}.contains(type)) {
      return Response.notFound(
        errorPageTemplate(404, 'Not Found', 'Unknown channel type: $type', appName: context.appName),
        headers: htmlHeaders,
      );
    }
    final sidebarData = await context.sidebar.build();
    final displayConfig = settingsSurface?.applyService.freshConfig() ?? context.config;
    final channelAccess = channelAccessService;
    final dmResult = await channelAccess?.readAllowlist(type, 'dm');
    final groupResult = await channelAccess?.readAllowlist(type, 'group');
    final dmAllowlist = _allowlistFrom(dmResult);
    final groupAllowlist = _allowlistFrom(groupResult);

    final data = await _channelDetailData(type, displayConfig, dmAllowlist, groupAllowlist);
    return _channelResponse(
      context,
      sidebarData,
      data,
      fragment: fragment,
      dmError: dmError,
      dmValue: dmValue,
      groupError: groupError,
      groupValue: groupValue,
      accessError: accessError,
      accessErrorField: accessErrorField,
      extraHeaders: extraHeaders,
      includeDmOob: includeDmOob,
      includeRestartOob: includeRestartOob,
    );
  }

  Future<_ChannelDetailData> _channelDetailData(
    String type,
    DartclawConfig? config,
    List<String>? dmAllowlist,
    List<String>? groupAllowlist,
  ) async {
    if (type == 'whatsapp') {
      final channel = whatsAppChannel;
      final configured = config == null
          ? const WhatsAppConfig.disabled()
          : resolveChannelConfig<WhatsAppConfig>(config, ChannelType.whatsapp);
      return (
        type: type,
        label: 'WhatsApp',
        status: channel == null ? ChannelStatus.disabled : await whatsAppChannelStatus(channel),
        phone: channel == null ? null : jidToPhone(channel.gowa.pairedJid),
        dmAccessMode: configured.dmAccess.name,
        dmAllowlist: dmAllowlist ?? channel?.dmAccess.allowlist.toList() ?? const [],
        groupAccessMode: configured.groupAccess.name,
        groupAllowlist: groupAllowlist ?? channel?.config.groupIds ?? const [],
        requireMention: configured.requireMention,
        entryPlaceholder: '15551234567@s.whatsapp.net',
        groupPlaceholder: '12345678@g.us',
        pendingPairings: channel == null ? const <Map<String, dynamic>>[] : pendingPairingsData(channel.dmAccess),
      );
    }
    if (type == 'signal') {
      final channel = signalChannel;
      final configured = config == null
          ? const SignalConfig.disabled()
          : resolveChannelConfig<SignalConfig>(config, ChannelType.signal);
      return (
        type: type,
        label: 'Signal',
        status: channel == null ? ChannelStatus.disabled : await signalChannelStatus(channel),
        phone: channel?.sidecar.registeredPhone,
        dmAccessMode: configured.dmAccess.name,
        dmAllowlist: dmAllowlist ?? channel?.dmAccess.allowlist.toList() ?? const [],
        groupAccessMode: configured.groupAccess.name,
        groupAllowlist: groupAllowlist ?? channel?.config.groupIds ?? const [],
        requireMention: configured.requireMention,
        entryPlaceholder: '+15551234567 or UUID',
        groupPlaceholder: 'base64-group-id',
        pendingPairings: channel == null ? const <Map<String, dynamic>>[] : pendingPairingsData(channel.dmAccess),
      );
    }
    final channel = googleChatChannel;
    final configured = config == null
        ? const GoogleChatConfig.disabled()
        : resolveChannelConfig<GoogleChatConfig>(config, ChannelType.googlechat);
    return (
      type: type,
      label: 'Google Chat',
      status: googleChatChannelStatus(channel, enabledInConfig: configured.enabled),
      phone: null,
      dmAccessMode: configured.dmAccess.name,
      dmAllowlist: dmAllowlist ?? const [],
      groupAccessMode: configured.groupAccess.name,
      groupAllowlist: groupAllowlist ?? const [],
      requireMention: configured.requireMention,
      entryPlaceholder: 'users/123456789',
      groupPlaceholder: 'spaces/AAAA',
      pendingPairings: channel?.dmAccess == null
          ? const <Map<String, dynamic>>[]
          : pendingPairingsData(channel!.dmAccess!),
    );
  }

  Response _channelResponse(
    PageContext context,
    SidebarData sidebarData,
    _ChannelDetailData data, {
    String? fragment,
    String? dmError,
    String? dmValue,
    String? groupError,
    String? groupValue,
    String? accessError,
    String? accessErrorField,
    Map<String, String>? extraHeaders,
    bool includeDmOob = false,
    bool includeRestartOob = false,
  }) {
    final ownedFields = channelRegistryFields(data.type);
    final settingsFieldsHtml = settingsSurface == null || ownedFields.isEmpty
        ? ''
        : settingsSurface!.renderOwnedFields(
            id: 'channel-${data.type}-fields',
            title: 'Advanced configuration',
            fields: ownedFields,
            action: '/settings/channels/${data.type}/fields',
          );
    final rendered = _renderChannel(
      data,
      sidebarData,
      context,
      settingsFieldsHtml: settingsFieldsHtml,
      fragment: fragment,
      dmError: dmError,
      dmValue: dmValue,
      groupError: groupError,
      groupValue: groupValue,
      accessError: accessError,
      accessErrorField: accessErrorField,
    );
    final dmOob = includeDmOob
        ? _renderChannel(data, sidebarData, context, fragment: 'dmAllowlist', dmAllowlistOutOfBand: true)
        : '';
    final restartOob = includeRestartOob && settingsSurface != null
        ? restartBannerTemplate(pendingFields: restartPendingFields(settingsSurface!.dataDir), outOfBand: true)
        : '';
    return Response.ok('$rendered$dmOob$restartOob', headers: {...htmlHeaders, ...?extraHeaders});
  }

  String _renderChannel(
    _ChannelDetailData data,
    SidebarData sidebarData,
    PageContext context, {
    String settingsFieldsHtml = '',
    String? fragment,
    String? dmError,
    String? dmValue,
    String? groupError,
    String? groupValue,
    String? accessError,
    String? accessErrorField,
    bool dmAllowlistOutOfBand = false,
  }) => channelDetailTemplate(
    channelType: data.type,
    channelLabel: data.label,
    status: data.status,
    phone: data.phone,
    dmAccessMode: data.dmAccessMode,
    dmAccessModes: const ['open', 'disabled', 'allowlist', 'pairing'],
    dmAllowlist: data.dmAllowlist,
    groupAccessMode: data.groupAccessMode,
    groupAccessModes: const ['open', 'disabled', 'allowlist'],
    groupAllowlist: data.groupAllowlist,
    requireMention: data.requireMention,
    entryPlaceholder: data.entryPlaceholder,
    groupPlaceholder: data.groupPlaceholder,
    sidebarData: sidebarData,
    navItems: context.navItems(activePage: title),
    pendingPairings: data.pendingPairings,
    settingsFieldsHtml: settingsFieldsHtml,
    fragment: fragment,
    dmError: dmError,
    dmValue: dmValue,
    groupError: groupError,
    groupValue: groupValue,
    accessError: accessError,
    accessErrorField: accessErrorField,
    dmAllowlistOutOfBand: dmAllowlistOutOfBand,
    restartBannerHtml: context.restartBannerHtml(),
    appName: context.appName,
  );

  Future<Response> _handleChannelAccess(String type, Request request, PageContext context) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Config changes require an admin user');
    if (!{'whatsapp', 'signal', 'google_chat'}.contains(type)) {
      return errorResponse(404, 'NOT_FOUND', 'Unknown channel type: $type');
    }
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final form = formResult.value!;
    final surface = settingsSurface;
    if (surface == null) return errorResponse(503, 'UNAVAILABLE', 'Channel access editing is unavailable');
    final accessFields = {'dm_access', 'group_access', 'require_mention'}.where(form.containsKey).toList();
    if (accessFields.length != 1) {
      return errorResponse(400, 'INVALID_INPUT', 'Submit one complete channel access control');
    }
    final updates = <String, Object?>{};
    final field = accessFields.single;
    final raw = form[field] ?? '';
    updates['channels.$type.$field'] = field == 'require_mention' ? raw == 'true' : raw;
    final result = await surface.applyService.apply(updates);
    final message = result.errors.firstOrNull?.message;
    return _handleChannelDetail(
      type,
      context,
      fragment: 'channelAccess',
      accessError: message,
      accessErrorField: message == null ? null : field,
      includeRestartOob: result.isValid,
    );
  }

  Future<Response> _handleAllowlist(
    String type,
    String list,
    String action,
    Request request,
    PageContext context,
  ) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Config changes require an admin user');
    if (!{'dm', 'group'}.contains(list) || !{'add', 'remove'}.contains(action)) {
      return errorResponse(404, 'NOT_FOUND', 'Unknown allowlist action');
    }
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final form = formResult.value!;
    final entry = form['entry'] ?? form['${list}_allowlist_entry'] ?? '';
    final service = channelAccessService;
    if (service == null) return errorResponse(503, 'UNAVAILABLE', 'Channel access editing is unavailable');
    final result = action == 'add'
        ? await service.addAllowlist(type, list, entry)
        : await service.removeAllowlist(type, list, entry);
    final refusal = result is ChannelAccessRefused ? result : null;
    return _handleChannelDetail(
      type,
      context,
      fragment: list == 'dm' ? 'dmAllowlist' : 'groupAllowlist',
      dmError: list == 'dm' && action == 'add' ? refusal?.message : null,
      dmValue: list == 'dm' && action == 'add' && refusal != null ? entry : null,
      groupError: list == 'group' && action == 'add' ? refusal?.message : null,
      groupValue: list == 'group' && action == 'add' && refusal != null ? entry : null,
      extraHeaders: action == 'remove' && refusal != null ? toastTriggerHeader('error', refusal.message) : null,
      includeRestartOob: list == 'group' && refusal == null,
    );
  }

  Future<Response> _handlePairing(String type, String action, Request request, PageContext context) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Config changes require an admin user');
    if (!{'confirm', 'reject'}.contains(action)) return errorResponse(404, 'NOT_FOUND', 'Unknown pairing action');
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final form = formResult.value!;
    final service = channelAccessService;
    if (service == null) return errorResponse(503, 'UNAVAILABLE', 'Channel access editing is unavailable');
    final result = action == 'confirm'
        ? await service.confirmPairing(type, form['code'])
        : service.rejectPairing(type, form['code']);
    final refusal = result is ChannelAccessRefused ? result : null;
    return _handleChannelDetail(
      type,
      context,
      fragment: 'pairings',
      extraHeaders: refusal == null ? null : toastTriggerHeader('info', refusal.message),
      includeDmOob: action == 'confirm' && refusal == null,
    );
  }

  Future<Response> _handleChannelFields(String type, Request request) async {
    final surface = settingsSurface;
    if (surface == null) return errorResponse(503, 'UNAVAILABLE', 'Settings editing is unavailable');
    return surface.handleOwnedSubmit(
      request,
      id: 'channel-$type-fields',
      title: 'Advanced configuration',
      fields: channelRegistryFields(type),
      action: '/settings/channels/$type/fields',
    );
  }

  static Future<({Map<String, String>? value, Response? error})> _form(Request request) async {
    final parsed = await readFormFields(request, maxBytes: 128 * 1024);
    if (parsed.error != null) return (value: null, error: parsed.error);
    return (value: {for (final entry in parsed.fields.entries) entry.key: entry.value.firstOrNull ?? ''}, error: null);
  }

  Response _guardEditorResponse(String guard, {String? error, String value = ''}) {
    final service = guardEditorService;
    if (service == null) return errorResponse(503, 'UNAVAILABLE', 'Guard editing is unavailable');
    return Response.ok(
      guardEditorFragment(service.readState(), activeGuard: guard, error: error, value: value),
      headers: htmlHeaders,
    );
  }

  Future<Response> _handleGuardAdd(String guard, Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Guard editing requires an admin user');
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final form = formResult.value!;
    final field = form['field'] ?? '';
    final value = form['value'] ?? '';
    final input = guard == 'file' ? {'pattern': value, 'level': form['level'] ?? 'no_access'} : value;
    try {
      await guardEditorService!.createEntry(guard, field, input);
      return _guardEditorResponse(guard);
    } on GuardEditorValidationException catch (error) {
      return _guardEditorResponse(guard, error: error.errors.join('; '), value: value);
    }
  }

  Future<Response> _handleGuardUpdate(String guard, String field, int? index, Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Guard editing requires an admin user');
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final form = formResult.value!;
    if (index == null) return _guardEditorResponse(guard, error: 'Invalid guard rule');
    final expected = form['display'];
    final value = form['value'] ?? '';
    final level = form['level'] ?? 'no_access';
    if (expected == null || _guardDisplayAt(guardEditorService!.readState(), guard, field, index) != expected) {
      return _guardEditDialogResponse(
        guard,
        field,
        index,
        display: expected ?? '',
        value: value,
        level: level,
        error: 'The rule changed since it was displayed; refresh and try again.',
      );
    }
    final input = guard == 'file' ? {'pattern': value, 'level': level} : value;
    try {
      await guardEditorService!.updateEntry(guard, field, index, input);
      return _guardEditorResponse(guard);
    } on GuardEditorValidationException catch (error) {
      return _guardEditDialogResponse(
        guard,
        field,
        index,
        display: expected,
        value: value,
        level: level,
        error: error.errors.join('; '),
      );
    }
  }

  Response _guardEditDialogResponse(
    String guard,
    String field,
    int index, {
    required String display,
    required String value,
    required String level,
    String? error,
  }) => Response.ok(
    guardEditDialogFragment(
      guard: guard,
      field: field,
      index: index,
      display: display,
      value: value,
      level: level,
      isFile: guard == 'file',
      error: error,
    ),
    headers: {...htmlHeaders, 'HX-Retarget': '#guard-edit-dialog-host'},
  );

  Response _handleGuardEdit(String guard, String field, int? index) {
    if (index == null) return _guardEditorResponse(guard, error: 'Invalid guard rule');
    final state = guardEditorService!.readState();
    final entry = _guardEntryAt(state, guard, field, index);
    if (entry == null) return _guardEditorResponse(guard, error: 'The guard rule no longer exists.');
    return Response.ok(
      guardEditDialogFragment(
        guard: guard,
        field: field,
        index: index,
        display: _guardDisplayAt(state, guard, field, index)!,
        value: entry is Map ? entry['pattern']?.toString() ?? '' : entry.toString(),
        level: entry is Map ? entry['level']?.toString() ?? 'no_access' : 'no_access',
        isFile: guard == 'file',
      ),
      headers: htmlHeaders,
    );
  }

  Future<Response> _handleGuardDelete(String guard, String field, int? index, Request request) async {
    if (!requestHasAdminAccess(request)) return errorResponse(403, 'FORBIDDEN', 'Guard editing requires an admin user');
    if (index == null) return _guardEditorResponse(guard, error: 'Invalid guard rule');
    final formResult = await _form(request);
    if (formResult.error != null) return formResult.error!;
    final expected = formResult.value!['display'];
    final current = _guardDisplayAt(guardEditorService!.readState(), guard, field, index);
    if (expected == null || current != expected) {
      return _guardEditorResponse(guard, error: 'The rule changed since it was displayed; refresh and try again.');
    }
    try {
      await guardEditorService!.deleteEntry(guard, field, index);
      return _guardEditorResponse(guard);
    } on GuardEditorValidationException catch (error) {
      return _guardEditorResponse(guard, error: error.errors.join('; '));
    }
  }

  Future<Response> _handleGuardFields(Request request) async {
    final surface = settingsSurface;
    if (surface == null) return errorResponse(503, 'UNAVAILABLE', 'Settings editing is unavailable');
    return surface.handleOwnedSubmit(
      request,
      id: 'guard-fields',
      title: 'Guard configuration',
      fields: guardRegistryFields(),
      action: '/settings/guards/fields',
    );
  }

  String _guardFieldsHtml() {
    final surface = settingsSurface;
    if (surface == null) return '';
    return surface.renderOwnedFields(
      id: 'guard-fields',
      title: 'Guard configuration',
      fields: guardRegistryFields(),
      action: '/settings/guards/fields',
    );
  }

  static String? _guardDisplayAt(Map<String, Object?> state, String guard, String field, int index) {
    final entry = _guardEntryAt(state, guard, field, index);
    if (entry == null) return null;
    if (entry is Map) return '${entry['pattern'] ?? ''} · ${entry['level'] ?? ''}';
    return entry.toString();
  }

  static Object? _guardEntryAt(Map<String, Object?> state, String guard, String field, int index) {
    final groups = (state['guards'] as List?)?.whereType<Map<Object?, Object?>>();
    final group = groups?.where((entry) => entry['guard'] == guard).firstOrNull;
    final fields = group?['fields'];
    final entries = fields is Map ? fields[field] : null;
    if (entries is! List || index < 0 || index >= entries.length) return null;
    return entries[index];
  }

  static List<String>? _allowlistFrom(ChannelAccessResult? result) => switch (result) {
    ChannelAccessApplied(:final body) => (body['allowlist'] as List?)?.whereType<String>().toList(),
    _ => null,
  };
}

({int configured, int healthy, int degraded}) _buildProviderSummary(Map<String, dynamic>? summary) {
  final counts = summary ?? const <String, dynamic>{};
  return (
    configured: _summaryCount(counts['configured']),
    healthy: _summaryCount(counts['healthy']),
    degraded: _summaryCount(counts['degraded']),
  );
}

int _summaryCount(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse('$value') ?? 0;
}

List<Map<String, Object?>> _buildProviderCards(List<ProviderStatus> providers) {
  return providers.map(_buildProviderCard).toList(growable: false);
}

Map<String, Object?> _buildProviderCard(ProviderStatus provider) {
  final healthUi = _providerHealthUi(provider.health);
  final credentialOk = provider.credentialStatus != 'missing';
  final capacityUsagePercent = _capacityUsagePercent(
    activeWorkers: provider.activeWorkers,
    effectiveWorkers: provider.effectiveWorkers,
  );

  return <String, Object?>{
    'id': provider.id,
    'title': ProviderIdentity.displayName(provider.id),
    'subtitle': 'Provider ID: ${provider.id}',
    'iconLabel': _providerIconLabel(provider.id),
    'iconClass': _providerIconClass(provider.id, binaryFound: provider.binaryFound),
    'isDefault': provider.isDefault,
    'healthLabel': healthUi.label,
    'healthBadgeClass': healthUi.badgeClass,
    'binaryStatusLabel': provider.binaryFound ? 'Found' : 'Not found',
    'binaryStatusClass': provider.binaryFound ? 'detail-value-ok' : 'detail-value-error',
    'executable': provider.executable,
    'versionDisplay': provider.binaryFound ? (absentValue(provider.version).value ?? '') : 'Not found',
    // An unreported version renders canon's .value-absent through the existing
    // class hook; "Not found" stays, being a determinate finding rather than
    // an unknown field.
    'versionClass': provider.binaryFound
        ? (absentValue(provider.version).isAbsent ? 'value-absent' : '')
        : 'detail-value-error',
    'credentialStatusLabel': switch (provider.credentialStatus) {
      'present' => 'Present',
      'oauth' => 'Authenticated',
      _ => 'Missing',
    },
    'credentialValueClass': credentialOk ? 'detail-value-ok' : 'detail-value-error',
    'credentialDotClass': credentialOk ? 'credential-dot-ok' : 'credential-dot-missing',
    'credentialEnvVarDisplay': _credentialSourceLabel(provider),
    'capacityUsageText': '${provider.activeWorkers} of ${provider.effectiveWorkers} worker leases active',
    'capacityUsageLabel': '$capacityUsagePercent% of worker capacity in use',
    'capacityUsageWidthStyle': 'width: $capacityUsagePercent%;',
    'capacityMeterEmptyClass': capacityUsagePercent == 0 ? 'meter--empty' : '',
    'capacityDetails':
        '${provider.queuedWorkers} queued · ${provider.cachedWorkers} warm · '
        '${provider.quarantinedWorkers} quarantined',
    'hasError': provider.errorMessage != null,
    'errorTitle': _providerErrorTitle(provider),
    'errorMessage': provider.errorMessage,
    ..._credentialHealthEntries(provider),
  };
}

/// Where the presented credential comes from, rendered directly above the
/// recorded mode.
///
/// The recorded mode decides before the presence answer does: `present` says
/// only that some credential resolved, so naming the API-key env var there puts
/// `ANTHROPIC_API_KEY` one line above `Subscription` on a card presenting a
/// stored subscription.
String _credentialSourceLabel(ProviderStatus provider) {
  if (provider.credentialStatus == 'oauth') {
    return 'OAuth / subscription login';
  }
  if (provider.credentialMode == 'subscription') {
    return 'Stored subscription credential';
  }
  return provider.credentialEnvVar ?? 'Credential source not configured';
}

/// Credential-health entries for the provider card's credential section.
///
/// Nothing here is rendered until health is recorded, and within a recorded
/// block the mode, expiry and remediation are each independently optional — so
/// every element carries its own `has*` boolean rather than sharing one.
Map<String, Object?> _credentialHealthEntries(ProviderStatus provider) {
  final health = _credentialHealthState(provider.credentialHealth);
  final state = _credentialStateUi(health);
  final mode = switch (provider.credentialMode) {
    'subscription' => 'Subscription',
    'api_key' => 'API key',
    _ => null,
  };
  final countdown = _credentialCountdown(
    mode: provider.credentialMode,
    expiresAt: provider.credentialExpiresAt,
    // Presenting a derived estimate as exact is the harmful direction.
    derived: provider.credentialExpiryDerived ?? true,
  );
  final lastChecked = provider.credentialLastChecked;
  // `unknown` keeps its command even though CredentialHealthState.isDegraded
  // excludes it: there the command upgrades an unmanaged vendor login to
  // DartClaw-managed auth rather than repairing a fault.
  final remediation = state == null ? null : absentValue(provider.credentialRemediation).value as String?;

  return <String, Object?>{
    'hasCredentialMode': mode != null,
    'credentialModeLabel': mode ?? '',
    'hasCredentialCountdown': countdown != null,
    'credentialCountdownLabel': countdown?.label ?? '',
    'credentialCountdownClass': countdown?.styleClass ?? '',
    'hasCredentialState': state != null,
    'credentialStateLabel': state?.label ?? '',
    'credentialStateVariant': state?.variant ?? '',
    'hasCredentialLastChecked': lastChecked != null,
    'credentialLastCheckedLabel': lastChecked == null ? '' : 'Checked ${formatRelativeTime(lastChecked)}',
    'credentialLastCheckedIso': isoTitle(lastChecked?.toIso8601String()),
    'credentialExpiresAtIso': isoTitle(provider.credentialExpiresAt?.toIso8601String()),
    'hasCredentialRemediation': remediation != null,
    'credentialRemediationLabel': health == CredentialHealthState.unknown ? 'DartClaw-managed auth:' : 'Fix:',
    'credentialRemediation': remediation ?? '',
  };
}

/// Resolves the wire string `ProviderStatus` carries back to its state.
///
/// Recovering the enum is what makes [_credentialStateUi] exhaustive, so a
/// seventh state cannot reach this page rendering as a healthy one.
CredentialHealthState? _credentialHealthState(String? jsonName) {
  for (final state in CredentialHealthState.values) {
    if (state.jsonName == jsonName) {
      return state;
    }
  }
  return null;
}

/// The credential state's badge, or `null` where no state line is shown.
///
/// `unknown` takes the neutral badge deliberately: an uncheckable credential is
/// not degraded (for Claude it means an interactive vendor login DartClaw does
/// not manage), so it must not borrow a warning hue.
({String label, String variant})? _credentialStateUi(CredentialHealthState? health) => switch (health) {
  CredentialHealthState.nearingExpiry => (label: 'Nearing expiry', variant: 'warning'),
  CredentialHealthState.refreshFailure => (label: 'Refresh failed', variant: 'warning'),
  CredentialHealthState.reauthRequired => (label: 'Re-authentication required', variant: 'error'),
  CredentialHealthState.contractBreak => (label: 'Mediation contract broken', variant: 'error'),
  CredentialHealthState.unknown => (label: 'Lifetime not checkable', variant: 'muted'),
  CredentialHealthState.healthy || null => null,
};

/// The renewal countdown, or `null` for a provider whose credential does not
/// age out (an API key) or whose mode was never recorded.
({String label, String styleClass})? _credentialCountdown({
  required String? mode,
  required DateTime? expiresAt,
  required bool derived,
}) {
  if (mode != 'subscription') {
    return null;
  }
  if (expiresAt == null) {
    return (label: 'Renewal deadline unknown', styleClass: 'value-absent');
  }
  final remaining = formatRemainingTimeIso(expiresAt.toIso8601String());
  // Colon, not a bare join: past 30 elapsed days formatRelativeTime answers an
  // absolute date, and "passed 12 Jul" would read as a typo.
  final label = remaining.isEmpty ? 'Renewal deadline passed: ${formatRelativeTime(expiresAt)}' : 'Renewal $remaining';
  return (label: derived ? '$label · derived' : label, styleClass: '');
}

int _capacityUsagePercent({required int activeWorkers, required int effectiveWorkers}) {
  if (effectiveWorkers <= 0) {
    return 0;
  }
  final percent = ((activeWorkers / effectiveWorkers) * 100).round();
  return percent.clamp(0, 100).toInt();
}

({String label, String badgeClass}) _providerHealthUi(String health) {
  return switch (health) {
    'healthy' => (label: 'Healthy', badgeClass: 'status-badge-success'),
    'degraded' => (label: 'Degraded', badgeClass: 'status-badge-warning'),
    _ => (label: 'Unavailable', badgeClass: 'status-badge-error'),
  };
}

String _providerIconLabel(String id) {
  final normalized = id.trim().toUpperCase();
  if (normalized.isEmpty) {
    return '??';
  }
  if (normalized.length <= 2) {
    return normalized;
  }
  return normalized.substring(0, 2);
}

String _providerIconClass(String id, {required bool binaryFound}) {
  if (!binaryFound) {
    return 'provider-icon-missing';
  }
  return switch (ProviderIdentity.family(id)) {
    'claude' => 'provider-icon-claude',
    'codex' => 'provider-icon-codex',
    _ => 'provider-icon-generic',
  };
}

String _providerErrorTitle(ProviderStatus provider) {
  if (!provider.binaryFound) {
    return 'Binary unavailable';
  }
  if (provider.credentialStatus == 'missing') {
    return 'Credentials missing';
  }
  return 'Action required';
}
