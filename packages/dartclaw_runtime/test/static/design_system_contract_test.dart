import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('disabled and idle status dots remain semantically distinct', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    final scheduling = File(await resolveServerPackagePath('lib', 'src', 'templates', 'scheduling.dart'))
        .readAsStringSync();
    expect(css, contains('.status-dot--idle'));
    expect(css, contains('.status-dot--muted'));
    expect(scheduling, contains("task.enabled ? 'status-dot--live' : 'status-dot--muted'"));
  });

  test('the empty-state hero glyph is scoped to the direct child', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    // As a descendant rule this painted the action button's leading icon
    // accent-on-accent inside .btn-primary, where it was invisible, and its 1em
    // box pushed the label off centre.
    expect(css, contains('.empty-state > .icon {'));
    expect(css, contains('.empty-state > .icon:not([class*="icon-"]) {'));
    expect(css, isNot(contains('.empty-state .icon')));
  });

  test('both icon-button size tiers rest borderless', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    // A rule naming only .btn-icon left every .btn-icon-sm — queue rows,
    // popover close buttons, the rail's settle and archive actions — a bordered
    // square with the glyph pushed off centre.
    expect(css, contains(':is(.btn-icon, .btn-icon-sm):not(.btn-primary):not(.btn-danger-fill):not(.btn-danger) {'));
  });

  test('the popover and menu vocabulary is canon, not app-owned', () async {
    final canon = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    final app = File(await resolveServerPackagePath('lib', 'src', 'static', 'app.css')).readAsStringSync();
    for (final selector in ['.pop', '.pop-head', '.pop-sep', '.menu-item', '.menu-tick', '.menu-item--on']) {
      // Anchored at the start of a line, so an app-side *placement* override
      // written as a descendant (`.pop-view .pop-head { … }`) still reads as
      // app-owned rather than as a redeclaration of the canon rule.
      final declaration = RegExp('^${RegExp.escape(selector)}[ ,{]', multiLine: true);
      expect(canon, matches(declaration), reason: '$selector must live in canon');
      expect(app, isNot(matches(declaration)), reason: '$selector must not be redeclared in the app layer');
    }
    // The tick column re-templates .palette-item's grid at equal specificity,
    // so source order is the only thing deciding it.
    expect(canon.indexOf('.menu-item {'), greaterThan(canon.indexOf('.palette-item {')));
  });

  test('the field tier marker is quiet text, never a pill', () async {
    final css = File(await resolveDesignSystemCss('components.css')).readAsStringSync();
    final tier = css.substring(css.indexOf('.field-tier {'), css.indexOf('.field-tier--warn'));
    // The label row is uppercase with caps tracking and both inherit; a marker
    // that keeps them reads as a second eyebrow rather than as an aside.
    expect(tier, contains('text-transform: none'));
    expect(tier, contains('letter-spacing: normal'));
    expect(tier, contains('margin-left: auto'));
    expect(tier, contains('color: var(--fg-overlay)'));
    expect(tier, isNot(contains('background')));
    expect(tier, isNot(contains('border')));
    expect(css, contains('.field-tier--warn { color: var(--warning); }'));
    expect(css, contains('.field-tier--ok { color: var(--success); }'));
  });
}
