# Trellis Guidelines

High-level Trellis guidance. This is a policy document, not a full directive reference.

For exact directive syntax and package-specific behavior, use the Trellis package docs and the versioned source used by your project.


---


## Core Principles

- Keep templates simple
- Keep business logic out of templates
- Compute view data in code, not in markup
- Escape by default
- Use raw HTML only at explicit trust boundaries


---


## Core Rules

### Use escaped text by default

Use `tl:text` for normal text output, especially user-controlled content.

```html
<span tl:text="${title}">Title</span>
```

Only use raw HTML when the value is already trusted and pre-rendered.

```html
<div tl:utext="${bodyHtml}">body</div>
```


### Use `tl:attr` for dynamic attributes

Use `tl:attr` when attribute values come from code.

```html
<input tl:attr="value=${title},data-id=${id}">
<a tl:attr="href=${href}">
<form tl:attr="action=${postUrl}">
```

Keep static attributes hardcoded in HTML.


### Keep conditional logic small

Use `tl:if` and `tl:unless` for simple show/hide behavior.

```html
<div tl:if="${bannerHtml}" tl:utext="${bannerHtml}">banner</div>
<div tl:unless="${readOnly}">...</div>
```

Prefer `null` to mean "absent" when that matches the template contract.


### Keep iteration data simple

Use `tl:each` with view-model data that is already prepared for rendering.

```html
<li tl:each="item : ${items}">
  <span tl:text="${item.label}">Item</span>
</li>
```

Do not push filtering, formatting, or business decisions into the loop body if they can be done before render.


### Use fragments for reusable partials

Use `tl:fragment` for sections that need to be rendered independently.

```html
<div tl:fragment="badge">
  <span tl:text="${label}">Label</span>
</div>
```

Keep fragment names stable and descriptive.


### Keep templates dumb

Do in code:
- format dates
- build labels
- choose CSS classes
- filter and sort lists
- decide which fragment or template to render

Do not do those things in template expressions unless the expression is trivial.


---


## Data-Passing Rules

- Pass plain text as plain strings
- Pass trusted HTML only when raw output is intentional
- Pass URLs and attribute values as plain strings
- Pass lists in a render-ready shape
- Pass `null` when the template should omit something

Good:

```dart
{
  'title': title,
  'statusClass': 'status-${status.name}',
  'subtitle': subtitle.isEmpty ? null : subtitle,
}
```

Bad:

```dart
{
  'rawUserHtml': userInput,
  'items': allItems.where((e) => complexFilter(e)).toList(),
}
```


---


## Trust Boundary

The code that prepares template context owns the trust boundary.

- `tl:text`: safe default
- `tl:attr`: safe for attribute output
- `tl:utext`: only for trusted HTML

If a value could contain unsafe HTML, do not pass it to `tl:utext`.


---


## Integration Guidance

- Separate page rendering from fragment rendering
- Reuse preloaded or cached template sources when rendering fragments repeatedly
- Keep template structure stable so CSS, HTMX, and tests can target it reliably
- If using Trellis with HTMX, keep dynamic URLs in template context and keep static HTMX behavior in markup


---


## Avoid

- Using `tl:utext` for untrusted content
- Encoding business logic in template expressions
- Doing heavy formatting work in templates
- Passing half-baked data structures and expecting templates to finish the job
- Using templates as a place to hide controller or service logic
- Letting template contracts drift without updating the calling code


---


## Checklist

- [ ] `tl:text` is the default for text output
- [ ] `tl:utext` is used only for trusted pre-rendered HTML
- [ ] Dynamic attributes come from `tl:attr`
- [ ] Conditions are simple and readable
- [ ] Lists are prepared before render
- [ ] Fragments are used for independently rendered partials
- [ ] Formatting and business rules live in code, not in templates

