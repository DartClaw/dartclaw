import {
  apiQs,
  applyIdenticons,
  closeAllCustomSelects,
  confirmDialog,
  dismissRestartBanner as dismissRestartBannerState,
  getApiToken,
  initCustomSelects,
  isAtBottom,
  queueToast,
  readHtmxErrorMessage,
  reconcileRestartBanner,
  renderMarkdown,
  scrollToBottom,
  showToast,
  syncRestartBannerAfterSwap,
  TOAST_QUEUE_KEY,
} from './shared.js';

const restartPollIntervalMs = 2000;
const restartPollTimeoutMs = 90000;

export default class DcShellController extends Stimulus.Controller {
  connect() {
    this.restartPollTimer = null;
    this.restartPollStart = null;
    this.globalEventSource = null;
    // Sticky-bottom intent captured before the pending mutation, keyed by the
    // scroll container it was measured on. Cleared once consumed so an
    // unrelated later swap cannot inherit it.
    this.stickyIntent = null;

    this.handleServerEvent = this.handleServerEvent.bind(this);
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    this.handleAfterSwap = this.handleAfterSwap.bind(this);
    this.handleBeforeSwap = this.handleBeforeSwap.bind(this);
    this.captureStickyIntent = this.captureStickyIntent.bind(this);
    this.handleDrawerViewportChange = this.handleDrawerViewportChange.bind(this);
    this.handleHtmxConfirm = this.handleHtmxConfirm.bind(this);
    this.handleHistoryRestore = this.handleHistoryRestore.bind(this);
    this.handleHistoryCacheMissLoad = this.handleHistoryCacheMissLoad.bind(this);
    this.handleAfterSettle = this.handleAfterSettle.bind(this);
    this.handleHtmxResponseError = this.handleHtmxResponseError.bind(this);
    this.handleHtmxSendError = this.handleHtmxSendError.bind(this);

    document.body.addEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.addEventListener('htmx:responseError', this.handleHtmxResponseError);
    document.body.addEventListener('htmx:sendError', this.handleHtmxSendError);
    document.addEventListener('click', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKeydown);
    document.body.addEventListener('htmx:afterSwap', this.handleAfterSwap);
    document.body.addEventListener('htmx:beforeSwap', this.handleBeforeSwap);
    document.body.addEventListener('htmx:beforeSwap', this.captureStickyIntent);
    document.body.addEventListener('htmx:confirm', this.handleHtmxConfirm);
    document.body.addEventListener('htmx:historyRestore', this.handleHistoryRestore);
    document.body.addEventListener('htmx:historyCacheMissLoad', this.handleHistoryCacheMissLoad);
    document.addEventListener('htmx:afterSettle', this.handleAfterSettle);
    // The off-canvas drawer only exists below this width.
    this.drawerViewport = window.matchMedia('(max-width: 768px)');
    this.drawerViewport.addEventListener('change', this.handleDrawerViewportChange);

    this.initializeShellUi();
    this.drainQueuedToast();
    // Global SSE (restart / context-warning events) only exists for authenticated
    // shell pages; the login page renders no sidebar and would 401 on /api/events.
    if (document.querySelector('.sidebar')) {
      this.connectGlobalEvents();
    }
    renderMarkdown();
    applyIdenticons();
    scrollToBottom(document, { force: true });
    this.applyTimelineAutoScroll({ force: true });
  }

