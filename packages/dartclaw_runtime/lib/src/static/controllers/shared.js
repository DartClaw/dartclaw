const TOAST_DURATION = 4000;
const TOAST_MAX = 5;

export function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function sanitizeClassToken(value, fallback) {
  const token = String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return token || fallback;
}

export function identiconVariant(id) {
  let hash = 0;
  for (const char of String(id ?? '')) {
    hash = (hash * 31 + char.codePointAt(0)) >>> 0;
  }
  return (hash % 6) + 1;
}

function identiconInitials(value) {
  const words = String(value ?? '')
    .trim()
    .split(/\s+/)
    .map((word) => Array.from(word).filter((char) => /[\p{L}\p{N}]/u.test(char)))
    .filter((characters) => characters.length > 0);
  if (words.length > 1) return words.slice(0, 2).map((characters) => characters[0]).join('');
  return words[0]?.slice(0, 2).join('') || '?';
}

export function applyIdenticons(root = document) {
  const mounts = [];
  if (root.matches?.('.identicon[data-identicon-id]')) mounts.push(root);
  const descendants = root.querySelectorAll ? root.querySelectorAll('.identicon[data-identicon-id]') : [];
  mounts.push(...descendants);
  mounts.forEach((mount) => {
    mount.classList.remove(...Array.from(mount.classList).filter((name) => /^identicon--[1-6]$/.test(name)));
    mount.classList.add('identicon--' + identiconVariant(mount.dataset.identiconId));
    mount.textContent = identiconInitials(mount.dataset.identiconInitials || mount.dataset.identiconId);
  });
}

export function syncSidebarSessionTitle(sessionId, title) {
  const titleElement = Array.from(document.querySelectorAll('[data-session-title-id]'))
    .find((element) => element.dataset.sessionTitleId === sessionId);
  if (titleElement) titleElement.textContent = title;
}

export function beginSessionDraftMutation(sessionId) {
  const chatArea = document.querySelector('.chat-area');
  if (!chatArea || chatArea.dataset.sessionId !== sessionId) return;
  const pending = Number.parseInt(chatArea.dataset.sessionMutationPending || '0', 10);
  chatArea.dataset.sessionMutationPending = String(Number.isFinite(pending) ? pending + 1 : 1);
  delete chatArea.dataset.newChatDraft;
}

export function endSessionDraftMutation(sessionId) {
  const chatArea = document.querySelector('.chat-area');
  if (!chatArea || chatArea.dataset.sessionId !== sessionId) return;
  const pending = Number.parseInt(chatArea.dataset.sessionMutationPending || '1', 10) - 1;
  if (pending > 0) {
    chatArea.dataset.sessionMutationPending = String(pending);
    return;
  }
  delete chatArea.dataset.sessionMutationPending;
  document.dispatchEvent(new CustomEvent('dartclaw:session-draft-mutation-complete'));
}

function toastContainer() {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.className = 'toast-container';
    container.setAttribute('role', 'status');
    container.setAttribute('aria-live', 'polite');
    document.body.appendChild(container);
  }
  return container;
}

function removeToast(toast) {
  if (!toast || !toast.parentNode || toast.classList.contains('removing')) return;
  if (toast.dataset.sourceRef) persistentToasts.delete(toast.dataset.sourceRef);
  toast.classList.add('removing');
  toast.addEventListener('animationend', () => toast.remove(), { once: true });
}

const persistentToasts = new Map();

export function showToast(type, message, options = {}) {
  const container = toastContainer();
  const sourceRef = typeof options.sourceRef === 'string' ? options.sourceRef : null;
  if (options.recovered && sourceRef) {
    const existing = persistentToasts.get(sourceRef);
    if (existing) removeToast(existing);
    persistentToasts.delete(sourceRef);
    return;
  }
  if (sourceRef && persistentToasts.has(sourceRef)) return;
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + sanitizeClassToken(type, 'info');
  toast.innerHTML =
    '<span>' + escapeHtml(message) + '</span>' +
    '<button class="toast-dismiss" aria-label="Dismiss" data-icon="x"></button>';
  toast.querySelector('.toast-dismiss')?.addEventListener('click', () => removeToast(toast));
  container.appendChild(toast);
  if (sourceRef) {
    toast.dataset.sourceRef = sourceRef;
    persistentToasts.set(sourceRef, toast);
  }
  while (container.children.length > TOAST_MAX) {
    removeToast(container.firstElementChild);
  }
  if (!options.persistent) setTimeout(() => removeToast(toast), TOAST_DURATION);
}

