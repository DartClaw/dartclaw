// app.js - DartClaw client-side logic
'use strict';

// Enable View Transitions API for SPA navigation swaps.
htmx.config.globalViewTransitions = true;

let activeSource = null;
let activeStreamUrl = null;
let reconnectAttempts = 0;
let reconnectTimer = null;

// === Toast notifications ===

const TOAST_DURATION = 4000;
const TOAST_MAX = 5;

function getOrCreateToastContainer() {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.className = 'toast-container';
    document.body.appendChild(container);
  }
  return container;
}

function showToast(type, message) {
  const container = getOrCreateToastContainer();
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + type;

  const safeMessage = String(message)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  toast.innerHTML =
    '<span>' + safeMessage + '</span>' +
    '<button class="toast-dismiss" aria-label="Dismiss">&times;</button>';

  toast.querySelector('.toast-dismiss').addEventListener('click', () => removeToast(toast));

  container.appendChild(toast);

  // Enforce max visible — remove oldest first
  while (container.children.length > TOAST_MAX) {
    removeToast(container.firstElementChild);
  }

  setTimeout(() => removeToast(toast), TOAST_DURATION);
}

function removeToast(toast) {
  if (!toast || !toast.parentNode) return;
  if (toast.classList.contains('removing')) return;

  toast.classList.add('removing');
  toast.addEventListener('animationend', () => toast.remove(), { once: true });
}

// === Theme toggle ===

(function restoreTheme() {
  const saved = localStorage.getItem('dartclaw-theme');
  if (saved === 'light') {
    document.documentElement.dataset.theme = 'light';
    const link = document.getElementById('hljs-theme');
    if (link) link.href = '/static/hljs-catppuccin-latte.css';
  }
})();

function applyHljsTheme(isLight) {
  const link = document.getElementById('hljs-theme');
  if (link) {
    link.href = isLight ? '/static/hljs-catppuccin-latte.css' : '/static/hljs-catppuccin-mocha.css';
  }
}

function initThemeToggle() {
  const btn = document.querySelector('.theme-toggle');
  if (!btn) return;

  btn.addEventListener('click', () => {
    const html = document.documentElement;
    const next = html.dataset.theme === 'light' ? '' : 'light';
    html.dataset.theme = next;
    localStorage.setItem('dartclaw-theme', next || 'dark');
    applyHljsTheme(next === 'light');
  });
}

// === Sidebar toggle ===

function setSidebarOpen(open) {
  const sidebar = document.getElementById('sidebar');
  const backdrop = document.getElementById('sidebar-backdrop');
  if (!sidebar) return;
  sidebar.classList.toggle('open', open);
  if (backdrop) backdrop.classList.toggle('open', open);
}

function initSidebar() {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;

  const menuToggle = document.querySelector('.menu-toggle');
  if (menuToggle) {
    menuToggle.addEventListener('click', () => setSidebarOpen(!sidebar.classList.contains('open')));
  }

  const closeBtn = document.querySelector('.sidebar-close');
  if (closeBtn) {
    closeBtn.addEventListener('click', () => setSidebarOpen(false));
  }

  // Click outside (overlay/backdrop) closes sidebar on mobile.
  document.addEventListener('click', (event) => {
    if (
      sidebar.classList.contains('open') &&
      !sidebar.contains(event.target) &&
      !event.target.closest('.menu-toggle')
    ) {
      setSidebarOpen(false);
    }
  });
}

// === Textarea auto-resize ===

function initTextareaResize() {
  const textarea = document.getElementById('message-input');
  if (!textarea) return;

  textarea.addEventListener('input', () => {
    textarea.style.height = 'auto';
    textarea.style.height = textarea.scrollHeight + 'px';
  });
}

// === Ctrl+Enter / Cmd+Enter submit ===

function initKeyboardSubmit() {
  const textarea = document.getElementById('message-input');
  const form = document.getElementById('chat-form');
  if (!textarea || !form) return;

  textarea.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    }
  });
}

// === Markdown rendering pipeline ===