  disconnect() {
    document.body.removeEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.removeEventListener('htmx:responseError', this.handleHtmxResponseError);
    document.body.removeEventListener('htmx:sendError', this.handleHtmxSendError);
    document.removeEventListener('click', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
    document.body.removeEventListener('htmx:afterSwap', this.handleAfterSwap);
    document.body.removeEventListener('htmx:beforeSwap', this.handleBeforeSwap);
    document.body.removeEventListener('htmx:beforeSwap', this.captureStickyIntent);
    document.body.removeEventListener('htmx:confirm', this.handleHtmxConfirm);
    document.body.removeEventListener('htmx:historyRestore', this.handleHistoryRestore);
    document.body.removeEventListener('htmx:historyCacheMissLoad', this.handleHistoryCacheMissLoad);
    document.removeEventListener('htmx:afterSettle', this.handleAfterSettle);
    this.drawerViewport?.removeEventListener('change', this.handleDrawerViewportChange);
    if (this.globalEventSource) {
      this.globalEventSource.close();
      this.globalEventSource = null;
    }
    if (this.restartPollTimer) {
      clearInterval(this.restartPollTimer);
      this.restartPollTimer = null;
    }
  }

  handleServerEvent(event) {
    const detail = event && event.detail;
    if (!detail) return;
    if (detail.type === 'restart-required') {
      this.showRestartBanner(detail.payload || {});
    }
  }

  handleDocumentClick(event) {
    if (!event.target.closest('.custom-select')) {
      closeAllCustomSelects();
    }
    // One-shot page notices are removed outright; the shell's restart banner is
    // a persistent slot node that client state hides and reveals, so removing it
    // would leave a later pending restart with nothing to surface into.
    if (event.target.matches('.dismiss') && !event.target.closest('#restart-banner-slot')) {
      event.target.closest('.banner')?.remove();
    }

    const auditToggle = event.target.closest('.audit-row-toggle');
    if (auditToggle) {
      this.toggleAuditRow(auditToggle);
      return;
    }

    const createButton = event.target.closest('[data-session-create]');
    if (createButton) {
      event.preventDefault();
      this.createSession();
      return;
    }

    const archiveButton = event.target.closest('[data-session-archive]');
    if (archiveButton) {
      event.preventDefault();
      event.stopPropagation();
      this.archiveSession(archiveButton);
      return;
    }

    const deleteButton = event.target.closest('[data-session-delete]');
    if (deleteButton) {
      event.preventDefault();
      event.stopPropagation();
      this.deleteSession(deleteButton);
      return;
    }

    const resumeButton = event.target.closest('[data-session-resume]');
    if (resumeButton) {
      event.preventDefault();
      this.resumeSession(resumeButton);
    }
  }

  handleDocumentKeydown(event) {
    if (event.key !== 'Escape') return;
    // An open drawer is the innermost dismissible layer, so it wins; otherwise
    // Escape keeps its existing meaning for an open custom select.
    if (document.getElementById('sidebar')?.classList.contains('open')) {
      this.setSidebarOpen(false);
      return;
    }
    closeAllCustomSelects();
  }

  handleAfterSwap(event) {
    const target = event.detail && event.detail.target;
    const source = event.detail && event.detail.elt;
    const isLoadEarlier = source && source.matches && source.matches('[data-load-earlier]');
    renderMarkdown();
    applyIdenticons();
    if (!isLoadEarlier) {
      scrollToBottom(document, { stickToBottom: this.stickyIntent?.messages === true });
    }
    syncRestartBannerAfterSwap();
    this.initializeShellUi();
    this.restoreAuditExpansion();
    if (target && target.id === 'main-content') {
      target.focus({ preventScroll: true });
    }
  }

  // Adapts every `hx-confirm` attribute onto the canonical dialog, so the markup
  // never has to name a confirmation mechanism and future uses convert for free.
  async handleHtmxConfirm(event) {
    // htmx fires this for every request; only those carrying hx-confirm have a question.
    const question = event.detail && event.detail.question;
    if (!question) return;
    event.preventDefault();
    const element = event.detail.elt;
    const confirmed = await confirmDialog({ body: question, danger: true });
    if (!confirmed) return;
    // htmx silently drops requests for detached elements, so an SSE-driven swap
    // during the dialog would otherwise turn a confirmed action into a no-op.
    if (element && !element.isConnected) {
      showToast('error', 'That action is no longer available – the page changed while you were confirming.');
      return;
    }
    event.detail.issueRequest(true);
  }

  handleHistoryRestore() {
    renderMarkdown();
    applyIdenticons();
    scrollToBottom(document, { force: true });
    this.initializeShellUi();
    document.getElementById('main-content')?.focus({ preventScroll: true });
  }

  handleHistoryCacheMissLoad() {
    renderMarkdown();
    applyIdenticons();
    scrollToBottom(document, { force: true });
  }

  initializeShellUi() {
    initCustomSelects(document);
    this.initThemeToggle();
    this.initSidebar();
    this.initInlineRename();
  }

  initThemeToggle() {
    const saved = localStorage.getItem('dartclaw-theme');
    if (saved === 'light') {
      document.documentElement.dataset.theme = 'light';
      const link = document.getElementById('hljs-theme');
      if (link) link.href = new URL('hljs-catppuccin-latte.css', link.href).href;
    }

    const button = document.querySelector('.theme-toggle');
    if (!button || button.dataset.themeInit) return;
    button.dataset.themeInit = '1';
    button.addEventListener('click', () => {
      const html = document.documentElement;
      const next = html.dataset.theme === 'light' ? '' : 'light';
      html.dataset.theme = next;
      localStorage.setItem('dartclaw-theme', next || 'dark');
      const link = document.getElementById('hljs-theme');
      if (link) {
        const stylesheet = next === 'light' ? 'hljs-catppuccin-latte.css' : 'hljs-catppuccin-mocha.css';
        link.href = new URL(stylesheet, link.href).href;
      }
    });
  }

  initSidebar() {
    if (!document.getElementById('sidebar')) return;

    const menuToggle = document.querySelector('.menu-toggle');
    if (menuToggle && !menuToggle.dataset.sidebarInit) {
      menuToggle.dataset.sidebarInit = '1';
      menuToggle.addEventListener('click', () => {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar) return;
        this.setSidebarOpen(!sidebar.classList.contains('open'));
      });
    }

    const scrim = document.querySelector('.sidebar-scrim');
    if (scrim && !scrim.dataset.sidebarInit) {
      scrim.dataset.sidebarInit = '1';
      scrim.addEventListener('click', () => this.setSidebarOpen(false));
    }

    const sidebarClose = document.querySelector('.sidebar-close');
    if (sidebarClose && !sidebarClose.dataset.sidebarInit) {
      sidebarClose.dataset.sidebarInit = '1';
      sidebarClose.addEventListener('click', () => this.setSidebarOpen(false));
    }

    this.initArchiveCollapse();
    this.syncSidebarNavActiveState();
  }