export function dispatchToast(type, message, options = {}) {
  document.body.dispatchEvent(new CustomEvent('dc:toast', { detail: { type, message, ...options } }));
}

export const TOAST_QUEUE_KEY = 'dartclaw-queued-toast';

// Parks a toast for the next page load. A mutation that navigates tears down
// its own toast along with the document, so the operator sees the page change
// with no confirmation that it worked. Only navigation mutations queue; an
// in-place swap shows its toast directly.
export function queueToast(type, message) {
  try {
    sessionStorage.setItem(TOAST_QUEUE_KEY, JSON.stringify({ type, message }));
  } catch (_) {}
}

let activeDialog = null;

function openCustomDialog({
  title,
  body,
  confirmLabel,
  danger = false,
  inputLabel = null,
  inputValue = '',
} = {}) {
  // Fail closed rather than stack dialogs: a second confirmation raised while one
  // is open would ask about an action the user can no longer see the context for.
  if (activeDialog) return Promise.resolve(inputLabel == null ? false : null);

  const dialog = document.createElement('dialog');
  dialog.className = inputLabel == null
    ? 'dialog dialog--confirm card card-glass'
    : 'dialog dialog--sm card card-glass';

  if (title) {
    const header = document.createElement('div');
    header.className = 'dialog-header';
    const heading = document.createElement('h3');
    heading.className = 't-heading';
    heading.textContent = title;
    header.appendChild(heading);
    dialog.appendChild(header);
  }

  const bodyElement = document.createElement('div');
  bodyElement.className = 'dialog-body';
  // Severity is markup, not a second frame — see DESIGN.md § Feedback.
  if (danger) {
    const glyph = document.createElement('span');
    glyph.className = 'icon icon-triangle-alert';
    glyph.setAttribute('aria-hidden', 'true');
    bodyElement.appendChild(glyph);
  }
  const message = document.createElement('p');
  message.textContent = body == null ? '' : String(body);
  bodyElement.appendChild(message);

  let input = null;
  if (inputLabel != null) {
    const label = document.createElement('label');
    label.className = 'form-label';
    label.htmlFor = 'custom-dialog-input';
    label.textContent = inputLabel;
    input = document.createElement('textarea');
    input.id = 'custom-dialog-input';
    input.className = 'form-textarea';
    input.rows = 5;
    input.value = String(inputValue ?? '');
    bodyElement.append(label, input);
  }
  dialog.appendChild(bodyElement);
  dialog.setAttribute('aria-label', title || message.textContent);

  const cancelButton = document.createElement('button');
  cancelButton.type = 'button';
  cancelButton.className = 'btn btn-ghost btn-sm';
  cancelButton.textContent = 'Cancel';

  const confirmButton = document.createElement('button');
  confirmButton.type = 'button';
  confirmButton.className = danger ? 'btn btn-danger-fill btn-sm' : 'btn btn-sm';
  confirmButton.textContent = confirmLabel;

  const actions = document.createElement('div');
  actions.className = 'dialog-actions';
  actions.append(cancelButton, confirmButton);
  const footer = document.createElement('div');
  footer.className = 'dialog-footer';
  footer.appendChild(actions);
  dialog.appendChild(footer);

  const returnFocus = document.activeElement;
  document.body.appendChild(dialog);
  activeDialog = dialog;

  return new Promise((resolve) => {
    let confirmed = false;
    // Settle off `close` so Escape, the backdrop and both buttons share one exit,
    // and remove the element first so a caller's toast is not occluded by the
    // top layer this dialog occupies.
    dialog.addEventListener('close', () => {
      dialog.remove();
      activeDialog = null;
      if (returnFocus?.isConnected) returnFocus.focus();
      resolve(confirmed ? (input == null ? true : input.value) : input == null ? false : null);
    }, { once: true });
    confirmButton.addEventListener('click', () => {
      confirmed = true;
      dialog.close();
    });
    cancelButton.addEventListener('click', () => dialog.close());
    // The frame owns no padding, so a click reaching it directly is the backdrop.
    // Gate on where the press started, not where it ended — a text-selection drag
    // released over the scrim dispatches its click at the frame and would
    // otherwise dismiss the dialog mid-gesture.
    let pressStartedOnBackdrop = false;
    dialog.addEventListener('pointerdown', (event) => {
      pressStartedOnBackdrop = event.target === dialog;
    });
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog && pressStartedOnBackdrop) dialog.close();
    });
    input?.addEventListener('keydown', (event) => {
      if (event.isComposing || event.key !== 'Enter' || (!event.ctrlKey && !event.metaKey)) return;
      event.preventDefault();
      confirmed = true;
      dialog.close();
    });
    dialog.showModal();
    if (input) {
      input.focus();
      input.select();
    } else if (danger) {
      cancelButton.focus();
    }
  });
}

