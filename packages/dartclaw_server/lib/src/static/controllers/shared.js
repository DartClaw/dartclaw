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

export function scrollToBottom(root = document) {
  const messages = root.querySelector('.messages');
  if (messages) {
    messages.scrollTop = messages.scrollHeight;
  }
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