  /// Re-derives the drawer's inert boundary from the DOM.
  ///
  /// Navigating from an open drawer replaces `#sidebar` out-of-band with server
  /// markup that carries no `.open`, so the drawer closes without ever calling
  /// [setSidebarOpen]. Left alone, `.shell-main` stays `inert` with
  /// `.menu-toggle` — the only control that could undo it — inside that
  /// boundary, and the page has no recovery short of a reload.
  ///
  /// Idempotent: [setSidebarOpen] short-circuits before moving focus when the
  /// state is already what it asks for, so the repeat settles per navigation
  /// cost nothing.
  reconcileDrawerState() {
    if (document.getElementById('sidebar')?.classList.contains('open')) return;
    this.setSidebarOpen(false);
  }

  /// Above the drawer breakpoint the rail is permanent and `.menu-toggle` is
  /// hidden, so an "open" drawer carried across a resize would inert the page
  /// with nothing left to close it.
  handleDrawerViewportChange(event) {
    if (!event.matches) this.setSidebarOpen(false);
  }

  setSidebarOpen(open) {
    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;
    const wasOpen = sidebar.classList.contains('open');
    sidebar.classList.toggle('open', open);
    const scrim = document.querySelector('.sidebar-scrim');
    if (scrim) {
      scrim.setAttribute('aria-hidden', String(!open));
      // Pointer-only: the drawer's own close button and Escape are the keyboard
      // paths, so the scrim never becomes a sequential tab stop.
      scrim.tabIndex = -1;
    }
    const menuToggle = document.querySelector('.menu-toggle');
    if (menuToggle) {
      menuToggle.setAttribute('aria-label', open ? 'Close sidebar' : 'Open sidebar');
      menuToggle.setAttribute('aria-expanded', String(open));
      menuToggle.setAttribute('data-icon', open ? 'x' : 'menu');
    }
    // Inert the whole right column rather than a selector list, so a visible
    // restart banner's controls are covered without a second focus trap.
    for (const region of [document.querySelector('.skip-link'), document.querySelector('.shell-main')]) {
      region?.toggleAttribute('inert', open);
    }
    // Only on a real transition: a no-op close (shell re-init, restore) must not
    // yank focus to a control the user never touched.
    if (open === wasOpen) return;
    if (open) {
      document.querySelector('.sidebar-close')?.focus();
    } else {
      menuToggle?.focus();
    }
  }

  initArchiveCollapse() {
    const section = document.querySelector('.sidebar-archive-section');
    if (!section) return;
    const toggle = section.querySelector('.sidebar-archive-toggle');
    const list = section.querySelector('.sidebar-archive-list');
    if (!toggle || !list) return;

    const storageKey = 'dartclaw-sidebar-archived-collapsed';
    const isCollapsed = section.classList.contains('force-expanded')
      ? false
      : localStorage.getItem(storageKey) !== 'false';
    list.hidden = isCollapsed;
    toggle.setAttribute('aria-expanded', String(!isCollapsed));
    section.classList.toggle('expanded', !isCollapsed);

    if (toggle.dataset.archiveInit) return;
    toggle.dataset.archiveInit = '1';
    toggle.addEventListener('click', () => {
      const wasExpanded = section.classList.contains('expanded');
      list.hidden = wasExpanded;
      section.classList.toggle('expanded', !wasExpanded);
      toggle.setAttribute('aria-expanded', String(!wasExpanded));
      localStorage.setItem(storageKey, String(wasExpanded));
    });
  }