export function confirmDialog({ title, body, confirmLabel = 'Confirm', danger = false } = {}) {
  return openCustomDialog({ title, body, confirmLabel, danger });
}

export function inputDialog({ title, body, inputLabel = 'Message', value = '', confirmLabel = 'Continue' } = {}) {
  return openCustomDialog({ title, body, confirmLabel, inputLabel, inputValue: value });
}

export function closeAllCustomSelects(except) {
  document.querySelectorAll('.custom-select[data-open="true"]').forEach((wrapper) => {
    if (except && wrapper === except) return;
    wrapper.dataset.open = 'false';
    wrapper.querySelector('.custom-select-trigger')?.setAttribute('aria-expanded', 'false');
  });
}

// Re-reads a wrapped select: rebuilds the menu when its option set has changed,
// then re-labels and re-ticks. Call it after rewriting `select.options`.
export function syncCustomSelect(select) {
  if (!select || typeof select._customSelectSync !== 'function') return;
  select._customSelectSync();
}

let customSelectSeq = 0;
let customSelectOutsideBound = false;

// pointerdown, not click: a click on another control lands after that control
// has already reacted, so a menu left open until then overlaps the thing the
// pointer went to.
function bindCustomSelectOutsideClose() {
  if (customSelectOutsideBound) return;
  customSelectOutsideBound = true;
  document.addEventListener('pointerdown', (event) => {
    if (!event.target?.closest?.('.custom-select')) closeAllCustomSelects();
  });
}

