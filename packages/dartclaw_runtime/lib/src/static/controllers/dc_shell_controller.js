import {
  apiQs,
  applyIdenticons,
  beginSessionDraftMutation,
  closeAllCustomSelects,
  conversationDraftSessionIds,
  confirmDialog,
  dismissRestartBanner as dismissRestartBannerState,
  endSessionDraftMutation,
  getApiToken,
  initCustomSelects,
  isAtBottom,
  queueToast,
  readHtmxErrorMessage,
  reconcileRestartBanner,
  renderMarkdown,
  scrollToBottom,
  showToast,
  syncSidebarSessionTitle,
  syncRestartBannerAfterSwap,
  TOAST_QUEUE_KEY,
} from './shared.js';

const restartPollIntervalMs = 2000;
const restartPollTimeoutMs = 90000;
const sidebarWidthKey = 'dartclaw-sidebar-width';
const railCollapsedKey = 'dartclaw-rail-collapsed';
const sidebarDefaultWidth = 280;
const sidebarMinWidth = 240;
const sidebarMaxWidth = 420;

// Rail view options. Filter and grouping are per-device presentation over the
// server's recency order — neither is sent to /api/inbox and neither reorders
// anything stored.
const inboxViewKey = 'dartclaw-inbox-view';
const inboxFilters = {
  all: 'All',
  unread: 'Unread',
  waiting: 'Waiting on you',
  running: 'Running',
  failed: 'Failed',
  drafts: 'Drafts on this device',
};
const inboxGroups = { none: 'None', project: 'Project', status: 'Status' };
const statusGroupOrder = ['waiting', 'running', 'failed', 'unread', 'done'];
const statusGroupLabels = {
  waiting: 'Waiting on you',
  running: 'Running',
  failed: 'Failed',
  unread: 'Unread',
  done: 'Everything else',
};

/// A 14px rail identicon holds one glyph. The shared two-letter form is for
/// surfaces where the label is absent; here the project name sits right beside
/// it, so a second letter only crowds the square.
function railInitial(value) {
  return Array.from(String(value ?? '')).find((char) => /[\p{L}\p{N}]/u.test(char)) || '·';
}

/// One rule for a conversation with no project, shared by the rows, the group
/// headers and (server-side) the topbar crumb: a muted "No project" label and a
/// neutral identicon rather than an empty cell that leaves line 1 looking broken.
const noProjectLabel = 'No project';