  syncSidebarNavActiveState() {
    const currentPath = window.location.pathname.replace(/\/$/, '') || '/';
    if (currentPath === '/' || currentPath.startsWith('/sessions/')) return;
    const links = document.querySelectorAll('.sidebar-nav-item');
    let bestMatchLength = -1;
    const linkPaths = [];
    links.forEach((link) => {
      const linkPath = new URL(link.href, window.location.origin).pathname.replace(/\/$/, '') || '/';
      const matches = linkPath === currentPath || (linkPath !== '/' && currentPath.startsWith(linkPath + '/'));
      linkPaths.push({ link, linkPath, matches });
      if (matches && linkPath.length > bestMatchLength) {
        bestMatchLength = linkPath.length;
      }
    });
    if (bestMatchLength < 0) return;
    linkPaths.forEach(({ link, linkPath, matches }) => {
      link.classList.toggle('active', matches && linkPath.length === bestMatchLength);
    });
  }

  initInlineRename() {
    const input = document.querySelector('.topbar .session-title[type="text"]');
    if (!input || input.dataset.renameInit) return;
    input.dataset.renameInit = '1';
    input.addEventListener('blur', () => this.commitRename(input));
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

  commitRename(input) {
    const newTitle = input.value.trim();
    const original = input.dataset.originalTitle;
    const sessionId = input.dataset.sessionId;
    if (!newTitle || newTitle === original || !sessionId) {
      input.value = original;
      return;
    }

    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) chatArea.dataset.hasTitle = 'true';
        const sidebarItem = document.querySelector(
          '.session-item-link[href*="' + CSS.escape(sessionId) + '"] .session-item-title',
        );
        if (sidebarItem) sidebarItem.textContent = newTitle;
        document.title = newTitle + ' - ' + (document.body.dataset.appName || 'DartClaw');
        showToast('success', 'Session renamed');
      })
      .catch((error) => {
        input.value = original;
        showToast('error', error.message || 'Failed to rename session');
      });
  }

  createSession() {
    fetch('/api/sessions', { method: 'POST' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to create session');
        return response.json();
      })
      .then((data) => {
        window.location.href = '/sessions/' + data.id;
      })
      .catch((error) => showToast('error', error.message || 'Failed to create session'));
  }

  archiveSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    const sidebar = document.getElementById('sidebar');
    const wasSidebarOpen = !!(sidebar && sidebar.classList.contains('open'));
    const activeSessionId = this.currentSessionPathId();
    const headers = activeSessionId ? { 'X-Dartclaw-Active-Session-Id': activeSessionId } : {};
    // Failures are reported by the body-level htmx error listeners; this only
    // restores the sidebar the swap collapsed.
    const request = htmx.ajax('POST', '/api/sessions/' + encodeURIComponent(sessionId) + '/archive', {
      source: button,
      target: '#sidebar',
      swap: 'none',
      headers,
    });
    if (request && typeof request.then === 'function') {
      request.then(() => {
        if (wasSidebarOpen) this.setSidebarOpen(true);
        // Failures are already reported by the body-level listeners; this arm
        // only stops an unhandled rejection.
      }, () => {});
    }
  }

  async deleteSession(button) {
    // Read the dataset before awaiting — the row can be swapped out under us.
    const sessionId = button.dataset.sessionId;
    const sessionTitle = button.dataset.sessionTitle;
    if (!sessionId) return;
    const confirmed = await confirmDialog({
      title: 'Delete chat',
      body: sessionTitle
        ? 'Permanently delete "' + sessionTitle + '" and all its messages?'
        : 'Permanently delete this chat and all its messages?',
      confirmLabel: 'Delete',
      danger: true,
    });
    if (!confirmed) return;
    fetch('/api/sessions/' + encodeURIComponent(sessionId), { method: 'DELETE' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to delete session');
        // Queued, not shown: the navigation below destroys this document.
        queueToast('success', 'Chat deleted');
        window.location.href = '/';
      })
      .catch((error) => showToast('error', error.message || 'Failed to delete session'));
  }

  resumeSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/resume', { method: 'POST' })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to resume session');
        return response.json();
      })
      .then(() => window.location.reload())
      .catch((error) => showToast('error', error.message || 'Failed to resume session'));
  }

  currentSessionPathId() {
    const match = window.location.pathname.match(/^\/sessions\/([^/]+)$/);
    return match ? decodeURIComponent(match[1]) : null;
  }

  drainQueuedToast() {
    let raw = null;
    try {
      raw = sessionStorage.getItem(TOAST_QUEUE_KEY);
      // Cleared in the same read, so a second navigation cannot repeat it.
      sessionStorage.removeItem(TOAST_QUEUE_KEY);
    } catch (_) {
      return;
    }
    if (!raw) return;
    try {
      const queued = JSON.parse(raw);
      if (queued && queued.message) showToast(queued.type || 'success', queued.message);
    } catch (_) {}
  }

  // Sole owner of HTMX failure reporting. Every hx-* site on the page is
  // covered without a template edit, and no call site may add its own pair —
  // two listeners on the same event paint two toasts for one failure.
  handleHtmxResponseError(event) {
    if (!event.detail) return;
    showToast('error', readHtmxErrorMessage(event.detail.xhr, 'Request failed'));
  }

  handleHtmxSendError(event) {
    if (!event.detail) return;
    showToast('error', 'Could not reach the server');
  }

  toggleAuditRow(toggle) {
    const detailRow = document.getElementById(toggle.getAttribute('aria-controls') || '');
    if (!detailRow || !detailRow.classList.contains('audit-detail-row')) return;
    const expand = detailRow.hidden;
    detailRow.hidden = !expand;
    toggle.setAttribute('aria-expanded', String(expand));
    // A collapse is the reader retracting their intent, so the restore key goes
    // with it. Left set, the next swap from anywhere on the page – the status
    // region above refreshes on its own 30s timer – would re-open the row they
    // just closed.
    this.expandedAuditKey = expand ? toggle.dataset.auditKey : null;
  }

  // The audit log has no row id, so an expanded row is tracked by the
  // presentation key the server derives from the fields it renders. Captured
  // before the 30s poll replaces the table and re-applied only if the same key
  // comes back – an entry that dropped out of the page leaves every row closed
  // rather than transferring its expansion to whichever row took its place.
  handleBeforeSwap(event) {
    const target = event.detail && event.detail.target;
    if (!target || target.id !== 'audit-table-container') return;
    const open = target.querySelector('.audit-row-toggle[aria-expanded="true"]');
    this.expandedAuditKey = open ? open.dataset.auditKey : null;
  }

  restoreAuditExpansion() {
    if (!this.expandedAuditKey) return;
    const toggle = document.querySelector(
      '.audit-row-toggle[data-audit-key="' + CSS.escape(this.expandedAuditKey) + '"]',
    );
    if (toggle && toggle.getAttribute('aria-expanded') !== 'true') this.toggleAuditRow(toggle);
  }

  applyTimelineAutoScroll({ force = false, stickToBottom = false } = {}) {
    if (!force && !stickToBottom) return;
    const container = document.querySelector('[data-auto-scroll="true"]');
    if (container) container.scrollTop = container.scrollHeight;
  }

  /// Records, before htmx mutates the DOM, whether each shared scroll region was
  /// at its bottom. Content growth changes that distance, so measuring after the
  /// swap would report the reader's new position rather than their intent.
  captureStickyIntent() {
    this.stickyIntent = {
      messages: isAtBottom(document.querySelector('.messages')),
      timeline: isAtBottom(document.querySelector('[data-auto-scroll="true"]')),
    };
  }

  /// Settle is the last event of a swap cycle, so the timeline follows here and
  /// the captured intent is released here — one clear per mutation, whether or
  /// not an afterSwap handler ran.
  handleAfterSettle() {
    this.applyTimelineAutoScroll({ stickToBottom: this.stickyIntent?.timeline === true });
    this.stickyIntent = null;
    // Settle, not swap: the out-of-band `#sidebar` replacement still carries the
    // old `.open` class at every afterSwap and only loses it once the swap
    // settles, so reconciling any earlier reads a stale open drawer.
    this.reconcileDrawerState();
  }

  connectGlobalEvents() {
    if (this.globalEventSource) return;
    const url = '/api/events' + apiQs();
    this.globalEventSource = new EventSource(url);
    this.globalEventSource.addEventListener('server_restart', () => this.showRestartOverlay());
    this.globalEventSource.addEventListener('context_warning', (event) => this.showContextWarning(event));
    this.globalEventSource.onopen = () => this.setConnectionState('live');
    this.globalEventSource.onerror = () => {
      if (document.getElementById('restart-overlay')) {
        this.startRestartPolling();
        return;
      }
      this.setConnectionState('lost');
    };
  }

  // A live pulse or a sweeping scan-bar is a claim that the view is current.
  // While the event stream is down that claim is false, so the shell records
  // the state, says so in words, and app.css stops the animations that would
  // otherwise keep asserting freshness.
  setConnectionState(state) {
    const shell = document.querySelector('.shell');
    if (shell) shell.dataset.connection = state;

    const existing = document.getElementById('connection-lost-banner');
    if (state !== 'lost') {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    const host = document.getElementById('main-content');
    if (!host) return;
    const banner = document.createElement('div');
    banner.id = 'connection-lost-banner';
    banner.className = 'banner banner-warning';
    banner.setAttribute('role', 'status');
    banner.setAttribute('aria-live', 'polite');
    banner.innerHTML = '<span>Live updates disconnected. Reconnecting…</span>';
    host.prepend(banner);
  }

  showContextWarning(event) {
    try {
      const data = JSON.parse(event.data);
      const currentSessionId = this.currentSessionPathId();
      if (!currentSessionId || data.sessionId !== currentSessionId) return;
      if (document.getElementById('context-warning-banner')) return;
      const banner = document.createElement('div');
      banner.id = 'context-warning-banner';
      banner.className = 'banner banner-warning';
      banner.setAttribute('role', 'status');
      banner.setAttribute('aria-live', 'polite');
      banner.innerHTML =
        '<span>' + String(data.message || 'Context window running low.')
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;') +
        '</span><button class="dismiss" aria-label="Dismiss" data-icon="x"></button>';
      document.querySelector('.chat-area')?.prepend(banner);
    } catch (_) {}
  }

  showRestartBanner(payload) {
    reconcileRestartBanner(Array.isArray(payload.fields) ? payload.fields : []);
  }

  async confirmRestart() {
    const appName = document.body.dataset.appName || 'DartClaw';
    // Restarting is recoverable, so this is the non-destructive confirmation:
    // no glyph, plain confirm button — see DESIGN.md § Feedback.
    const confirmed = await confirmDialog({
      title: 'Restart ' + appName,
      body: 'Restart ' + appName + '? Active turns will complete first.',
      confirmLabel: 'Restart',
    });
    if (!confirmed) return;
    const token = getApiToken();
    fetch('/api/system/restart' + (token ? '?token=' + encodeURIComponent(token) : ''), { method: 'POST' })
      .then((response) => {
        if (response.ok) {
          this.showRestartOverlay();
          return;
        }
        response.json()
          .then((data) => showToast('error', 'Restart failed: ' + (data.error?.message || 'Unknown error')))
          .catch(() => showToast('error', 'Restart failed'));
      })
      .catch(() => showToast('error', 'Failed to reach server'));
  }

  dismissRestartBanner() {
    dismissRestartBannerState();
  }

  showRestartOverlay() {
    if (document.getElementById('restart-overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'restart-overlay';
    overlay.className = 'restart-overlay';
    overlay.setAttribute('role', 'status');
    overlay.setAttribute('aria-live', 'assertive');
    overlay.innerHTML = `
      <div class="restart-overlay-content">
        <div class="claw-loader" aria-label="Server is restarting"><span></span><span></span><span></span></div>
        <h2>Server is restarting...</h2>
        <p id="restart-status">Waiting for server to come back online</p>
      </div>
    `;
    document.body.appendChild(overlay);
    this.startRestartPolling();
  }

  startRestartPolling() {
    if (this.restartPollTimer) return;
    this.restartPollStart = Date.now();
    this.restartPollTimer = setInterval(async () => {
      const elapsed = Date.now() - this.restartPollStart;
      if (elapsed > restartPollTimeoutMs) {
        clearInterval(this.restartPollTimer);
        this.restartPollTimer = null;
        const status = document.getElementById('restart-status');
        if (status) status.textContent = 'Server did not restart within 90s. Please check the server manually.';
        return;
      }
      try {
        const response = await fetch('/health');
        if (response.ok) {
          clearInterval(this.restartPollTimer);
          this.restartPollTimer = null;
          window.location.reload();
        }
      } catch (_) {}
    }, restartPollIntervalMs);
  }
}