function enhanceCustomSelect(select) {
  if (!select || select.dataset.customSelectInit) return;
  // The markup's opt-out, read before the enhancer sets aria-hidden itself:
  // a select already outside the a11y tree is a value holder behind a
  // purpose-built control, not a control. `data-custom-select-init` alone
  // answers "already enhanced", so the two questions never share an answer.
  if (select.getAttribute('aria-hidden') === 'true') return;
  select.dataset.customSelectInit = '1';
  bindCustomSelectOutsideClose();

  const menuId = `custom-select-menu-${(customSelectSeq += 1)}`;

  const wrapper = document.createElement('div');
  wrapper.className = 'custom-select';
  wrapper.dataset.open = 'false';
  select.parentNode.insertBefore(wrapper, select);
  wrapper.appendChild(select);
  select.classList.add('native-select-hidden');
  select.tabIndex = -1;
  // The trigger is the control now; leaving the select in the a11y tree would
  // announce the same field twice.
  select.setAttribute('aria-hidden', 'true');

  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.className = 'custom-select-trigger';
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');
  trigger.setAttribute('aria-controls', menuId);
  const label = document.createElement('span');
  label.className = 'custom-select-label';
  trigger.append(label);
  nameTriggerAfterSelect(select, trigger);

  const menu = document.createElement('div');
  menu.id = menuId;
  menu.className = 'pop card card-elevated custom-select-menu';
  menu.setAttribute('role', 'listbox');
  wrapper.append(trigger, menu);

  const enabledOptions = () =>
    Array.from(menu.children).filter((row) => !row.disabled);

  function syncFromSelect() {
    const selectedOption = select.options[select.selectedIndex] || select.options[0];
    label.textContent = selectedOption ? (selectedOption.textContent || selectedOption.label || '') : '';
    trigger.disabled = select.disabled;
    for (const row of menu.children) {
      const on = row.dataset.value === select.value;
      row.classList.toggle('menu-item--on', on);
      row.setAttribute('aria-selected', on ? 'true' : 'false');
      const tick = row.firstChild;
      tick.className = on ? 'menu-tick icon-control' : 'menu-tick';
      if (on) tick.dataset.icon = 'check';
      else delete tick.dataset.icon;
    }
  }

  // The rows mirror the option list, so anything that rewrites `select.options`
  // has to be able to reach them. Comparing is cheaper than rebuilding, and a
  // rebuild would drop keyboard focus mid-menu for an unchanged list.
  function menuMatchesOptions() {
    if (select.options.length !== menu.children.length) return false;
    for (let index = 0; index < select.options.length; index += 1) {
      const option = select.options[index];
      const row = menu.children[index];
      if (row.dataset.value !== option.value) return false;
      if (row.disabled !== option.disabled) return false;
      if (row.lastChild.textContent !== (option.textContent || option.label || '')) return false;
    }
    return true;
  }

  function refresh() {
    if (!menuMatchesOptions()) buildOptions();
    syncFromSelect();
  }

  function buildOptions() {
    menu.replaceChildren();
    Array.from(select.options).forEach((option, index) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.id = `${menuId}-option-${index}`;
      row.className = 'palette-item menu-item custom-select-option';
      row.setAttribute('role', 'option');
      row.tabIndex = -1;
      row.dataset.value = option.value;
      row.disabled = option.disabled;

      const tick = document.createElement('span');
      tick.className = 'menu-tick';
      tick.setAttribute('aria-hidden', 'true');
      const text = document.createElement('span');
      text.className = 'palette-item-label';
      text.textContent = option.textContent || option.label || '';
      row.append(tick, text);
      // Focus is the menu's one cursor, so the pointer moves it too. A move, not
      // an enter: the list scrolling under a resting pointer must not take the
      // cursor back from the keyboard.
      row.addEventListener('pointermove', () => {
        if (row.disabled || document.activeElement === row) return;
        row.focus({ preventScroll: true });
      });
      row.addEventListener('click', () => {
        if (option.disabled) return;
        select.value = option.value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        syncFromSelect();
        setOpen(false);
        trigger.focus();
      });
      menu.appendChild(row);
    });
  }

  // Below the trigger whenever the whole menu fits there. Otherwise the side
  // with more room, with the height capped to that room so every row is still
  // reachable by scrolling. Measured on each open: the trigger moves with the
  // page, and a menu clipped by the viewport or a scrolling dialog body hides
  // rows the keyboard can still land on.
  function placeMenu() {
    menu.classList.remove('custom-select-menu--up');
    menu.style.maxHeight = '';
    const anchor = trigger.getBoundingClientRect();
    const box = menu.getBoundingClientRect();
    const gap = box.top - anchor.bottom;
    const bounds = visibleBounds(wrapper);
    const below = bounds.bottom - anchor.bottom - gap;
    if (box.height <= below) return;
    const above = anchor.top - bounds.top - gap;
    const up = above > below;
    menu.classList.toggle('custom-select-menu--up', up);
    const room = Math.max(0, up ? above : below);
    if (box.height > room) menu.style.maxHeight = room + 'px';
  }

  function setOpen(open, { focusOption = false } = {}) {
    if (open && select.disabled) return;
    closeAllCustomSelects(open ? wrapper : null);
    wrapper.dataset.open = open ? 'true' : 'false';
    trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) placeMenu();
    if (!open || !focusOption) return;
    const current = Array.from(menu.children).find((row) => row.dataset.value === select.value && !row.disabled);
    (current || enabledOptions()[0])?.focus();
  }

  let typeBuffer = '';
  let typeTimer = null;
  function typeAhead(key) {
    typeBuffer += key.toLowerCase();
    clearTimeout(typeTimer);
    typeTimer = setTimeout(() => { typeBuffer = ''; }, 700);
    const match = enabledOptions().find((row) => row.textContent.trim().toLowerCase().startsWith(typeBuffer));
    if (!match) return;
    setOpen(true);
    match.focus();
  }

  const isTypeAheadKey = (event) =>
    event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey && event.key !== ' ';

  trigger.addEventListener('click', () => setOpen(wrapper.dataset.open !== 'true', { focusOption: true }));
  trigger.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      setOpen(true, { focusOption: true });
    } else if (isTypeAheadKey(event)) {
      event.preventDefault();
      typeAhead(event.key);
    }
  });

  menu.addEventListener('keydown', (event) => {
    const options = enabledOptions();
    const currentIndex = options.indexOf(document.activeElement);
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      (options[Math.min(currentIndex + 1, options.length - 1)] || options[0])?.focus();
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      (options[Math.max(currentIndex - 1, 0)] || options[options.length - 1])?.focus();
    } else if (event.key === 'Home') {
      event.preventDefault();
      options[0]?.focus();
    } else if (event.key === 'End') {
      event.preventDefault();
      options[options.length - 1]?.focus();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      setOpen(false);
      trigger.focus();
    } else if (isTypeAheadKey(event)) {
      event.preventDefault();
      typeAhead(event.key);
    }
  });

  wrapper.addEventListener('focusout', (event) => {
    if (!wrapper.contains(event.relatedTarget)) setOpen(false);
  });

  select.addEventListener('change', refresh);
  bindFormReset(select, refresh);
  select._customSelectSync = refresh;
  buildOptions();
  syncFromSelect();
}