function renderMarkdown() {
  if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') return;
  document.querySelectorAll('[data-markdown]').forEach((el) => {
    const raw = marked.parse(el.textContent);
    const clean = DOMPurify.sanitize(raw);
    el.innerHTML = clean;
    if (typeof hljs !== 'undefined') {
      el.querySelectorAll('code').forEach((block) => hljs.highlightElement(block));
    }
    el.removeAttribute('data-markdown');
  });
}

// === Auto-scroll ===

function scrollToBottom() {
  const messages = document.querySelector('.messages');
  if (messages) {
    messages.scrollTop = messages.scrollHeight;
  }
}

// === Input state management ===

function disableInput() {
  const input = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');

  if (input) {
    input.disabled = true;
    input.placeholder = 'Agent is responding...';
  }
  if (btn) {
    btn.disabled = true;
  }
}

function enableInput() {
  const input = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');

  if (input) {
    input.disabled = false;
    input.placeholder = 'Type a message...';
  }
  if (btn) {
    btn.disabled = !input || !input.value.trim();
  }
}

// === Send button state (disable when textarea empty) ===

function initSendButtonState() {
  const textarea = document.getElementById('message-input');
  const btn = document.getElementById('send-btn');
  if (!textarea || !btn) return;

  function updateSendState() {
    btn.disabled = !textarea.value.trim();
  }

  textarea.addEventListener('input', updateSendState);
  updateSendState(); // set initial state (textarea is empty on load)
}

// === Error banner ===

function showBanner(type, message) {
  const banner = document.createElement('div');
  const safeMessage = String(message)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  banner.className = 'banner banner-' + type;
  banner.innerHTML =
    '<span>' + safeMessage + '</span>' +
    '<button class="dismiss" aria-label="Dismiss">&#10005;</button>';

  const chatArea = document.querySelector('.chat-area');
  if (chatArea) {
    chatArea.prepend(banner);
  }

  const dismiss = banner.querySelector('.dismiss');
  if (dismiss) {
    dismiss.addEventListener('click', () => banner.remove());
  }
}

// === Banner dismiss (delegated, for server-rendered banners) ===

document.addEventListener('click', (event) => {
  if (event.target.matches('.dismiss')) {
    const banner = event.target.closest('.banner');
    if (banner) {
      banner.remove();
    }
  }
});

function isChatFormRequest(event) {
  return event.detail && event.detail.elt && event.detail.elt.id === 'chat-form';
}

function extractResponseMessage(xhr) {
  if (!xhr) return 'Request failed';

  const contentType = xhr.getResponseHeader('content-type') || '';
  if (contentType.includes('application/json')) {
    try {
      const parsed = JSON.parse(xhr.responseText || '{}');
      const error = parsed.error || {};
      return error.message || 'Request failed';
    } catch (_) {
      return 'Request failed';
    }
  }

  return xhr.statusText || 'Request failed';
}

// === HTMX request lifecycle ===

function initHtmxRequestLifecycle() {
  document.body.addEventListener('htmx:beforeRequest', (event) => {
    if (!isChatFormRequest(event)) return;
    disableInput();
  });

  document.body.addEventListener('htmx:afterRequest', (event) => {
    if (!isChatFormRequest(event)) return;

    if (event.detail.successful) {
      return;
    }

    closeActiveStream();
    enableInput();
    showBanner('error', extractResponseMessage(event.detail.xhr));
  });
}

function closeActiveStream() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (activeSource) {
    activeSource.close();
    activeSource = null;
    activeStreamUrl = null;
  }
  document.body.classList.remove('streaming');
}

function scheduleReconnect(url) {
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000);
  reconnectAttempts++;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    // Guard: only reconnect if URL still matches (prevents stale reconnects after session switch)
    if (activeStreamUrl !== url && activeStreamUrl !== null) return;
    startStream(url);
  }, delay);
}

function parseSsePayload(event) {
  if (!event || typeof event.data !== 'string') return null;

  try {
    return JSON.parse(event.data);
  } catch (_) {
    return null;
  }
}

function loadMessages(sessionId) {
  return htmx.ajax('GET', '/sessions/' + sessionId + '/messages-html', {
    target: '#messages',
    swap: 'innerHTML',
  });
}

