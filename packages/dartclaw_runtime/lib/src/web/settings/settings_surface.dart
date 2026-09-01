import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import '../../api/api_helpers.dart';
import '../../api/config_apply_service.dart';
import '../../restart_service.dart';
import '../../auth/request_auth_context.dart';
import '../../config/config_serializer.dart';
import '../../runtime_config.dart';
import '../../templates/restart_banner.dart';
import '../../templates/settings_form.dart';
import '../web_utils.dart';
import 'settings_field_view.dart';
import 'settings_form_model.dart';
import 'settings_sections.dart';

/// The largest form-encoded settings submission accepted, matching the JSON
/// tier's own body cap.
const _maxSettingsFormBytes = 128 * 1024;

/// The editable half of `/settings`: what the page renders and what a save does.
///
/// Both directions read the same [ConfigMeta] projection, so a control the page
/// shows and a value the POST accepts cannot come apart.
final class SettingsSurface {
  /// Creates a [SettingsSurface] value.
  new({required this.writer, required this.applyService, required this.dataDir, required this.runtimeConfig});

  /// Writer owning the YAML the form reads and writes.
  final ConfigWriter writer;

  /// The one config-apply authority, shared with `PATCH /api/config`.
  final ConfigApplyService applyService;

  /// Data directory holding `restart.pending`.
  final String dataDir;

  /// Current runtime state, so a live-tier field renders what is in effect.
  final RuntimeConfig runtimeConfig;

  /// Renders every form panel, keyed by panel id.
  Map<String, String> renderPanels() {
    final resolver = _resolver();
    final pending = restartPendingFields(dataDir).toSet();
    return {
      for (final panel in settingsPanels)
        if (panel.isForm)
          panel.id: settingsSectionFragment(
            buildSettingsPanelView(panel: panel, resolver: resolver, pendingRestart: pending),
          ),
    };
  }

  /// Renders registry fields owned by a purpose-built settings surface.
  String renderOwnedFields({
    required String id,
    required String title,
    required List<FieldMeta> fields,
    required String action,
  }) {
    final panel = SettingsPanel(id: id, tab: 'settings', title: title);
    final view = buildSettingsPanelView(
      panel: panel,
      resolver: _resolver(),
      fields: fields,
      pendingRestart: restartPendingFields(dataDir).toSet(),
    );
    return settingsSectionFragment(view, action: action);
  }

  /// Applies a form submission for registry fields owned outside `/settings`.
  Future<Response> handleOwnedSubmit(
    Request request, {
    required String id,
    required String title,
    required List<FieldMeta> fields,
    required String action,
  }) async {
    final panel = SettingsPanel(id: id, tab: 'settings', title: title);
    return _handleSubmit(request, panel: panel, fields: fields, action: action);
  }

  /// Handles `POST /settings`.
  ///
  /// Answers 200 with the re-rendered section on both success and validation
  /// failure — 4xx is reserved for a refusal where nothing is swapped — and
  /// carries the restart banner out of band so no second fetch is needed.
  Future<Response> handleSubmit(Request request) async {
    final parsed = await _readForm(request);
    if (parsed.error != null) return parsed.error!;
    final form = parsed.value!;
    final sectionId = form[settingsSectionFormField];
    final panel = _formPanel(sectionId);
    if (panel == null) {
      return errorResponse(400, 'INVALID_INPUT', 'Unknown settings section: ${sectionId ?? '(none)'}');
    }

    return _apply(panel: panel, form: form);
  }

  Future<Response> _handleSubmit(
    Request request, {
    required SettingsPanel panel,
    List<FieldMeta>? fields,
    String? action,
  }) async {
    final parsed = await _readForm(request);
    if (parsed.error != null) return parsed.error!;
    return _apply(panel: panel, form: parsed.value!, fields: fields, action: action);
  }

  Future<Response> _apply({
    required SettingsPanel panel,
    required Map<String, String> form,
    List<FieldMeta>? fields,
    String? action,
  }) async {
    try {
      final changes = decodeSettingsSubmission(panel: panel, form: form, resolver: _resolver(), fields: fields);
      final result = await applyService.apply(changes);
      final pending = restartPendingFields(dataDir);
      final view = buildSettingsPanelView(
        panel: panel,
        resolver: _resolver(),
        fields: fields,
        errors: result.errors,
        applied: result.applied.toSet(),
        pendingRestart: pending.toSet(),
        statusMessage: settingsSubmissionSummary(result),
      );
      final section = settingsSectionFragment(view, action: action ?? '/settings');
      final banner = restartBannerTemplate(pendingFields: pending, outOfBand: true);
      return Response.ok('$section$banner', headers: htmlHeaders);
    } on SettingsSubmissionRefused catch (e) {
      return errorResponse(400, 'INVALID_INPUT', e.message);
    } on ConfigReadException catch (e) {
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to read config: ${e.cause}');
    } on StateError catch (e) {
      return errorResponse(500, 'BACKUP_FAILED', e.message);
    } on FileSystemException catch (e) {
      return errorResponse(500, 'WRITE_FAILED', 'Config write failed: ${e.message}');
    }
  }

  static Future<({Map<String, String>? value, Response? error})> _readForm(Request request) async {
    if (!requestHasAdminAccess(request)) {
      return (value: null, error: errorResponse(403, 'FORBIDDEN', 'Config changes require an admin user'));
    }
    final parsed = await readFormFields(request, maxBytes: _maxSettingsFormBytes);
    if (parsed.error != null) return (value: null, error: parsed.error);
    return (value: {for (final entry in parsed.fields.entries) entry.key: entry.value.firstOrNull ?? ''}, error: null);
  }

  static SettingsPanel? _formPanel(String? id) {
    for (final panel in settingsPanels) {
      if (panel.isForm && panel.id == id) return panel;
    }
    return null;
  }

  SettingsValueResolver _resolver() {
    const serializer = ConfigSerializer();
    return SettingsValueResolver(
      serialized: serializer.toJson(applyService.freshConfig(), runtime: runtimeConfig),
      yaml: writer.readDocument(),
    );
  }
}

/// Builds the settings surface for a deployment, or `null` when it has no
/// writable config file — the settings page then renders read-only.
SettingsSurface? buildSettingsSurface({
  required ConfigWriter? writer,
  required RuntimeConfig? runtimeConfig,
  required String? dataDir,
  bool containerIsolationActive = false,
  EventBus? eventBus,
  ConfigNotifier? configNotifier,
}) {
  if (writer == null || runtimeConfig == null || dataDir == null) return null;
  return SettingsSurface(
    writer: writer,
    runtimeConfig: runtimeConfig,
    dataDir: dataDir,
    applyService: ConfigApplyService(
      writer: writer,
      validator: const ConfigValidator(),
      dataDir: dataDir,
      containerIsolationActive: containerIsolationActive,
      eventBus: eventBus,
      configNotifier: configNotifier,
    ),
  );
}