// The part of the viewport an element's overflow can show: every ancestor that
// clips (any overflow but `visible`) narrows it.
function visibleBounds(element) {
  let top = 0;
  let bottom = window.innerHeight;
  for (let node = element.parentElement; node; node = node.parentElement) {
    if (getComputedStyle(node).overflowY === 'visible') continue;
    const rect = node.getBoundingClientRect();
    top = Math.max(top, rect.top);
    bottom = Math.min(bottom, rect.bottom);
  }
  return { top, bottom };
}

// A form reset restores the native select silently — no `change` fires — so the
// trigger would keep the label of the value the user just discarded. The reset
// event itself arrives *before* the browser has restored the control values, so
// the resync has to wait a task for the values it is about to read.
//
// The listener sits on the form, which outlives the select under an inner
// swap, so it retires itself once the select it speaks for is detached.
function bindFormReset(select, refresh) {
  const form = select.form;
  if (!form) return;
  const onReset = () => {
    setTimeout(() => {
      if (!select.isConnected) {
        form.removeEventListener('reset', onReset);
        return;
      }
      refresh();
    }, 0);
  };
  form.addEventListener('reset', onReset);
}

// The trigger replaces the select as the control, so it has to inherit the
// select's accessible name — a `<label for>` points at an element no one can
// reach any more.
function nameTriggerAfterSelect(select, trigger) {
  const ariaLabel = select.getAttribute('aria-label');
  if (ariaLabel) {
    trigger.setAttribute('aria-label', ariaLabel);
    return;
  }
  if (!select.id) return;
  const labelElement = document.querySelector(`label[for="${CSS.escape(select.id)}"]`);
  if (!labelElement) return;
  if (!labelElement.id) labelElement.id = `${select.id}-label`;
  trigger.setAttribute('aria-labelledby', labelElement.id);
}

// Every select that is a control, with no opt-in attribute. The selector asks
// only "not enhanced yet"; the markup's opt-out is `enhanceCustomSelect`'s.
export function initCustomSelects(root = document) {
  root.querySelectorAll('select.form-select:not([data-custom-select-init])').forEach(enhanceCustomSelect);
}

export function renderMarkdown(root = document) {
  if (typeof window.marked === 'undefined' || typeof window.DOMPurify === 'undefined') return;
  root.querySelectorAll('[data-markdown]').forEach((element) => {
    const raw = window.marked.parse(element.textContent);
    element.innerHTML = window.DOMPurify.sanitize(raw);
    if (typeof window.hljs !== 'undefined') {
      element.querySelectorAll('code').forEach((block) => window.hljs.highlightElement(block));
    }
    element.removeAttribute('data-markdown');
  });
}

/// Whether [el] is scrolled to (or within [threshold] of) its bottom.
///
/// A container that does not overflow reports true: there is nothing to scroll
/// back through, so new content should keep tracking.
export function isAtBottom(el, threshold = 32) {
  if (!el) return false;
  return el.scrollHeight - el.clientHeight - el.scrollTop <= threshold;
}

/// Anchors the `.messages` region inside [root] to its bottom.
///
/// Acts only when [force] is set (initial render and history restoration) or
/// when the caller passes a [stickToBottom] intent it captured **before** the
/// DOM mutation. Recomputing the intent afterwards is too late: appended
/// content has already moved the bottom away from the reader's position, so a
/// user who had scrolled up would be yanked back down on every frame.
export function scrollToBottom(root = document, { force = false, stickToBottom = false } = {}) {
  if (!force && !stickToBottom) return;
  const messages = root.querySelector('.messages');
  if (messages) {
    messages.scrollTop = messages.scrollHeight;
  }
}

/// Restart-banner state, shared so the shell controller, the settings save path
/// and an out-of-band slot replacement cannot disagree about dismissal.
///
/// The slot always holds one `#restart-banner` node; these helpers only reveal
/// and re-hide it, never create or remove markup.
let restartBannerDismissed = false;