function startStream(url) {
  if (!url) return;
  if (activeSource && activeStreamUrl === url) return;

  closeActiveStream();

  const source = new EventSource(url);
  activeSource = source;
  activeStreamUrl = url;
  document.body.classList.add('streaming');

  source.addEventListener('delta', (event) => {
    reconnectAttempts = 0;
    // Dismiss reconnect banner if present
    const reconnectBanner = document.querySelector('.banner-warning');
    if (reconnectBanner && reconnectBanner.textContent.includes('Reconnecting')) {
      reconnectBanner.remove();
    }

    const data = parseSsePayload(event) || {};
    const el = document.getElementById('streaming-content');
    if (!el) return;

    el.appendChild(document.createTextNode(data.text || ''));
    scrollToBottom();
  });

  source.addEventListener('tool_use', (event) => {
    const data = parseSsePayload(event) || {};
    const el = document.getElementById('streaming-content');
    if (!el) return;

    const indicator = document.createElement('div');
    indicator.className = 'tool-indicator pending';
    indicator.dataset.toolId = data.tool_id || '';
    indicator.textContent = data.tool_name || 'Tool';
    el.appendChild(indicator);
    scrollToBottom();
  });

  source.addEventListener('tool_result', (event) => {
    const data = parseSsePayload(event) || {};
    if (!data.tool_id) return;

    const indicator = document.querySelector(
      '.tool-indicator[data-tool-id="' + CSS.escape(data.tool_id) + '"]',
    );

    if (!indicator) return;
    indicator.classList.remove('pending');
    indicator.classList.add(data.is_error ? 'error' : 'success');
  });

  source.addEventListener('done', () => {
    closeActiveStream();

    const content = document.getElementById('streaming-content');
    if (content) {
      content.classList.remove('streaming');
    }

    // Clear and reset textarea after successful stream completion.
    const textarea = document.getElementById('message-input');
    if (textarea) {
      textarea.value = '';
      textarea.style.height = 'auto';
    }

    enableInput();

    const chatArea = document.querySelector('.chat-area');
    const sessionId = chatArea && chatArea.dataset.sessionId;
    if (!sessionId) return;

    loadMessages(sessionId)
      .then(() => {
        renderMarkdown();
        scrollToBottom();

        // Auto-title untitled sessions from first user message
        if (chatArea && chatArea.dataset.hasTitle !== 'true') {
          const firstUserMsg = document.querySelector('#messages .msg-user .msg-content');
          if (firstUserMsg) {
            let title = (firstUserMsg.textContent || '').trim();
            if (title.length > 50) {
              title = title.substring(0, 50).replace(/\s+\S*$/, '');
            }
            if (title) {
              fetch('/api/sessions/' + encodeURIComponent(sessionId), {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ title: title }),
              })
                .then((res) => {
                  if (!res.ok) return;
                  chatArea.dataset.hasTitle = 'true';
                  // Update topbar input
                  const titleInput = document.querySelector('.topbar .session-title[type="text"]');
                  if (titleInput) {
                    titleInput.value = title;
                    titleInput.dataset.originalTitle = title;
                  }
                  // Update sidebar item
                  const sidebarItem = document.querySelector('.session-item.active .session-item-title');
                  if (sidebarItem) sidebarItem.textContent = title;
                })
                .catch(() => {}); // silent fail for auto-title
            }
          }
        }
      })
      .catch(() => {
        showToast('error', 'Failed to refresh messages');
      });
  });

  source.addEventListener('error', (event) => {
    if (typeof event.data !== 'string') {
      // Network error — no payload. Reconnect.
      const url = activeStreamUrl;
      closeActiveStream();
      if (url) {
        showBanner('warning', 'Connection lost. Reconnecting...');
        scheduleReconnect(url);
      }
      return;
    }

    // Server-sent error event with payload
    const payload = parseSsePayload(event) || {};
    const message = payload.message || payload.error || 'Stream error';
    closeActiveStream();
    enableInput();
    showBanner('error', message);
  });
}

// === Session CRUD ===

function initSessionCreate() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="create-session"]');
    if (!btn) return;
    event.preventDefault();

    fetch('/api/sessions', { method: 'POST' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to create session');
        return res.json();
      })
      .then((data) => {
        window.location.href = '/sessions/' + data.id;
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to create session');
      });
  });
}

