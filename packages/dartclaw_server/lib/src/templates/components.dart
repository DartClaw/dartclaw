import 'helpers.dart';
import 'loader.dart';

/// Banner notification. [type] is one of `error`, `warning`, or `info`.
/// [message] is auto-escaped by Trellis (`tl:text`).
String bannerTemplate(String type, String message) {
  final safeType = const {'error', 'warning', 'info'}.contains(type) ? type : 'error';
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'banner',
    context: {'type': safeType, 'message': message},
  );
}

/// The one empty-state treatment: decorative visual, headline, body copy and an
/// optional action.
///
/// [title] and [body] are auto-escaped by Trellis. [actionHtml] is inserted
/// verbatim and must be **server-owned control markup** — never user content.
///
/// [useMascot] swaps the default decorative icon for the 64px mascot. Both
/// visuals are decorative (`aria-hidden` / empty `alt`) because [title] and
/// [body] carry the state; the mascot exists for the in-session chat empty
/// only, and every other caller keeps the default.
/// Prompt-hero greeting — the typed-glyph claw moment for a landing or status
/// view. One per view; it replaces, never joins, a mascot or claw-loader
/// moment. [titleHtml] is rendered unescaped so a word can wrap in
/// `.text-gradient`: it must be a server-authored static string — never
/// interpolate user data into it. User-sourced copy belongs in [eyebrow] or
/// [sub], which are escaped.
String promptHeroTemplate({
  required String titleHtml,
  String? eyebrow,
  String? sub,
  String? modifiers,
  bool useMascot = false,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'promptHero',
    context: {
      'titleHtml': titleHtml,
      'eyebrow': _slot(eyebrow),
      'sub': _slot(sub),
      'modifiers': modifiers ?? '',
      'useMascot': useMascot,
    },
  );
}

String emptyStateTemplate({required String title, required String body, String? actionHtml, bool useMascot = false}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'emptyState',
    context: {'title': title, 'body': body, 'actionHtml': _slot(actionHtml), 'useMascot': useMascot},
  );
}

/// Empty app state shown when no sessions exist yet.
///
/// [appName] is the configurable instance name shown in the call-to-action text.
String emptyAppStateTemplate({String appName = 'DartClaw'}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'emptyAppState',
    context: {'appName': appName},
  );
}

/// Status badge with semantic color variant.
///
/// [variant] maps to `status-badge-{variant}` CSS class (e.g., `success`,
/// `error`, `warning`, `muted`, `running`, `queued`).
/// [text] is the badge label, auto-escaped by Trellis.
///
/// [dot] adds a leading `status-dot--{dot}` so the state is not carried by
/// colour alone. The dot renders empty on purpose: consumers that poll a
/// badge's `textContent` must still read exactly [text] after trimming.
String statusBadgeTemplate({required String variant, required String text, String? dot}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'statusBadge',
    context: {'variant': variant, 'text': text, 'dot': dot},
  );
}

/// Status pill — the heavier sibling of [statusBadgeTemplate], for table cells
/// and card footers.
///
/// [variant] maps to `status-pill--{variant}` (`live`, `error`, `warning`,
/// `info`). [dot] adds a leading `status-dot--{dot}`, as above.
String statusPillTemplate({required String variant, required String text, String? dot}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'statusPill',
    context: {'variant': variant, 'text': text, 'dot': dot},
  );
}

/// Simple metric card with colored accent.
///
/// [color] maps to `card-metric--{color}` CSS class (e.g., `accent`, `info`,
/// `error`, `warning`).
/// Use for KPI displays with a single value and label. For metric cards with
/// custom sub-content (budget bars, fill indicators), use inline HTML instead.
String metricCardTemplate({
  required String color,
  required Object? value,
  required String label,
  String? labelTooltip,
}) {
  final resolved = absentValue(value);
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'metricCard',
    context: {
      'color': color,
      'value': resolved.value ?? '',
      'valueAbsent': resolved.isAbsent,
      'label': label,
      'labelTooltip': labelTooltip,
    },
  );
}

/// Page header: the one heading treatment every non-chat surface uses.
///
/// Emits `<header class="pagehead">` with an optional `.t-page-title` heading,
/// an optional subtitle and a right-aligned action slot. The heading is an
/// `<h2>`, not an `<h1>` — the topbar owns the page's single `<h1>`
/// (DESIGN.md § Layout → Page title and skip link).
///
/// Pass an empty [title] to render subtitle and actions with no heading.
///
/// [actionsHtml] is inserted verbatim and must be **server-owned control
/// markup** — never user content. Action labels read verb+noun ("Add Project",
/// not "New"), and a create action carries `data-icon="plus"` rather than a
/// literal `"+ "` in its label text.
String pageHeaderTemplate({String title = '', String? subtitle, String? actionsHtml}) {
  // Trellis reads an empty string as truthy, so blank slots are normalised to
  // null or `tl:if` would emit an empty heading / subtitle / action wrapper.
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'pageHeader',
    context: {'title': _slot(title), 'subtitle': _slot(subtitle), 'actionsHtml': _slot(actionsHtml)},
  );
}

String? _slot(String? value) => (value == null || value.isEmpty) ? null : value;

/// Info card with key-value rows and a footer status badge.
///
/// [variant] maps to `status-badge-{variant}` (e.g., `success`, `error`,
/// `warning`, `muted`), matching [statusBadgeTemplate].
/// [rows] is a list of maps with `label`, `value`, and optional `valueClass` keys.
String infoCardTemplate({
  required String title,
  required String badgeText,
  required String variant,
  required List<Map<String, dynamic>> rows,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('components'),
    fragment: 'infoCard',
    context: {'title': title, 'badgeText': badgeText, 'variant': variant, 'rows': rows},
  );
}