function setRestartBannerVisible(banner, visible) {
  banner.toggleAttribute('hidden', !visible);
  banner.toggleAttribute('inert', !visible);
}

/// Applies [pendingFields] to the banner.
///
/// An empty list is the cleared state: it blanks the field list, re-hides the
/// node and resets dismissal, so a later independent pending set can surface.
export function reconcileRestartBanner(pendingFields) {
  const banner = document.getElementById('restart-banner');
  const fields = document.getElementById('restart-banner-fields');
  if (!banner || !fields) return;
  const names = (Array.isArray(pendingFields) ? pendingFields : []).filter(Boolean);
  if (!names.length) {
    restartBannerDismissed = false;
    fields.textContent = '';
    setRestartBannerVisible(banner, false);
    return;
  }
  fields.textContent = names.join(', ');
  setRestartBannerVisible(banner, !restartBannerDismissed);
}

export function dismissRestartBanner() {
  restartBannerDismissed = true;
  const banner = document.getElementById('restart-banner');
  if (banner) setRestartBannerVisible(banner, false);
}

/// Re-applies the shared dismissal state after HTMX replaces the slot.
///
/// The replacement is server-rendered and knows nothing about this session's
/// dismissal, so without this a navigation would resurrect a dismissed banner.
export function syncRestartBannerAfterSwap() {
  const banner = document.getElementById('restart-banner');
  const fields = document.getElementById('restart-banner-fields');
  if (!banner || !fields) return;
  const pending = fields.textContent.trim().length > 0;
  if (!pending) restartBannerDismissed = false;
  setRestartBannerVisible(banner, pending && !restartBannerDismissed);
}

export function showBanner(type, message) {
  const banner = document.createElement('div');
  banner.className = 'banner banner-' + sanitizeClassToken(type, 'info');
  banner.innerHTML =
    '<span>' + escapeHtml(message) + '</span>' +
    '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button>';
  const chatArea = document.querySelector('.chat-area');
  if (chatArea) {
    chatArea.prepend(banner);
  }
  banner.querySelector('.dismiss')?.addEventListener('click', () => banner.remove());
}

export function readHtmxErrorMessage(ctx, fallbackMessage = 'Request failed') {
  if (!ctx) return fallbackMessage;
  const contentType = ctx.response?.headers?.get('content-type') || '';
  if (contentType.includes('application/json')) {
    try {
      const parsed = JSON.parse(ctx.text || '{}');
      return parsed.error?.message || fallbackMessage;
    } catch (_) {
      return fallbackMessage;
    }
  }
  return ctx.response?.raw?.statusText || fallbackMessage;
}

export function getApiToken() {
  return new URLSearchParams(window.location.search).get('token');
}

export function openConversationDraftDb() {
  if (!globalThis.indexedDB) return Promise.reject(new Error('IndexedDB unavailable'));
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('dartclaw-conversation-drafts', 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains('drafts')) {
        request.result.createObjectStore('drafts', { keyPath: 'key' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function conversationDraftSessionIds(limit = 200) {
  const db = await openConversationDraftDb();
  return new Promise((resolve, reject) => {
    const request = db.transaction('drafts', 'readonly').objectStore('drafts').getAll();
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const ids = request.result
        .filter((draft) => (draft.text || '').trim() || draft.references?.length || draft.attachments?.length)
        .map((draft) => String(draft.key || '').split(':').slice(1).join(':'))
        .filter((id) => id && id !== 'provisional');
      resolve([...new Set(ids)].slice(0, limit));
    };
  });
}

export function apiQs() {
  const token = getApiToken();
  return token ? '?token=' + encodeURIComponent(token) : '';
}

// Transitional shim: a few migrated controllers still reach for window.dartclaw.ui.* / .shell.*
// helpers. Retire when those call sites move to direct imports from shared.js (planned for 0.17).
export function installCompatibilityNamespace() {
  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = {
    ...(dartclaw.ui || {}),
    escapeHtml,
    initCustomSelects,
    sanitizeClassToken,
    showBanner,
    showToast,
    syncCustomSelect,
  };
  dartclaw.shell = {
    ...(dartclaw.shell || {}),
    apiQs,
    getApiToken,
    renderMarkdown,
    scrollToBottom,
  };
  return dartclaw;
}

installCompatibilityNamespace();