function initSessionDelete() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="delete-session"]');
    if (!btn) return;
    event.preventDefault();
    event.stopPropagation(); // prevent <a> navigation on sidebar items

    const sessionId = btn.dataset.sessionId;
    if (!sessionId) return;

    if (!confirm('Delete this session and all its messages?')) return;

    fetch('/api/sessions/' + encodeURIComponent(sessionId), { method: 'DELETE' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to delete session');
        window.location.href = '/';
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to delete session');
      });
  });
}

function initResumeArchive() {
  document.addEventListener('click', (event) => {
    const btn = event.target.closest('[data-action="resume-archive"]');
    if (!btn) return;
    event.preventDefault();

    const sessionId = btn.dataset.sessionId;
    if (!sessionId) return;

    fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/resume', { method: 'POST' })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to resume session');
        return res.json();
      })
      .then(() => {
        window.location.reload();
      })
      .catch((err) => {
        showToast('error', err.message || 'Failed to resume session');
      });
  });
}

// === Inline rename ===

function initInlineRename() {
  const input = document.querySelector('.topbar .session-title[type="text"]');
  if (!input) return;

  function commitRename() {
    const newTitle = input.value.trim();
    const original = input.dataset.originalTitle;
    const sessionId = input.dataset.sessionId;

    if (!newTitle || newTitle === original) {
      input.value = original;
      return;
    }

    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((res) => {
        if (!res.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) {
          // Manual rename means this session now has a user-defined title.
          chatArea.dataset.hasTitle = 'true';
        }
        // Update sidebar item text and browser tab title
        const sidebarItem = document.querySelector(
          '.session-item-link[href*="' + CSS.escape(sessionId) + '"] .session-item-title',
        );
        if (sidebarItem) sidebarItem.textContent = newTitle;
        document.title = newTitle + ' - DartClaw';
        showToast('success', 'Session renamed');
      })
      .catch((err) => {
        input.value = original;
        showToast('error', err.message || 'Failed to rename session');
      });
  }

  input.addEventListener('blur', commitRename);

  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      input.blur();
    } else if (event.key === 'Escape') {
      input.value = input.dataset.originalTitle;
      input.blur();
    }
  });
}

// === SSE streaming startup (scoped to #sse-container swaps) ===

function initSseConnectorHandling() {
  document.body.addEventListener('htmx:afterSwap', (event) => {
    const target = event.detail && event.detail.target;
    if (!target || target.id !== 'sse-container') return;

    const connector = target.querySelector('#sse-connector');
    if (!connector) {
      closeActiveStream();
      return;
    }

    const url = connector.dataset.sseUrl;
    if (!url) {
      closeActiveStream();
      enableInput();
      showBanner('error', 'Streaming URL missing');
      return;
    }

    startStream(url);
  });

  window.addEventListener('beforeunload', () => {
    closeActiveStream();
  });
}

// === SPA content re-initialization after HTMX swap ===

function initAfterSwapReinit() {
  document.body.addEventListener('htmx:afterSwap', (event) => {
    const target = event.detail && event.detail.target;
    // Skip SSE container swaps — handled by initSseConnectorHandling.
    if (target && target.id === 'sse-container') return;

    renderMarkdown();
    scrollToBottom();
    initThemeToggle();
    initSidebar();
    initTextareaResize();
    initKeyboardSubmit();
    initSendButtonState();
    initInlineRename();
  });
}

// === HTMX history restore re-init ===

function initHistoryRestore() {
  document.body.addEventListener('htmx:historyCacheMissLoad', () => {
    renderMarkdown();
    scrollToBottom();
  });

  document.body.addEventListener('htmx:historyRestore', () => {
    renderMarkdown();
    scrollToBottom();
    initThemeToggle();
    initSidebar();
    initTextareaResize();
    initKeyboardSubmit();
    initSendButtonState();
    initInlineRename();
  });
}

// === Init ===

document.addEventListener('DOMContentLoaded', () => {
  initThemeToggle();
  initSidebar();
  initTextareaResize();
  initKeyboardSubmit();
  initSendButtonState();
  initHtmxRequestLifecycle();
  initSseConnectorHandling();
  initAfterSwapReinit();
  initHistoryRestore();
  initSessionCreate();
  initSessionDelete();
  initResumeArchive();
  initInlineRename();
  renderMarkdown();
  scrollToBottom();
});