export default class DcShellController extends Stimulus.Controller {
  connect() {
    this.restartPollTimer = null;
    this.restartPollStart = null;
    this.globalEventSource = null;
    this.inboxMarkupRefresh = null;
    this.handleServerEvent = this.handleServerEvent.bind(this);
    this.handleDocumentClick = this.handleDocumentClick.bind(this);
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this);
    this.handleAfterSwap = this.handleAfterSwap.bind(this);
    this.handleBeforeSwap = this.handleBeforeSwap.bind(this);
    this.captureStickyIntent = this.captureStickyIntent.bind(this);
    this.handleDrawerViewportChange = this.handleDrawerViewportChange.bind(this);
    this.handleHtmxConfirm = this.handleHtmxConfirm.bind(this);
    this.handleHtmxResponseError = this.handleHtmxResponseError.bind(this);
    this.handleHtmxError = this.handleHtmxError.bind(this);
    this.handleAuthorizationRevoked = this.handleAuthorizationRevoked.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);
    this.handleInboxSelectChange = this.handleInboxSelectChange.bind(this);

    document.addEventListener('change', this.handleInboxSelectChange);
    document.body.addEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.addEventListener('dartclaw:authorization-revoked', this.handleAuthorizationRevoked);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    document.body.addEventListener('htmx:response:error', this.handleHtmxResponseError);
    document.body.addEventListener('htmx:error', this.handleHtmxError);
    document.addEventListener('click', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKeydown);
    document.body.addEventListener('htmx:after:swap', this.handleAfterSwap);
    document.body.addEventListener('htmx:before:swap', this.handleBeforeSwap);
    document.body.addEventListener('htmx:before:swap', this.captureStickyIntent);
    document.body.addEventListener('htmx:confirm', this.handleHtmxConfirm);
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
    document.removeEventListener('change', this.handleInboxSelectChange);
    document.body.removeEventListener('dartclaw:server-event', this.handleServerEvent);
    document.body.removeEventListener('dartclaw:authorization-revoked', this.handleAuthorizationRevoked);
    document.body.removeEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    document.body.removeEventListener('htmx:response:error', this.handleHtmxResponseError);
    document.body.removeEventListener('htmx:error', this.handleHtmxError);
    document.removeEventListener('click', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKeydown);
    document.body.removeEventListener('htmx:after:swap', this.handleAfterSwap);
    document.body.removeEventListener('htmx:before:swap', this.handleBeforeSwap);
    document.body.removeEventListener('htmx:before:swap', this.captureStickyIntent);
    document.body.removeEventListener('htmx:confirm', this.handleHtmxConfirm);
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

  handleAuthorizationRevoked() {
    if (this.globalEventSource) {
      this.globalEventSource.close();
      this.globalEventSource = null;
    }
    this.setConnectionState('lost');
  }

  handleConversationChanged() {
    this.refreshInboxUi();
    this.refreshAttentionUi();
  }

  handleDocumentClick(event) {
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

    const settleButton = event.target.closest('[data-inbox-settle]');
    if (settleButton) {
      event.preventDefault();
      this.settleInboxRows([settleButton.closest('[data-inbox-session-id]')]);
      return;
    }

    if (event.target.closest('[data-inbox-settle-selected]')) {
      event.preventDefault();
      this.settleInboxRows([...document.querySelectorAll('[data-inbox-select]:checked')].map((input) => input.closest('[data-inbox-session-id]')));
      return;
    }

    if (event.target.closest('[data-next-attention]')) {
      event.preventDefault();
      if (this.nextAttentionSessionId) {
        location.assign('/sessions/' + encodeURIComponent(this.nextAttentionSessionId) + apiQs());
      }
      return;
    }

    if (event.target.closest('[data-inbox-clear-filter]')) {
      event.preventDefault();
      this.setInboxView({ filter: 'all', scope: '' });
      return;
    }

    if (event.target.closest('[data-rail-collapse]')) {
      event.preventDefault();
      this.setRailCollapsed(true);
      return;
    }

    const filterItem = event.target.closest('[data-inbox-filter]');
    if (filterItem) {
      event.preventDefault();
      this.setInboxView({ filter: filterItem.dataset.inboxFilter });
      this.closeShellPopovers();
      return;
    }

    const groupItem = event.target.closest('[data-inbox-group]');
    if (groupItem) {
      event.preventDefault();
      this.setInboxView({ group: groupItem.dataset.inboxGroup });
      this.closeShellPopovers();
      return;
    }

    const scopeOption = event.target.closest('[data-inbox-scope-option]');
    if (scopeOption) {
      event.preventDefault();
      this.setInboxView({ scope: scopeOption.dataset.inboxScopeOption });
      this.closeShellPopovers();
      return;
    }

    const groupToggle = event.target.closest('[data-inbox-group-toggle]');
    if (groupToggle) {
      event.preventDefault();
      const key = groupToggle.dataset.inboxGroupToggle;
      if (this.collapsedGroups.has(key)) this.collapsedGroups.delete(key);
      else this.collapsedGroups.add(key);
      this.applyInboxView();
      return;
    }

    if (event.target.closest('[data-inbox-select-toggle]')) {
      event.preventDefault();
      this.setSelectMode(!this.loadInboxView().selectMode);
      this.closeShellPopovers();
      return;
    }

    if (event.target.closest('[data-inbox-clear-selection]')) {
      event.preventDefault();
      this.setSelectMode(false);
      return;
    }

    const popToggle = event.target.closest('[data-inbox-view],[data-inbox-scope],[data-topbar-overflow],[data-attention-toggle]');
    if (popToggle) {
      event.preventDefault();
      // A click synthesised by Enter/Space on a button reports detail 0; a real
      // pointer press reports 1 or more. That is the only signal distinguishing
      // the two here, since both arrive as `click`.
      this.toggleShellPopover(popToggle, { keyboard: event.detail === 0 });
      return;
    }

    // The chat controller owns these surfaces and lives outside the topbar, so
    // the menu asks it rather than reimplementing any of them.
    const chatAction = event.target.closest('[data-chat-action]');
    if (chatAction) {
      event.preventDefault();
      this.closeShellPopovers();
      document.getElementById('main-content')?.dispatchEvent(
        new CustomEvent('dartclaw:chat-action', {
          bubbles: true,
          detail: { action: chatAction.dataset.chatAction },
        }),
      );
      return;
    }

    if (event.target.closest('[data-attention-read-all]')) {
      event.preventDefault();
      this.markVisibleAttentionRead();
      return;
    }

    // Any click that reached here and landed outside an open popover dismisses
    // it; a click inside one is the menu doing its job.
    if (!event.target.closest('.pop')) this.closeShellPopovers();

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
      return;
    }

    const resetButton = event.target.closest('[data-session-reset]');
    if (resetButton) {
      event.preventDefault();
      this.resetSession(resetButton);
    }
  }

  handleDocumentKeydown(event) {
    const sidebar = document.getElementById('sidebar');
    if (event.key === 'Tab' && sidebar?.classList.contains('open')) {
      const focusable = [...sidebar.querySelectorAll(
        'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])',
      )].filter((element) => !element.hidden && element.offsetParent !== null);
      const first = focusable[0];
      const last = focusable.at(-1);
      if (first && last && ((event.shiftKey && document.activeElement === first) ||
          (!event.shiftKey && document.activeElement === last))) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
      }
      return;
    }
    if (event.key !== 'Escape') return;
    // Innermost dismissible layer wins: an open popover, then the drawer, then
    // select mode, and Escape otherwise keeps its meaning for a custom select.
    if (document.querySelector('.pop:not([hidden])')) {
      this.closeShellPopovers();
      return;
    }
    if (sidebar?.classList.contains('open')) {
      this.setSidebarOpen(false);
      return;
    }
    if (this.loadInboxView().selectMode) {
      this.setSelectMode(false);
      return;
    }
    closeAllCustomSelects();
  }

  handleInboxSelectChange(event) {
    if (!event.target.matches?.('[data-inbox-select]')) return;
    this.syncBulkBar();
  }

  handleAfterSwap(event) {
    const ctx = event.detail?.ctx;
    const target = ctx?.target;
    const source = ctx?.sourceElement;
    const isLoadEarlier = source && source.matches && source.matches('[data-load-earlier]');
    const isHistoryRestore = ctx?.request?.headers?.['HX-History-Restore-Request'] === 'true';
    const stickyIntent = ctx?.dartclawStickyIntent;
    renderMarkdown();
    applyIdenticons();
    if (isHistoryRestore) {
      scrollToBottom(document, { force: true });
    } else if (!isLoadEarlier) {
      scrollToBottom(document, { stickToBottom: stickyIntent?.messages === true });
    }
    syncRestartBannerAfterSwap();
    this.initializeShellUi();
    this.restoreAuditExpansion();
    this.applyTimelineAutoScroll({ stickToBottom: stickyIntent?.timeline === true });
    this.reconcileDrawerState();
    const liveTarget = target?.isConnected ? target : (target?.id ? document.getElementById(target.id) : null);
    const focusTarget = liveTarget?.id === 'main-content'
      ? liveTarget
      : (liveTarget?.matches?.('[hx-history-elt]') ? document.getElementById('main-content') : null);
    if (focusTarget) {
      focusTarget.focus({ preventScroll: true });
    }
  }


  // Adapts every `hx-confirm` attribute onto the canonical dialog, so the markup
  // never has to name a confirmation mechanism and future uses convert for free.
  async handleHtmxConfirm(event) {
    const question = event.detail?.ctx?.confirm;
    if (!question) return;
    event.preventDefault();
    const element = event.detail.ctx.sourceElement;
    const confirmed = await confirmDialog({ body: question, danger: true });
    if (!confirmed) {
      event.detail.dropRequest();
      return;
    }
    // htmx silently drops requests for detached elements, so an SSE-driven swap
    // during the dialog would otherwise turn a confirmed action into a no-op.
    if (element && !element.isConnected) {
      showToast('error', 'That action is no longer available – the page changed while you were confirming.');
      event.detail.dropRequest();
      return;
    }
    event.detail.issueRequest();
  }

  initializeShellUi() {
    initCustomSelects(document);
    this.initThemeToggle();
    this.initRailCollapse();
    this.initSidebar();
    this.initSidebarResize();
    this.initInboxUi();
    this.setSelectMode(this.loadInboxView().selectMode);
    this.initAttentionUi();
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
        // Above the drawer breakpoint the toggle is only visible while the rail
        // is collapsed, and its whole job there is to bring the rail back.
        if (document.documentElement.dataset.railCollapsed === 'true') {
          this.setRailCollapsed(false);
          return;
        }
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

  initSidebarResize() {
    const handle = document.querySelector('.sidebar-resize-handle');
    if (!handle || handle.dataset.resizeInit) return;
    handle.dataset.resizeInit = '1';
    const stored = Number.parseInt(localStorage.getItem(sidebarWidthKey) || '', 10);
    this.applySidebarWidth(Number.isFinite(stored) ? stored : sidebarDefaultWidth, false);
    // Pointer capture, so a drag that outruns the 6px handle keeps delivering
    // moves instead of stalling the moment the cursor leaves it.
    handle.addEventListener('pointerdown', (event) => {
      // preventDefault stops the drag from selecting text, and it also cancels
      // the focus the press would have given the handle — so focus is moved
      // explicitly, or arrow-key resize is unreachable after a drag.
      event.preventDefault();
      handle.focus();
      handle.setPointerCapture(event.pointerId);
      handle.dataset.dragging = '';
    });
    handle.addEventListener('pointermove', (event) => {
      if (!('dragging' in handle.dataset)) return;
      this.applySidebarWidth(event.clientX, true);
    });
    handle.addEventListener('pointerup', (event) => {
      delete handle.dataset.dragging;
      handle.releasePointerCapture(event.pointerId);
    });
    handle.addEventListener('dblclick', () => this.applySidebarWidth(sidebarDefaultWidth, true));
    handle.addEventListener('keydown', (event) => {
      const current = Number.parseInt(handle.getAttribute('aria-valuenow') || String(sidebarDefaultWidth), 10);
      const step = event.shiftKey ? 16 : 8;
      let next = current;
      if (event.key === 'ArrowLeft') next -= step;
      else if (event.key === 'ArrowRight') next += step;
      else if (event.key === 'Home') next = sidebarDefaultWidth;
      else return;
      event.preventDefault();
      this.applySidebarWidth(next, true);
    });
  }

  applySidebarWidth(value, persist) {
    const width = Math.max(sidebarMinWidth, Math.min(sidebarMaxWidth, Math.round(value)));
    document.documentElement.style.setProperty('--sidebar-w', width + 'px');
    const handle = document.querySelector('.sidebar-resize-handle');
    if (handle) handle.setAttribute('aria-valuenow', String(width));
    if (persist) localStorage.setItem(sidebarWidthKey, String(width));
  }

  /// Desktop-only: hands the rail's width back and lets the topbar menu toggle —
  /// which canon hides above the drawer breakpoint — bring it back.
  setRailCollapsed(collapsed) {
    document.documentElement.dataset.railCollapsed = String(collapsed);
    localStorage.setItem(railCollapsedKey, String(collapsed));
  }

  initRailCollapse() {
    if (localStorage.getItem(railCollapsedKey) === 'true') {
      document.documentElement.dataset.railCollapsed = 'true';
    }
  }

  async localDraftSessionIds() {
    if (!globalThis.indexedDB) return [];
    try {
      return await conversationDraftSessionIds();
    } catch (_) {
      return [];
    }
  }

  loadInboxView() {
    if (this.inboxView) return this.inboxView;
    let stored = null;
    try {
      stored = JSON.parse(localStorage.getItem(inboxViewKey) || 'null');
    } catch (_) {}
    this.inboxView = {
      filter: inboxFilters[stored?.filter] ? stored.filter : 'all',
      group: inboxGroups[stored?.group] ? stored.group : 'none',
      scope: typeof stored?.scope === 'string' ? stored.scope : '',
      // Select mode is a gesture, not a preference: it must not survive a reload
      // with a stale selection behind it.
      selectMode: false,
    };
    this.collapsedGroups = new Set();
    return this.inboxView;
  }

  persistInboxView() {
    const { filter, group, scope } = this.inboxView;
    try {
      localStorage.setItem(inboxViewKey, JSON.stringify({ filter, group, scope }));
    } catch (_) {}
  }

  /// Navigation replaces `#sidebar` out of band, so the freshly swapped rail is
  /// unpainted — but the projection it needs is already on this controller,
  /// which outlives the swap. Re-paint from it; only a controller that has never
  /// held a page fetches one.
  initInboxUi() {
    this.loadInboxView();
    if (!document.querySelector('[data-inbox-list]')) return;
    if (!this.inboxEntries) {
      this.refreshInboxUi();
      return;
    }
    for (const entry of this.inboxEntries) {
      const row = document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]');
      if (row) this.paintInboxRow(row, entry);
    }
    this.applyInboxView();
  }

  async refreshInboxUi(nextSettledPage = false) {
    if (!document.querySelector('[data-inbox-list]')) return;
    // Paging the settled tail is a distinct request and never shares a flight.
    if (nextSettledPage) return this.loadInboxPage(true);
    // Navigation emits `conversation_changed` for the conversation left and the
    // one opened; both land inside one round trip and settle for one page.
    if (this.inboxFlight) {
      this.inboxRefreshQueued = true;
      return this.inboxFlight;
    }
    this.inboxFlight = this.loadInboxPage(false).finally(() => {
      this.inboxFlight = null;
    });
    await this.inboxFlight;
    if (!this.inboxRefreshQueued) return;
    this.inboxRefreshQueued = false;
    await this.refreshInboxUi();
  }

  async loadInboxPage(nextSettledPage) {
    this.loadInboxView();
    const drafts = await this.localDraftSessionIds();
    // Always the unfiltered page: the Show menu is a per-device view over it and
    // needs every state's count, and a server-side filter would make the counts
    // a second round trip that could disagree with the rows.
    const params = new URLSearchParams({
      filter: 'all',
      limit: '200',
      local_draft_session_ids: drafts.join(','),
    });
    const settled = new URLSearchParams({ settled: '1', limit: '50', local_draft_session_ids: drafts.join(',') });
    const nextButton = document.querySelector('[data-settled-next]');
    if (nextSettledPage && nextButton?.dataset.cursor) settled.set('cursor', nextButton.dataset.cursor);
    try {
      const [activeResponse, settledResponse] = await Promise.all([
        fetch('/api/inbox?' + params),
        fetch('/api/inbox?' + settled),
      ]);
      if (!activeResponse.ok || !settledResponse.ok) throw new Error('Inbox request failed');
      const active = await activeResponse.json();
      const settledPage = await settledResponse.json();
      const missingActiveRow = active.entries.some((entry) =>
        entry.session.type === 'user'
        && !document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]'));
      if (missingActiveRow) {
        await this.refreshInboxMarkup();
        return;
      }
      this.nextAttentionSessionId = active.next_attention_session_id;
      this.inboxEntries = active.entries;
      this.waitingTotal = active.waiting_total;
      for (const row of document.querySelectorAll('[data-inbox-session-id]')) row.hidden = true;
      for (const entry of active.entries) {
        const row = document.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]');
        if (row) this.paintInboxRow(row, entry);
      }
      this.renderSettled(settledPage, nextSettledPage);
      this.renderDeviceDrafts(drafts, [...active.entries, ...settledPage.entries]);
      this.applyInboxView();
      showToast('info', '', { sourceRef: 'conversation-inbox', recovered: true });
    } catch (_) {
      showToast('error', 'Inbox updates are unavailable', { sourceRef: 'conversation-inbox', persistent: true });
    }
  }

  async refreshInboxMarkup() {
    if (this.inboxMarkupRefresh) return this.inboxMarkupRefresh;
    this.inboxMarkupRefresh = (async () => {
      const response = await fetch(location.href, { headers: { accept: 'text/html' } });
      if (!response.ok) throw new Error('Sidebar request failed');
      const next = new DOMParser().parseFromString(await response.text(), 'text/html').querySelector('#sidebar');
      const current = document.getElementById('sidebar');
      if (!next || !current) throw new Error('Sidebar response is incomplete');
      current.replaceWith(next);
      this.initializeShellUi();
      applyIdenticons(next);
      await this.refreshInboxUi();
    })();
    try {
      return await this.inboxMarkupRefresh;
    } finally {
      this.inboxMarkupRefresh = null;
    }
  }

  /// States a row carries, newest-intent first — the order decides which status
  /// group it lands in and which dot it shows.
  inboxStates(entry) {
    return ['waiting', 'running', 'failed', 'unread', 'done', 'local_draft'].filter((state) => entry[state]);
  }

  paintInboxRow(row, entry) {
    const states = this.inboxStates(entry);
    row.hidden = false;
    row.dataset.conversationRevision = String(entry.conversation_revision);
    row.dataset.inboxState = states.join(' ');
    row.dataset.projectId = entry.project_id || '';
    row.dataset.projectName = entry.project_name || '';

    const project = row.querySelector('[data-inbox-project]');
    if (project) {
      project.textContent = entry.project_name || noProjectLabel;
      project.classList.toggle('row-project--none', !entry.project_name);
    }
    // Grouped by project, line 1 would repeat the group header; it carries the
    // conversation's provider and model instead.
    const model = row.querySelector('[data-inbox-model]');
    if (model) model.textContent = [entry.provider, entry.model].filter(Boolean).join(' · ');
    const identicon = row.querySelector('.row-ident');
    if (identicon) {
      identicon.dataset.identiconId = entry.project_id || '';
      identicon.dataset.identiconInitials = railInitial(entry.project_name || entry.project_id);
      identicon.classList.toggle('identicon--none', !entry.project_id);
    }

    const time = row.querySelector('[data-inbox-time]');
    if (time) {
      time.className = 'row-time';
      if (entry.running && entry.running_since) {
        time.textContent = this.elapsedLabel(entry.running_since);
      } else if (entry.failed) {
        time.textContent = 'Failed';
        time.classList.add('row-time--failed');
      } else {
        time.textContent = this.relativeLabel(entry.session.updatedAt);
        if (entry.waiting) time.classList.add('row-time--waiting');
        else if (entry.unread) time.classList.add('row-time--unread');
      }
    }

    const title = row.querySelector('.row-title');
    if (title) {
      title.classList.toggle('row-title--unread', Boolean(entry.unread || entry.waiting));
      title.classList.toggle('row-title--draft', Boolean(entry.local_draft));
    }

    const state = row.querySelector('[data-inbox-state]');
    if (state) state.replaceChildren(...this.inboxStateGlyph(entry));

    const reason = row.querySelector('[data-inbox-reason]');
    if (reason) this.paintInboxReason(reason, entry);

    applyIdenticons(row);
  }

  inboxStateGlyph(entry) {
    const marks = [
      ['waiting', 'status-dot status-dot--attention', 'Waiting on you'],
      ['running', 'status-dot status-dot--live', 'Running'],
      ['failed', 'status-dot status-dot--error', 'Failed'],
      ['local_draft', 'icon icon-pencil', 'Draft on this device'],
    ];
    for (const [flag, className, label] of marks) {
      if (!entry[flag]) continue;
      const mark = document.createElement('span');
      mark.className = className;
      mark.setAttribute('role', 'img');
      mark.setAttribute('aria-label', label);
      return [mark];
    }
    return [];
  }

  /// Line 3 carries one fact, in falling order of urgency: why the conversation
  /// is waiting, then its fork lineage. Never both — the row is a list entry.
  paintInboxReason(reason, entry) {
    const attention = (this.attentionItems || [])
      .find((item) => item.session_id === entry.session.id && item.action_available);
    if (entry.waiting && attention?.title) {
      reason.className = 'row-l3 row-l3--reason';
      reason.textContent = attention.title;
      reason.hidden = false;
      return;
    }
    if (entry.parent_session_id) {
      const parent = (this.inboxEntries || []).find((item) => item.session.id === entry.parent_session_id);
      reason.className = 'row-l3 row-l3--lineage';
      reason.replaceChildren();
      const glyph = document.createElement('span');
      glyph.className = 'icon icon-corner-down-right';
      glyph.setAttribute('aria-hidden', 'true');
      reason.append(glyph, document.createTextNode('from ' + (parent?.session?.title || 'another conversation')));
      reason.hidden = false;
      return;
    }
    reason.hidden = true;
  }

  matchesInboxFilter(entry, filter) {
    if (filter === 'all') return true;
    if (filter === 'drafts') return Boolean(entry.local_draft);
    return Boolean(entry[filter]);
  }

  applyInboxView() {
    const view = this.loadInboxView();
    const entries = this.inboxEntries || [];
    const list = document.querySelector('[data-inbox-list]');
    if (!list) return;

    for (const [filter] of Object.entries(inboxFilters)) {
      const count = document.querySelector('[data-inbox-count="' + filter + '"]');
      if (!count) continue;
      const total = entries.filter((entry) => this.matchesInboxFilter(entry, filter)).length;
      count.textContent = filter === 'all' || !total ? '' : String(total);
    }

    const visible = entries.filter((entry) =>
      this.matchesInboxFilter(entry, view.filter) &&
      (!view.scope || entry.project_id === view.scope));
    const visibleIds = new Set(visible.map((entry) => entry.session.id));
    for (const row of list.querySelectorAll('[data-inbox-session-id]')) {
      row.hidden = !visibleIds.has(row.dataset.inboxSessionId);
    }
    // Counted from the rows, not from the entries: the inbox also returns the
    // workspace conversation, which the rail renders as its own Workspace item
    // and never as a chat row. Counting entries hid the empty state on an
    // install whose only conversation is that one. Read before grouping, so a
    // collapsed group does not read as an empty list either.
    const shownRows = [...list.querySelectorAll('[data-inbox-session-id]')].filter((row) => !row.hidden).length;

    this.renderScopeMenu(entries, view);
    this.renderViewMenu(view);
    this.renderInboxGroups(list, visible, view);
    this.renderActiveFilter(view);
    this.renderAttentionRow();
    this.syncTopbarState();

    const empty = document.querySelector('[data-inbox-empty]');
    if (empty) {
      const filtered = view.filter !== 'all' || Boolean(view.scope);
      empty.hidden = shownRows !== 0;
      empty.querySelector('[data-inbox-empty-label]').textContent = filtered
        ? 'No matching conversations.'
        : 'No chats yet';
      empty.querySelector('[data-inbox-clear-filter]').hidden = !filtered;
    }
  }

  renderViewMenu(view) {
    for (const item of document.querySelectorAll('[data-inbox-filter],[data-inbox-group]')) {
      const on = item.dataset.inboxFilter === view.filter || item.dataset.inboxGroup === view.group;
      item.classList.toggle('menu-item--on', on);
      item.setAttribute('aria-checked', String(on));
      const tick = item.querySelector('.menu-tick');
      if (tick) {
        tick.className = on ? 'menu-tick icon-control' : 'menu-tick';
        if (on) tick.setAttribute('data-icon', 'check');
        else tick.removeAttribute('data-icon');
      }
    }
  }

  renderScopeMenu(entries, view) {
    const menu = document.querySelector('[data-inbox-scope-menu]');
    const label = document.querySelector('[data-inbox-scope-label]');
    if (!menu) return;
    const projects = new Map();
    for (const entry of entries) {
      if (entry.project_id) projects.set(entry.project_id, entry.project_name || entry.project_id);
    }
    menu.replaceChildren();
    const head = document.createElement('div');
    head.className = 'pop-head';
    head.textContent = 'Scope';
    menu.append(head, this.scopeOption('', 'All projects', view.scope === ''));
    for (const [id, name] of projects) menu.append(this.scopeOption(id, name, view.scope === id));
    if (label) label.textContent = view.scope ? projects.get(view.scope) || view.scope : 'All projects';
  }

  scopeOption(id, name, on) {
    const option = document.createElement('button');
    option.type = 'button';
    option.className = 'palette-item menu-item' + (on ? ' menu-item--on' : '');
    option.setAttribute('role', 'menuitemradio');
    option.setAttribute('aria-checked', String(on));
    option.dataset.inboxScopeOption = id;
    const tick = document.createElement('span');
    tick.className = on ? 'menu-tick icon-control' : 'menu-tick';
    if (on) tick.dataset.icon = 'check';
    const text = document.createElement('span');
    text.className = 'palette-item-label';
    text.textContent = name;
    option.append(tick, text);
    return option;
  }

  /// Grouping is `order` on the existing rows plus inserted headers, so the DOM
  /// keeps the server's recency order and every `[data-inbox-session-id]` lookup
  /// still resolves.
  renderInboxGroups(list, visible, view) {
    for (const header of list.querySelectorAll('.rail-group')) header.remove();
    list.dataset.inboxGrouped = view.group;
    const settled = list.querySelector('[data-settled-section]');
    if (settled) settled.style.order = '999';
    if (view.group === 'none') {
      for (const row of list.querySelectorAll('[data-inbox-session-id]')) row.style.order = '';
      return;
    }

    const buckets = new Map();
    for (const entry of visible) {
      const key = view.group === 'project'
        ? entry.project_id || ''
        : this.inboxStates(entry).find((state) => statusGroupOrder.includes(state)) || 'done';
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(entry);
    }
    const keys = view.group === 'status'
      ? statusGroupOrder.filter((key) => buckets.has(key))
      : [...buckets.keys()];

    let slot = 0;
    for (const key of keys) {
      const rows = buckets.get(key);
      const label = view.group === 'project'
        ? rows[0].project_name || noProjectLabel
        : statusGroupLabels[key];
      const collapsed = this.collapsedGroups.has(view.group + ':' + key);
      list.append(this.groupHeader(
        view.group + ':' + key,
        label,
        rows.length,
        collapsed,
        slot,
        view.group === 'project' ? key : null,
      ));
      slot += 1;
      for (const entry of rows) {
        const row = list.querySelector('[data-inbox-session-id="' + CSS.escape(entry.session.id) + '"]');
        if (!row) continue;
        row.style.order = String(slot);
        if (collapsed) row.hidden = true;
      }
      slot += 1;
    }
  }

  groupHeader(key, label, count, collapsed, slot, projectId) {
    const header = document.createElement('button');
    header.type = 'button';
    header.className = 'rail-group';
    header.dataset.inboxGroupToggle = key;
    header.style.order = String(slot);
    header.setAttribute('aria-expanded', String(!collapsed));
    const chevron = document.createElement('span');
    chevron.className = 'icon-slot';
    const glyph = document.createElement('span');
    glyph.className = 'icon icon-chevron-down';
    glyph.setAttribute('aria-hidden', 'true');
    chevron.append(glyph);
    header.append(chevron);
    if (projectId) {
      const identicon = document.createElement('span');
      identicon.className = 'identicon';
      identicon.setAttribute('aria-hidden', 'true');
      identicon.dataset.identiconId = projectId;
      identicon.dataset.identiconInitials = railInitial(label);
      header.append(identicon);
    }
    const name = document.createElement('span');
    name.className = 'rail-group-name';
    name.textContent = label;
    const total = document.createElement('span');
    total.className = 'rail-group-count';
    total.textContent = String(count);
    header.append(name, total);
    applyIdenticons(header);
    return header;
  }

  renderActiveFilter(view) {
    const host = document.querySelector('[data-inbox-active-filter]');
    if (!host) return;
    const active = view.filter !== 'all';
    host.hidden = !active;
    if (active) host.querySelector('[data-inbox-filter-label]').textContent = inboxFilters[view.filter];
  }

  renderAttentionRow() {
    const row = document.querySelector('[data-next-attention]');
    if (!row) return;
    row.hidden = !this.waitingTotal;
    if (this.waitingTotal) row.querySelector('[data-waiting-total]').textContent = String(this.waitingTotal);
  }

  /// The topbar badge and context crumb are both projections of the inbox row
  /// for the open conversation — the inbox service is the one authority over
  /// that state, and the crumb reads the same row rather than staying at
  /// whatever the server rendered before the first turn was admitted.
  syncTopbarState() {
    const badge = document.querySelector('[data-session-state-badge]');
    const dot = document.querySelector('[data-session-state-dot]');
    if (!badge || !dot) return;
    const sessionId = this.currentSessionPathId();
    const entry = (this.inboxEntries || []).find((item) => item.session.id === sessionId);
    this.syncTopbarCrumb(entry);
    const [label, badgeClass, dotClass] = !entry
      ? ['', '', '']
      : entry.waiting ? ['Waiting on you', 'status-badge-warning', 'status-dot--attention']
      : entry.running ? ['Running', 'status-badge-running', 'status-dot--live']
      : entry.failed ? ['Failed', 'status-badge-error', 'status-dot--error']
      : entry.done ? ['Done', 'status-badge-success', 'status-dot--success']
      : ['Draft', 'status-badge-muted', 'status-dot--idle'];
    badge.hidden = !label;
    dot.hidden = !label;
    if (!label) return;
    badge.className = 'status-badge ' + badgeClass;
    badge.textContent = label;
    dot.className = 'tb-dot status-dot ' + dotClass;
    dot.setAttribute('aria-label', label);
  }

  syncTopbarCrumb(entry) {
    const crumb = document.querySelector('[data-session-crumb]');
    if (!crumb || !entry?.provider) return;
    const identicon = crumb.querySelector('.identicon');
    const project = crumb.querySelector('.crumb-project');
    const name = entry.project_name || noProjectLabel;
    if (project) {
      project.textContent = name;
      project.classList.toggle('row-project--none', !entry.project_name);
    }
    if (identicon) {
      identicon.dataset.identiconId = entry.project_id || '';
      identicon.dataset.identiconInitials = railInitial(entry.project_name);
      identicon.classList.toggle('identicon--none', !entry.project_id);
      applyIdenticons(identicon);
    }
    // The crumb's provider/model segments are the last two spans; the server
    // omits the model one entirely until a model is known, so it is rebuilt
    // rather than patched in place.
    crumb.querySelectorAll('[data-crumb-tail]').forEach((node) => node.remove());
    for (const value of [entry.provider, entry.model].filter(Boolean)) {
      const sep = document.createElement('span');
      sep.className = 'crumb-sep';
      sep.dataset.crumbTail = '';
      sep.setAttribute('aria-hidden', 'true');
      sep.textContent = '·';
      const text = document.createElement('span');
      text.dataset.crumbTail = '';
      text.textContent = value;
      crumb.append(sep, text);
    }
  }

  setInboxView(patch) {
    Object.assign(this.loadInboxView(), patch);
    this.persistInboxView();
    this.applyInboxView();
  }

  setSelectMode(on) {
    this.loadInboxView().selectMode = on;
    document.querySelector('[data-inbox-list]')?.setAttribute('data-inbox-select-mode', String(on));
    if (!on) {
      for (const input of document.querySelectorAll('[data-inbox-select]:checked')) input.checked = false;
    }
    this.syncBulkBar();
  }

  syncBulkBar() {
    const bar = document.querySelector('[data-inbox-bulk]');
    if (!bar) return;
    const selected = document.querySelectorAll('[data-inbox-select]:checked').length;
    bar.hidden = !this.loadInboxView().selectMode;
    bar.querySelector('[data-inbox-selected-count]').textContent = selected + ' selected';
    bar.querySelector('[data-inbox-settle-selected]').disabled = selected === 0;
  }

  relativeLabel(iso) {
    const elapsed = Date.now() - Date.parse(iso);
    if (!Number.isFinite(elapsed)) return '';
    const minutes = Math.floor(elapsed / 60000);
    if (minutes < 1) return 'now';
    if (minutes < 60) return minutes + 'm';
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + 'h';
    return Math.floor(hours / 24) + 'd';
  }

  elapsedLabel(startedAt) {
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - Date.parse(startedAt)) / 1000));
    if (elapsedSeconds < 60) return elapsedSeconds + 's';
    if (elapsedSeconds < 3600) {
      return Math.floor(elapsedSeconds / 60) + 'm' + String(elapsedSeconds % 60).padStart(2, '0') + 's';
    }
    const minutes = Math.floor(elapsedSeconds / 60);
    return Math.floor(minutes / 60) + 'h' + String(minutes % 60).padStart(2, '0') + 'm';
  }

  async settleInboxRows(rows) {
    const members = rows.filter(Boolean).map((row) => ({
      session_id: row.dataset.inboxSessionId,
      conversation_revision: Number.parseInt(row.dataset.conversationRevision || '', 10),
    })).filter((member) => member.session_id && Number.isInteger(member.conversation_revision));
    if (!members.length) {
      this.announceInbox('Select at least one conversation');
      return;
    }
    const drafts = await this.localDraftSessionIds();
    const response = await fetch('/api/inbox/settle', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ members, local_draft_session_ids: drafts }),
    });
    if (!response.ok) {
      this.announceInbox('Conversations could not be settled');
      return;
    }
    const body = await response.json();
    const accepted = body.results.filter((result) => result.accepted).length;
    const rejected = body.results.length - accepted;
    this.announceInbox(accepted + ' settled' + (rejected ? ', ' + rejected + ' unchanged' : ''));
    for (const input of document.querySelectorAll('[data-inbox-select]:checked')) input.checked = false;
    this.syncBulkBar();
    await this.refreshInboxUi();
  }

  announceInbox(message) {
    const region = document.querySelector('[data-inbox-announcer]');
    if (region) region.textContent = message;
  }

  /// Builds the rail's two/three-line row for a list the server did not render
  /// (settled conversations, device drafts). Same grammar as a live row, so the
  /// tail and the drafts section stay aligned with the list above them.
  buildRailRow(entry, { trailing } = {}) {
    const row = document.createElement('div');
    row.className = 'row';
    const check = document.createElement('span');
    check.className = 'row-check';

    const link = document.createElement('a');
    link.className = 'row-main';
    link.href = '/sessions/' + encodeURIComponent(entry.session.id) + apiQs();

    const line1 = document.createElement('span');
    line1.className = 'row-l1';
    const identicon = document.createElement('span');
    identicon.className = 'identicon row-ident';
    identicon.setAttribute('aria-hidden', 'true');
    identicon.dataset.identiconId = entry.project_id || '';
    identicon.dataset.identiconInitials = railInitial(entry.project_name);
    if (!entry.project_id) identicon.classList.add('identicon--none');
    const project = document.createElement('span');
    project.className = 'row-project' + (entry.project_name ? '' : ' row-project--none');
    project.textContent = entry.project_name || noProjectLabel;
    line1.append(identicon, project);

    const line2 = document.createElement('span');
    line2.className = 'row-l2';
    const title = document.createElement('span');
    title.className = 'row-title';
    title.textContent = entry.session.title || 'Untitled draft';
    const state = document.createElement('span');
    state.className = 'row-state';
    line2.append(title, state);
    link.append(line1, line2);

    const right = document.createElement('span');
    right.className = 'row-right';
    const time = document.createElement('span');
    time.className = 'row-time';
    time.textContent = this.relativeLabel(entry.session.settledAt || entry.session.updatedAt);
    right.append(time);
    if (trailing) {
      const actions = document.createElement('span');
      actions.className = 'row-actions';
      actions.append(trailing);
      right.append(actions);
    }

    row.append(check, link, right);
    applyIdenticons(row);
    return row;
  }

  renderSettled(page, append) {
    const list = document.querySelector('[data-settled-list]');
    if (!list) return;
    if (!append) list.replaceChildren();
    for (const entry of page.entries) {
      const restore = document.createElement('button');
      restore.type = 'button';
      restore.className = 'btn btn-icon-sm';
      restore.dataset.icon = 'retry';
      restore.title = 'Restore';
      restore.setAttribute('aria-label', 'Restore conversation');
      restore.addEventListener('click', () => this.restoreSettled(entry));
      list.appendChild(this.buildRailRow(entry, { trailing: restore }));
    }
    const section = document.querySelector('[data-settled-section]');
    if (section) section.hidden = page.total === 0;
    const total = document.querySelector('[data-settled-total]');
    if (total) total.textContent = '(' + page.total + ')';
    const next = document.querySelector('[data-settled-next]');
    if (next) {
      next.hidden = !page.next_cursor;
      next.dataset.cursor = page.next_cursor || '';
    }
  }

  async restoreSettled(entry) {
    const response = await fetch('/api/inbox/' + encodeURIComponent(entry.session.id) + '/restore', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ conversation_revision: entry.conversation_revision }),
    });
    if (response.ok) location.reload();
    else showToast('error', 'Conversation changed before it could be restored');
  }

  renderDeviceDrafts(draftIds, entries) {
    const section = document.querySelector('[data-device-drafts]');
    const list = document.querySelector('[data-device-draft-list]');
    if (!section || !list) return;
    list.replaceChildren();
    for (const id of draftIds) {
      const entry = entries.find((candidate) => candidate.session.id === id)
        || { session: { id, title: 'Untitled draft' } };
      const row = this.buildRailRow(entry);
      row.querySelector('.row-title').classList.add('row-title--draft');
      if (entry.session.settledAt) {
        const note = document.createElement('span');
        note.className = 'row-l3';
        note.textContent = 'settled remotely';
        row.querySelector('.row-main').append(note);
      }
      list.appendChild(row);
    }
    section.hidden = draftIds.length === 0;
  }

  /// Same rule as the rail: `#topbar` is replaced out of band by navigation, and
  /// the feed this controller already holds re-paints the new panel.
  initAttentionUi() {
    if (!document.querySelector('[data-attention-toggle]')) return;
    if (!this.attentionPage) {
      this.refreshAttentionUi();
      return;
    }
    this.paintAttention(this.attentionPage);
  }

  /// The shell's four popovers — rail scope, rail view options, topbar overflow,
  /// attention — share one open-at-most-one rule, so a second trigger closes the
  /// first instead of stacking two dismissible layers.
  shellPopoverFor(trigger) {
    const pairs = [
      ['data-inbox-view', '[data-inbox-view-menu]'],
      ['data-inbox-scope', '[data-inbox-scope-menu]'],
      ['data-topbar-overflow', '[data-topbar-menu]'],
      ['data-attention-toggle', '[data-attention-panel]'],
    ];
    const pair = pairs.find(([attribute]) => trigger.hasAttribute(attribute));
    return pair ? document.querySelector(pair[1]) : null;
  }

  /// [keyboard] is whether the trigger was activated by key rather than pointer.
  /// It decides where focus lands, not what opens: a keyboard user needs the
  /// first item focused to carry on with the keyboard, while focusing it after a
  /// click paints a ring on a menu the pointer is already aimed at.
  toggleShellPopover(trigger, { keyboard = false } = {}) {
    const panel = this.shellPopoverFor(trigger);
    if (!panel) return;
    const open = panel.hidden;
    this.closeShellPopovers();
    if (!open) return;
    // A chat-owned entry on a page with no conversation would be a dead item; it
    // is hidden rather than shown disabled. The test is the controller element
    // the event is dispatched on, not a class any page could carry.
    const hasChat = Boolean(document.querySelector('#main-content[data-controller~="dc-chat"]'));
    for (const item of panel.querySelectorAll('[data-chat-action]')) item.hidden = !hasChat;
    panel.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');
    if (trigger.hasAttribute('data-attention-toggle')) this.markVisibleAttentionRead();
    if (keyboard) {
      panel.querySelector('a:not([hidden]),button:not([hidden])')?.focus();
      return;
    }
    // Focus still enters the panel so Escape and Tab reach it and so the reader
    // is not left on the trigger, but the container takes no ring of its own.
    panel.tabIndex = -1;
    panel.focus({ preventScroll: true });
  }

  closeShellPopovers() {
    for (const selector of ['[data-inbox-view-menu]', '[data-inbox-scope-menu]', '[data-topbar-menu]', '[data-attention-panel]']) {
      const panel = document.querySelector(selector);
      if (panel) panel.hidden = true;
    }
    for (const trigger of document.querySelectorAll('[data-inbox-view],[data-inbox-scope],[data-topbar-overflow],[data-attention-toggle]')) {
      trigger.setAttribute('aria-expanded', 'false');
    }
  }

  async refreshAttentionUi(cursor = null) {
    // A paged read is its own request; only the unpaged refresh coalesces, and
    // for the same reason the rail's does — navigation emits two change events.
    if (!cursor) {
      if (this.attentionFlight) {
        this.attentionRefreshQueued = true;
        return this.attentionFlight;
      }
      this.attentionFlight = this.loadAttentionPage(null).finally(() => {
        this.attentionFlight = null;
      });
      await this.attentionFlight;
      if (!this.attentionRefreshQueued) return;
      this.attentionRefreshQueued = false;
      return this.refreshAttentionUi();
    }
    return this.loadAttentionPage(cursor);
  }

  async loadAttentionPage(cursor) {
    try {
      const response = await fetch('/api/attention?' + new URLSearchParams({ limit: '50', ...(cursor ? { cursor } : {}) }));
      if (!response.ok) throw new Error('Attention request failed');
      this.paintAttention(await response.json());
      showToast('info', '', { sourceRef: 'attention-feed', recovered: true });
    } catch (_) {
      showToast('error', 'Attention updates are unavailable', { sourceRef: 'attention-feed', persistent: true });
    }
  }

  paintAttention(page) {
    this.attentionPage = page;
    this.attentionItems = page.items;
    const list = document.querySelector('[data-attention-list]');
    if (!list) return;
    list.replaceChildren();
    // Two groups, each carrying its own count: a single number over both would
    // read as the sum of things that are not one kind.
    const blocked = page.items.filter((item) => item.action_available);
    const finished = page.items.filter((item) => !item.action_available);
    for (const [label, items] of [['Blocked on you', blocked], ['Finished', finished]]) {
      if (!items.length) continue;
      const group = document.createElement('div');
      group.className = 'notif-group';
      group.textContent = label + ' · ' + items.length;
      list.appendChild(group);
      for (const item of items) list.appendChild(this.attentionRow(item));
    }
    const unread = document.querySelector('[data-attention-unread]');
    if (unread) {
      unread.textContent = page.unread_total ? String(page.unread_total) : '';
      unread.hidden = !page.unread_total;
    }
    const next = document.querySelector('[data-attention-panel] [data-attention-next]');
    if (next) {
      next.hidden = !page.next_cursor;
      next.onclick = () => this.refreshAttentionUi(page.next_cursor);
    }
    // Rail rows read their reason line off this feed.
    this.applyInboxView();
  }

  /// Canon row grammar — dot · body · time. The resolve actions take the time's
  /// slot on hover/focus rather than adding a permanent row the grammar has no
  /// place for; at the touch tier canon floors them at 44px.
  attentionRow(item) {
    const row = document.createElement('a');
    row.className = 'notif-item' + (item.unread ? ' notif-item--unread' : '');
    row.dataset.eventId = item.event_id;
    const query = new URLSearchParams();
    if (item.message_id) query.set('message', item.message_id);
    const token = getApiToken();
    if (token) query.set('token', token);
    const recordTarget = item.record_id ? '#record-' + encodeURIComponent(item.record_id) : '';
    row.href = '/sessions/' + encodeURIComponent(item.session_id) + (query.size ? '?' + query : '') + recordTarget;

    const dot = document.createElement('span');
    dot.className = 'status-dot ' + (item.action_available ? 'status-dot--attention' : item.status === 'failed' ? 'status-dot--error' : 'status-dot--success');
    dot.setAttribute('aria-hidden', 'true');

    const body = document.createElement('span');
    body.className = 'notif-item-body';
    const title = document.createElement('span');
    title.className = 'notif-item-title';
    title.textContent = item.title;
    const detail = document.createElement('span');
    detail.className = 'notif-item-detail';
    // The dot already carries the status and the source repeats the title's
    // context; the canon row has one detail slot and it belongs to the reason.
    detail.textContent = item.detail || '';
    body.append(title, detail);

    const time = document.createElement('time');
    time.className = 'notif-item-time';
    time.dateTime = item.occurred_at;
    time.textContent = this.relativeLabel(item.occurred_at);

    const actions = document.createElement('span');
    actions.className = 'notif-item-actions';
    const resolveActions = item.action_available
      ? [['check', 'Approve', () => this.resolveAttention(item, true)],
         ['circle-x', 'Reject', () => this.resolveAttention(item, false)]]
      : [];
    if (item.dismissible) {
      resolveActions.push(['x', 'Dismiss', () => this.updateAttentionMarker('/api/attention/dismiss', item)]);
    }
    for (const [icon, label, run] of resolveActions) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'btn btn-icon-sm';
      button.dataset.icon = icon;
      button.title = label;
      button.setAttribute('aria-label', label + ' ' + item.title);
      button.addEventListener('click', (event) => {
        event.preventDefault();
        run();
      });
      actions.appendChild(button);
    }

    row.append(dot, body, time);
    if (resolveActions.length) row.append(actions);
    return row;
  }

  async markVisibleAttentionRead() {
    const newestBySession = new Map();
    for (const item of this.attentionItems || []) {
      if (item.unread && !newestBySession.has(item.session_id)) newestBySession.set(item.session_id, item);
    }
    await Promise.all([...newestBySession.values()].map((item) => this.updateAttentionMarker('/api/attention/read', item, false)));
    if (newestBySession.size) this.refreshAttentionUi();
  }

  async updateAttentionMarker(path, item, refresh = true) {
    const response = await fetch(path, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event_id: item.event_id,
        session_id: item.session_id,
        conversation_revision: item.conversation_revision,
      }),
    });
    if (response.ok && refresh) this.refreshAttentionUi();
    return response.ok;
  }

  async resolveAttention(item, approved) {
    const response = await fetch('/api/attention/action', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        event_id: item.event_id, session_id: item.session_id, attempt_id: item.attempt_id,
        turn_id: item.turn_id, request_id: item.request_id,
        conversation_revision: item.conversation_revision, approved,
      }),
    });
    if (response.ok) this.refreshAttentionUi();
    else showToast('error', 'That attention action is no longer available');
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

    beginSessionDraftMutation(sessionId);
    fetch('/api/sessions/' + encodeURIComponent(sessionId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newTitle }),
    })
      .then((response) => {
        if (!response.ok) throw new Error('Failed to rename session');
        input.dataset.originalTitle = newTitle;
        const chatArea = document.querySelector('.chat-area');
        if (chatArea) {
          chatArea.dataset.hasTitle = 'true';
          delete chatArea.dataset.newChatDraft;
        }
        syncSidebarSessionTitle(sessionId, newTitle);
        document.title = newTitle + ' - ' + (document.body.dataset.appName || 'DartClaw');
        showToast('success', 'Session renamed');
      })
      .catch((error) => {
        input.value = original;
        showToast('error', error.message || 'Failed to rename session');
      })
      .finally(() => endSessionDraftMutation(sessionId));
  }

  createSession() {
    if (this.sessionCreatePromise) return this.sessionCreatePromise;

    const createButtons = Array.from(document.querySelectorAll('[data-session-create]'));
    for (const button of createButtons) {
      button.disabled = true;
      button.setAttribute('aria-busy', 'true');
    }

    this.sessionCreatePromise = this.openNewChatAfterPendingMutation()
      .catch((error) => {
        showToast('error', error.message || 'Failed to create session');
      })
      .finally(() => {
        this.sessionCreatePromise = null;
        for (const button of createButtons) {
          button.disabled = false;
          button.removeAttribute('aria-busy');
        }
      });
    return this.sessionCreatePromise;
  }

  async openNewChatAfterPendingMutation() {
    await this.waitForSessionDraftMutation();
    if (this.focusCurrentNewChatDraft()) return;

    const response = await fetch('/api/sessions/open', { method: 'POST' });
    if (!response.ok) throw new Error('Failed to create session');
    const data = await response.json();
    if (data.id === this.currentSessionPathId() && this.focusCurrentNewChatDraft()) return;
    window.location.href = '/sessions/' + data.id;
  }

  waitForSessionDraftMutation() {
    const mutationPending = () => {
      const chatArea = document.querySelector('.chat-area');
      return chatArea?.dataset.sessionId === this.currentSessionPathId() &&
        Number.parseInt(chatArea.dataset.sessionMutationPending || '0', 10) > 0;
    };
    if (!mutationPending()) return Promise.resolve();

    return new Promise((resolve) => {
      const handleComplete = () => {
        if (mutationPending()) return;
        document.removeEventListener('dartclaw:session-draft-mutation-complete', handleComplete);
        resolve();
      };
      document.addEventListener('dartclaw:session-draft-mutation-complete', handleComplete);
      handleComplete();
    });
  }

  focusCurrentNewChatDraft() {
    const chatArea = document.querySelector('.chat-area[data-new-chat-draft="true"]');
    if (!chatArea || chatArea.dataset.sessionId !== this.currentSessionPathId()) return false;
    if (chatArea.querySelector('#messages .msg')) return false;
    this.setSidebarOpen(false);
    chatArea.querySelector('#message-input')?.focus();
    return true;
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

  /// Reset archives the conversation and leaves every rendered surface stale —
  /// transcript, topbar state, rail row. 0.27 drove it through `hx-swap="none"`
  /// and re-rendered nothing; it is a shell mutation like archive and delete, so
  /// it settles here and reloads rather than relying on a swap that swaps nothing.
  async resetSession(button) {
    const sessionId = button.dataset.sessionId;
    if (!sessionId) return;
    this.closeShellPopovers();
    const confirmed = await confirmDialog({
      title: 'Reset conversation',
      body: 'Reset this session? Conversation will be archived.',
      confirmLabel: 'Reset',
      danger: true,
    });
    if (!confirmed) return;
    try {
      const response = await fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/reset', { method: 'POST' });
      if (!response.ok) throw new Error('Failed to reset session');
      queueToast('success', 'Conversation reset');
      location.reload();
    } catch (error) {
      showToast('error', error.message || 'Failed to reset session');
    }
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
    showToast('error', readHtmxErrorMessage(event.detail.ctx, 'Request failed'));
  }

  handleHtmxError(event) {
    if (!event.detail) return;
    showToast('error', event.detail.error?.message || 'Could not reach the server');
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
    const target = event.detail?.ctx?.target;
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
  captureStickyIntent(event) {
    if (!event.detail?.ctx) return;
    event.detail.ctx.dartclawStickyIntent = {
      messages: isAtBottom(document.querySelector('.messages')),
      timeline: isAtBottom(document.querySelector('[data-auto-scroll="true"]')),
    };
  }

  connectGlobalEvents() {
    if (this.globalEventSource) return;
    const url = '/api/events' + apiQs();
    this.globalEventSource = new EventSource(url);
    this.globalEventSource.addEventListener('server_restart', () => this.showRestartOverlay());
    this.globalEventSource.addEventListener('context_warning', (event) => this.showContextWarning(event));
    this.globalEventSource.addEventListener('conversation_changed', (event) => {
      try {
        document.body.dispatchEvent(new CustomEvent('dartclaw:conversation-changed', { detail: JSON.parse(event.data) }));
      } catch (_) {}
    });
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
