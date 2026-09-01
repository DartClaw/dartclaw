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
  toast.classList.add('removing');
  toast.addEventListener('animationend', () => toast.remove(), { once: true });
}

export function showToast(type, message) {
  const container = toastContainer();
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + sanitizeClassToken(type, 'info');
  toast.innerHTML =
    '<span>' + escapeHtml(message) + '</span>' +
    '<button class="toast-dismiss" aria-label="Dismiss" data-icon="x"></button>';
  toast.querySelector('.toast-dismiss')?.addEventListener('click', () => removeToast(toast));
  container.appendChild(toast);
  while (container.children.length > TOAST_MAX) {
    removeToast(container.firstElementChild);
  }
  setTimeout(() => removeToast(toast), TOAST_DURATION);
}

export function dispatchToast(type, message) {
  document.body.dispatchEvent(new CustomEvent('dc:toast', { detail: { type, message } }));
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

let activeConfirmDialog = null;

export function confirmDialog({ title, body, confirmLabel = 'Confirm', danger = false } = {}) {
  // Fail closed rather than stack dialogs: a second confirmation raised while one
  // is open would ask about an action the user can no longer see the context for.
  if (activeConfirmDialog) return Promise.resolve(false);

  const dialog = document.createElement('dialog');
  dialog.className = 'dialog dialog--confirm card card-glass';

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

  document.body.appendChild(dialog);
  activeConfirmDialog = dialog;

  return new Promise((resolve) => {
    let confirmed = false;
    // Settle off `close` so Escape, the backdrop and both buttons share one exit,
    // and remove the element first so a caller's toast is not occluded by the
    // top layer this dialog occupies.
    dialog.addEventListener('close', () => {
      dialog.remove();
      activeConfirmDialog = null;
      resolve(confirmed);
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
    dialog.showModal();
    if (danger) cancelButton.focus();
  });
}

export function closeAllCustomSelects(except) {
  document.querySelectorAll('.custom-select[data-open="true"]').forEach((wrapper) => {
    if (except && wrapper === except) return;
    wrapper.dataset.open = 'false';
    wrapper.querySelector('.custom-select-trigger')?.setAttribute('aria-expanded', 'false');
  });
}

export function syncCustomSelect(select) {
  if (!select || typeof select._customSelectSync !== 'function') return;
  select._customSelectSync();
}

function enhanceCustomSelect(select) {
  if (!select || select.dataset.customSelectInit) return;
  select.dataset.customSelectInit = '1';

  const wrapper = document.createElement('div');
  wrapper.className = 'custom-select';
  wrapper.dataset.open = 'false';
  select.parentNode.insertBefore(wrapper, select);
  wrapper.appendChild(select);
  select.classList.add('native-select-hidden');
  select.tabIndex = -1;

  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.className = 'custom-select-trigger';
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');
  const label = document.createElement('span');
  label.className = 'custom-select-label';
  const caret = document.createElement('span');
  caret.className = 'custom-select-caret';
  caret.setAttribute('aria-hidden', 'true');
  trigger.append(label, caret);

  const menu = document.createElement('div');
  menu.className = 'custom-select-menu';
  menu.setAttribute('role', 'listbox');
  wrapper.append(trigger, menu);

  function syncFromSelect() {
    const selectedOption = select.options[select.selectedIndex] || select.options[0];
    label.textContent = selectedOption ? (selectedOption.textContent || selectedOption.label || '') : '';
    menu.querySelectorAll('.custom-select-option').forEach((optionButton) => {
      optionButton.setAttribute('aria-selected', optionButton.dataset.value === select.value ? 'true' : 'false');
    });
  }

  function buildOptions() {
    menu.innerHTML = '';
    Array.from(select.options).forEach((option, index) => {
      const optionButton = document.createElement('button');
      optionButton.type = 'button';
      optionButton.className = 'custom-select-option';
      optionButton.setAttribute('role', 'option');
      optionButton.dataset.value = option.value;
      optionButton.dataset.index = String(index);
      optionButton.disabled = option.disabled;
      optionButton.setAttribute('aria-selected', option.selected ? 'true' : 'false');

      const check = document.createElement('span');
      check.className = 'custom-select-check';
      check.setAttribute('aria-hidden', 'true');
      check.textContent = '✓';
      const text = document.createElement('span');
      text.textContent = option.textContent || option.label || '';
      optionButton.append(check, text);
      optionButton.addEventListener('click', () => {
        if (option.disabled) return;
        select.value = option.value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        syncFromSelect();
        closeAllCustomSelects();
        trigger.focus();
      });
      menu.appendChild(optionButton);
    });
  }

  trigger.addEventListener('click', () => {
    const isOpen = wrapper.dataset.open === 'true';
    closeAllCustomSelects(isOpen ? null : wrapper);
    wrapper.dataset.open = isOpen ? 'false' : 'true';
    trigger.setAttribute('aria-expanded', isOpen ? 'false' : 'true');
  });
  trigger.addEventListener('keydown', (event) => {
    if (event.key !== 'ArrowDown' && event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    closeAllCustomSelects(wrapper);
    wrapper.dataset.open = 'true';
    trigger.setAttribute('aria-expanded', 'true');
    const selected = menu.querySelector('.custom-select-option[aria-selected="true"]') ||
      menu.querySelector('.custom-select-option:not([disabled])');
    selected?.focus();
  });
  menu.addEventListener('keydown', (event) => {
    const options = Array.from(menu.querySelectorAll('.custom-select-option:not([disabled])'));
    const currentIndex = options.indexOf(document.activeElement);
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      (options[Math.min(currentIndex + 1, options.length - 1)] || options[0])?.focus();
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      (options[Math.max(currentIndex - 1, 0)] || options[options.length - 1])?.focus();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      closeAllCustomSelects();
      trigger.focus();
    }
  });

  select.addEventListener('change', syncFromSelect);
  select._customSelectSync = syncFromSelect;
  buildOptions();
  syncFromSelect();
}

export function initCustomSelects(root = document) {
  root.querySelectorAll('select[data-enhance="custom-select"]').forEach(enhanceCustomSelect);
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

export function readHtmxErrorMessage(xhr, fallbackMessage = 'Request failed') {
  if (!xhr) return fallbackMessage;
  const contentType = xhr.getResponseHeader('content-type') || '';
  if (contentType.includes('application/json')) {
    try {
      const parsed = JSON.parse(xhr.responseText || '{}');
      return parsed.error?.message || fallbackMessage;
    } catch (_) {
      return fallbackMessage;
    }
  }
  return xhr.statusText || fallbackMessage;
}

export function getApiToken() {
  return new URLSearchParams(window.location.search).get('token');
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
