import {
  beginSessionDraftMutation,
  confirmDialog,
  conversationDraftSessionIds,
  endSessionDraftMutation,
  escapeHtml,
  inputDialog,
  isAtBottom,
  openConversationDraftDb,
  readHtmxErrorMessage,
  renderMarkdown,
  scrollToBottom,
  showBanner,
  showToast,
} from './shared.js';

const temporaryDrafts = new Map();

export default class DcChatController extends Stimulus.Controller {
  connect() {
    this.attachments = [];
    this.references = [];
    this.filteredReferences = [];
    this.activeReferenceIndex = 0;
    this.streaming = false;
    this.chatRequestPending = false;
    this.recoveryActive = false;
    this.turnFinalized = false;
    this.canCancel = false;
    this.activeTurnId = null;
    this.turnStatusTimer = null;
    this.turnStatusPollGeneration = 0;
    this.streamRecoveryTurnId = null;
    this.conversationReady = false;
    this.conversationRevision = 0;
    this.ordinaryControls = true;
    this.maxAttachmentBytes = 0;
    this.draftRevisionId = this.generateClientId();
    this.draftTouched = false;
    this.submittedRevisionId = null;
    this.saveTimer = null;
    this.pendingConflict = null;
    this.queueItems = new Map();
    this.findStops = [];
    this.findIndex = 0;
    this.findGeneration = 0;
    this.findTruncated = false;
    this.appliedProvider = null;
    this.paginationAnchor = null;
    this.paginationAnchorTop = null;
    this.historyViewState = null;
    this.handleBeforeRequest = this.handleBeforeRequest.bind(this);
    this.handleFinallyRequest = this.handleFinallyRequest.bind(this);
    this.handleSseBeforeMessage = this.handleSseBeforeMessage.bind(this);
    this.handleSseClose = this.handleSseClose.bind(this);
    this.handleLoadEarlierClick = this.handleLoadEarlierClick.bind(this);
    this.handleHistoryClick = this.handleHistoryClick.bind(this);
    this.handleTextareaInput = this.handleTextareaInput.bind(this);
    this.handleTextareaKeydown = this.handleTextareaKeydown.bind(this);
    this.handleSendButtonClick = this.handleSendButtonClick.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);
    this.handleConnectivityChange = this.handleConnectivityChange.bind(this);
    this.handleContextDialogKeydown = this.handleContextDialogKeydown.bind(this);
    this.handleDocumentPointerDown = this.handleDocumentPointerDown.bind(this);
    this.handleChatAction = this.handleChatAction.bind(this);
    this.handleViewportChange = this.handleViewportChange.bind(this);
    this.handleVisibleReadBoundary = this.handleVisibleReadBoundary.bind(this);
    this.handleTemporaryBeforeUnload = this.handleTemporaryBeforeUnload.bind(this);
    this.handleTemporaryPageHide = this.handleTemporaryPageHide.bind(this);
    this.handleTemporaryDialogKeydown = this.handleTemporaryDialogKeydown.bind(this);
    this.handleTemporaryDialogClose = this.handleTemporaryDialogClose.bind(this);

    document.body.addEventListener('htmx:before:request', this.handleBeforeRequest);
    document.body.addEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.addEventListener('htmx:sse:before:message', this.handleSseBeforeMessage);
    document.body.addEventListener('htmx:sse:close', this.handleSseClose);
    this.element.addEventListener('click', this.handleLoadEarlierClick);
    this.element.addEventListener('click', this.handleHistoryClick);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    this.element.addEventListener('dartclaw:chat-action', this.handleChatAction);
    document.addEventListener('pointerdown', this.handleDocumentPointerDown);
    window.addEventListener('online', this.handleConnectivityChange);
    window.addEventListener('offline', this.handleConnectivityChange);
    window.addEventListener('resize', this.handleViewportChange);
    document.addEventListener('visibilitychange', this.handleVisibleReadBoundary);
    this.element.querySelector('.messages')?.addEventListener('scroll', this.handleVisibleReadBoundary, { passive: true });
    if (this.isTemporary) {
      window.addEventListener('beforeunload', this.handleTemporaryBeforeUnload);
      window.addEventListener('pagehide', this.handleTemporaryPageHide);
    }

    this.initTextarea();
    this.sendButton?.addEventListener('click', this.handleSendButtonClick);
    this.updateSendState();
    this.observeComposerStack();
    this.handleViewportChange();
    renderMarkdown(this.element);
    scrollToBottom(this.element, { force: true });
    this.restoreStoredHistoryViewState();
    this.revealHistoryTarget();
    this.initializeConversationState();
    this.initializeDraftStorage();
    this.contextPopover?.addEventListener('keydown', this.handleContextDialogKeydown);
    this.temporaryDialogs.forEach((dialog) => {
      dialog.addEventListener('keydown', this.handleTemporaryDialogKeydown);
      dialog.addEventListener('close', this.handleTemporaryDialogClose);
    });
  }

  disconnect() {
    this.storeHistoryViewState();
    document.body.removeEventListener('htmx:before:request', this.handleBeforeRequest);
    document.body.removeEventListener('htmx:finally:request', this.handleFinallyRequest);
    document.body.removeEventListener('htmx:sse:before:message', this.handleSseBeforeMessage);
    document.body.removeEventListener('htmx:sse:close', this.handleSseClose);
    this.element.removeEventListener('click', this.handleLoadEarlierClick);
    this.element.removeEventListener('click', this.handleHistoryClick);
    document.body.removeEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    this.element.removeEventListener('dartclaw:chat-action', this.handleChatAction);
    document.removeEventListener('pointerdown', this.handleDocumentPointerDown);
    window.removeEventListener('online', this.handleConnectivityChange);
    window.removeEventListener('offline', this.handleConnectivityChange);
    window.removeEventListener('resize', this.handleViewportChange);
    this.stackObserver?.disconnect();
    document.removeEventListener('visibilitychange', this.handleVisibleReadBoundary);
    this.element.querySelector('.messages')?.removeEventListener('scroll', this.handleVisibleReadBoundary);
    window.removeEventListener('beforeunload', this.handleTemporaryBeforeUnload);
    window.removeEventListener('pagehide', this.handleTemporaryPageHide);
    this._stopTurnStatusPolling();
    this.streamRecoveryTurnId = null;
    document.body.classList.remove('streaming');
    this.form?.classList.remove('composer--streaming');
    const textarea = this.textarea;
    if (textarea) {
      textarea.removeEventListener('input', this.handleTextareaInput);
      textarea.removeEventListener('keydown', this.handleTextareaKeydown);
    }
    this.sendButton?.removeEventListener('click', this.handleSendButtonClick);
    clearTimeout(this.saveTimer);
    clearTimeout(this.saveStatusTimer);
    clearTimeout(this.findTimer);
    this.draftChannel?.close();
    this.contextPopover?.removeEventListener('keydown', this.handleContextDialogKeydown);
    this.temporaryDialogs.forEach((dialog) => {
      dialog.removeEventListener('keydown', this.handleTemporaryDialogKeydown);
      dialog.removeEventListener('close', this.handleTemporaryDialogClose);
    });
  }

  get textarea() {
    return this.element.querySelector('#message-input');
  }

  get sendButton() {
    return this.element.querySelector('#send-btn');
  }

  get form() {
    return this.element.querySelector('#chat-form');
  }

  get contextTray() {
    return this.element.querySelector('[data-dc-chat-target="contextTray"]');
  }

  get referencePalette() {
    return this.element.querySelector('[data-dc-chat-target="referencePalette"]');
  }

  get attachmentsInput() {
    return this.element.querySelector('[data-dc-chat-target="attachmentsInput"]');
  }

  get referencesInput() {
    return this.element.querySelector('[data-dc-chat-target="referencesInput"]');
  }

  get recovery() {
    return this.element.querySelector('[data-dc-chat-target="recovery"]');
  }

  get saveStatus() {
    return this.element.querySelector('[data-dc-chat-target="saveStatus"]');
  }

  get saveGlyph() {
    return this.element.querySelector('[data-dc-chat-target="saveGlyph"]');
  }

  get composerStack() {
    return this.element.querySelector('[data-dc-chat-target="composerStack"]');
  }

  get requestStrip() {
    return this.element.querySelector('[data-dc-chat-target="requestStrip"]');
  }

  get findBar() {
    return this.element.querySelector('[data-dc-chat-target="findBar"]');
  }

  get findQuery() {
    return this.element.querySelector('[data-dc-chat-target="findQuery"]');
  }

  get findCount() {
    return this.element.querySelector('[data-dc-chat-target="findCount"]');
  }

  get queueButton() {
    return this.element.querySelector('[data-dc-chat-target="queueButton"]');
  }

  get steerToggle() {
    return this.element.querySelector('[data-dc-chat-target="steerToggle"]');
  }

  get steerMenu() {
    return this.element.querySelector('[data-dc-chat-target="steerMenu"]');
  }

  get contextPopover() {
    return this.element.querySelector('[data-dc-chat-target="contextPopover"]');
  }

  get liveStatus() {
    return this.element.querySelector('[data-dc-chat-target="liveStatus"]');
  }

  get recoveryActions() {
    return this.element.querySelector('[data-dc-chat-target="recoveryActions"]');
  }

  get conflictAction() {
    return this.element.querySelector('[data-dc-chat-target="conflictAction"]');
  }

  get queue() {
    return this.element.querySelector('[data-dc-chat-target="queue"]');
  }

  get steerButton() {
    return this.element.querySelector('[data-dc-chat-target="steerButton"]');
  }

  get submissionIdInput() {
    return this.element.querySelector('[data-dc-chat-target="submissionIdInput"]');
  }

  get revisionIdInput() {
    return this.element.querySelector('[data-dc-chat-target="revisionIdInput"]');
  }

  get sessionId() {
    return this.element.dataset.sessionId;
  }

  get isTemporary() {
    return this.element.dataset.retention === 'process';
  }

  handleTemporaryBeforeUnload(event) {
    if (!this.draftTouched && !this.textarea?.value) return;
    event.preventDefault();
    event.returnValue = '';
  }

  handleTemporaryPageHide() {
    clearTimeout(this.saveTimer);
    temporaryDrafts.delete(this.sessionId);
    if (this.textarea) this.textarea.value = '';
    this.attachments = [];
    this.references = [];
    this.syncRichInputs();
    this.draftRevisionId = this.generateClientId();
    this.draftSubmissionId = this.generateClientId();
    this.draftTouched = false;
  }

  get temporaryDialogs() {
    return this.element.querySelectorAll('.temporary-dialog');
  }

  /// The dock's measured height drives the transcript's bottom padding and the
  /// fade that hides the last turn behind the floating composer. It grows with
  /// queue rows, the approval strip and recovery actions, so it is measured
  /// rather than guessed.
  observeComposerStack() {
    const stack = this.composerStack;
    if (!stack || typeof ResizeObserver !== 'function') return;
    const publish = () => {
      const area = stack.closest('.input-area');
      this.element.style.setProperty('--stack-h', (area?.offsetHeight || 0) + 'px');
    };
    this.stackObserver = new ResizeObserver(publish);
    this.stackObserver.observe(stack);
    publish();
  }

  /// The shortcut hint is a desktop-only placeholder: there is no modifier key
  /// at the touch tier, and the longer string wraps onto a second line.
  handleViewportChange() {
    const textarea = this.textarea;
    if (!textarea || this.streaming) return;
    const narrow = globalThis.matchMedia?.('(max-width: 768px)').matches;
    textarea.placeholder = narrow ? 'Message DartClaw…' : 'Message DartClaw…  ⌘↵ to send';
  }

  /// The topbar overflow menu and the command palette live outside this
  /// controller's element, so they reach these surfaces by dispatching
  /// `dartclaw:chat-action` on `#main-content` with one of these four actions.
  /// The model/effort commands keep their own route: they click
  /// `#effective-context-open` and focus the field they name.
  handleChatAction(event) {
    const actions = {
      find: () => this.openFind(),
      export: () => this.openTemporaryExport(),
      'temporary-create': () => this.openTemporaryCreate(),
      'temporary-end': () => this.openTemporaryEnd(),
    };
    const run = actions[event.detail?.action];
    if (!run) return;
    event.stopPropagation();
    run();
  }

  openCommands() {
    const textarea = this.textarea;
    if (!textarea) return;
    if (!textarea.value.startsWith('/')) textarea.value = '/' + textarea.value;
    textarea.focus();
    textarea.setSelectionRange(1, 1);
    textarea.dispatchEvent(new Event('input', { bubbles: true }));
  }

  toggleContextPopover(event) {
    if (this.contextPopover && !this.contextPopover.hidden) {
      this.closeContextPopover();
      return;
    }
    this.openContextPopover(event);
  }

  openContextPopover(event) {
    const popover = this.contextPopover;
    if (!popover) return;
    this.contextPopoverReturnFocus = event?.currentTarget || document.activeElement;
    popover.hidden = false;
    this.setContextExpanded(true);
    // The first editable row, not the close button that precedes it in the head.
    popover.querySelector('form select, form input:not([type="hidden"])')?.focus();
  }

  closeContextPopover() {
    const popover = this.contextPopover;
    if (!popover || popover.hidden) return;
    popover.hidden = true;
    this.setContextExpanded(false);
    this.contextPopoverReturnFocus?.focus();
  }

  setContextExpanded(open) {
    this.element.querySelectorAll('[data-action~="dc-chat#toggleContextPopover"]')
      .forEach((trigger) => trigger.setAttribute('aria-expanded', String(open)));
  }

  handleDocumentPointerDown(event) {
    const popover = this.contextPopover;
    if (popover && !popover.hidden && !event.target.closest('.pop-context') &&
        !event.target.closest('[data-action~="dc-chat#toggleContextPopover"]')) {
      this.closeContextPopover();
    }
    const menu = this.steerMenu;
    if (menu && !menu.hidden && !event.target.closest('.composer-send-group')) this.closeSteerMenu();
  }

  toggleSteerMenu() {
    const menu = this.steerMenu;
    if (!menu) return;
    menu.hidden = !menu.hidden;
    this.steerToggle?.setAttribute('aria-expanded', String(!menu.hidden));
  }

  closeSteerMenu() {
    if (this.steerMenu) this.steerMenu.hidden = true;
    this.steerToggle?.setAttribute('aria-expanded', 'false');
  }

  submitForm() {
    this.form?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  }

  contextProviderChanged(event) {
    const option = event.currentTarget.selectedOptions?.[0];
    const form = event.currentTarget.form;
    if (!option || !form) return;
    const model = form.elements.namedItem('model');
    const effort = form.elements.namedItem('effort');
    if (model) {
      model.disabled = option.dataset.modelEditable !== 'true';
      if (model.disabled) model.value = '';
    }
    if (effort) {
      effort.disabled = option.dataset.effortEditable !== 'true';
      if (effort.disabled) effort.value = '';
    }
    this.updateContinuityWarning();
  }

  async applyContext(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const validation = this.element.querySelector('#effective-context-validation');
    const apply = form.querySelector('[type="submit"]');
    const fields = new FormData(form);
    const optionalValue = (name) => {
      const value = fields.get(name);
      return typeof value === 'string' && value.trim() ? value.trim() : null;
    };
    const payload = {
      conversation_revision: this.conversationRevision,
      project_id: fields.get('project_id'),
      directory: fields.get('directory'),
      provider: fields.get('provider'),
      model: optionalValue('model'),
      effort: optionalValue('effort'),
      attachments: this.attachments.filter((item) => item.state === 'ready'),
      references: this.references.filter((item) => item.state === 'resolved'),
    };
    apply.disabled = true;
    if (validation) validation.hidden = true;
    try {
      const response = await fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/context', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        if (validation) {
          validation.textContent = result.error?.message || 'Context change was rejected';
          validation.hidden = false;
        }
        return;
      }
      this.reconcileContext(result);
      if (this.liveStatus) this.liveStatus.textContent = 'Context updated for the next turn';
    } catch (_) {
      if (validation) {
        validation.textContent = 'Context change could not be applied';
        validation.hidden = false;
      }
    } finally {
      apply.disabled = false;
    }
  }

  reconcileContext(snapshot) {
    const view = snapshot.effective_context;
    const next = snapshot.next_context;
    const nextRevision = Number(snapshot.revision);
    if (!view || !next || !Number.isInteger(nextRevision)) return;

    const form = this.element.querySelector('#effective-context-form');
    const project = form?.elements.namedItem('project_id');
    const directory = form?.elements.namedItem('directory');
    const provider = form?.elements.namedItem('provider');
    const model = form?.elements.namedItem('model');
    const effort = form?.elements.namedItem('effort');
    if (!project || !directory || !provider || !model || !effort) return;
    if (![...project.options].some((option) => option.value === view.projectId)) return;
    if (![...provider.options].some((option) => option.value === view.provider)) return;

    project.value = view.projectId;
    directory.value = view.directory;
    provider.value = view.provider;
    model.disabled = view.modelEditable !== true;
    model.value = view.modelValue || '';
    effort.disabled = view.effortEditable !== true;
    effort.value = view.effortValue || '';

    const text = {
      '#effective-context-workspace': view.workspace,
      '#effective-context-project-name': view.project,
      '#effective-context-current': view.current,
      '#effective-context-composer-provider': view.composer,
      '#effective-context-telemetry': view.telemetry,
      '#effective-context-behavior': view.behavior,
      '#effective-context-memory': view.memory,
    };
    for (const [selector, value] of Object.entries(text)) {
      const mount = this.element.querySelector(selector);
      if (mount) mount.textContent = value || '';
    }
    const usage = this.element.querySelector('#effective-context-usage');
    if (usage) {
      usage.textContent = view.usage || '';
      usage.hidden = !view.usage;
    }
    const identicon = this.element.querySelector('.composer-context-chip [data-identicon-id]');
    if (identicon) identicon.dataset.identiconId = view.projectId;
    const memoryRow = this.element.querySelector('#effective-context-memory-row');
    if (memoryRow) memoryRow.hidden = !view.memory;
    // The editable rows are the statement of next-turn context; the current one
    // appears only while it differs from them.
    const currentRow = this.element.querySelector('#effective-context-current-row');
    if (currentRow) currentRow.hidden = view.currentHidden === true;
    for (const id of ['#effective-context-directory', '#effective-context-behavior']) {
      const mount = this.element.querySelector(id);
      if (mount) mount.title = mount.value ?? mount.textContent ?? '';
    }
    this.appliedProvider = view.provider;
    this.updateContinuityWarning();

    this.conversationRevision = nextRevision;
    const revision = this.contextPopover?.querySelector('[name="conversation_revision"]');
    if (revision) revision.value = String(nextRevision);
  }

  /// The continuity notice is a consequence of switching providers, not a
  /// standing caption: it appears only while the form's selection differs from
  /// the provider the conversation is actually on.
  updateContinuityWarning() {
    const warning = this.element.querySelector('#effective-context-continuity');
    const selected = this.element.querySelector('#effective-context-provider')?.value;
    if (!warning) return;
    warning.hidden = !selected || !this.appliedProvider || selected === this.appliedProvider;
  }

  handleContextDialogKeydown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closeContextPopover();
      return;
    }
    if (event.key !== 'Tab') return;
    const focusable = [...this.contextPopover.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')]
      .filter((element) => !element.disabled && !element.hidden);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  async handleVisibleReadBoundary() {
    if (document.visibilityState !== 'visible' || !this.sessionId || !this.conversationReady) return;
    const visible = [...this.element.querySelectorAll('[data-message-id]')].filter((message) => {
      const bounds = message.getBoundingClientRect();
      return bounds.bottom > 0 && bounds.top < globalThis.innerHeight;
    });
    const latest = visible.at(-1);
    if (!latest || latest.dataset.messageId === this.lastReadMessageId) return;
    let localDraftSessionIds = [];
    try {
      localDraftSessionIds = await conversationDraftSessionIds();
    } catch (_) {}
    fetch('/api/inbox/' + encodeURIComponent(this.sessionId) + '/read', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        conversation_revision: this.conversationRevision,
        visible_message_id: latest.dataset.messageId,
        foreground: true,
        local_draft_session_ids: localDraftSessionIds,
      }),
    }).then(async (response) => {
      if (!response.ok) return;
      const result = await response.json();
      this.lastReadMessageId = latest.dataset.messageId;
      this.conversationRevision = Number(result.conversation_revision || this.conversationRevision);
    }).catch(() => {});
  }

  initTextarea() {
    const textarea = this.textarea;
    if (!textarea) return;
    textarea.addEventListener('input', this.handleTextareaInput);
    textarea.addEventListener('keydown', this.handleTextareaKeydown);
  }

  handleTextareaInput() {
    const textarea = this.textarea;
    if (!textarea) return;
    textarea.style.height = 'auto';
    textarea.style.height = Math.min(textarea.scrollHeight, Math.max(96, (globalThis.innerHeight || 800) * 0.32)) + 'px';
    this.draftTouched = true;
    this.draftRevisionId = this.generateClientId();
    this.draftSubmissionId = this.generateClientId();
    this.hideRecovery();
    this.maybeOpenReferencePalette();
    this.updateSendState();
    this.scheduleDraftSave();
  }

  handleTextareaKeydown(event) {
    if (this.referencePalette && !this.referencePalette.hidden && this.handlePaletteKey(event)) return;
    if (event.isComposing) return;
    if (!(event.ctrlKey || event.metaKey) || event.key !== 'Enter') return;
    event.preventDefault();
    this.form?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  }

  /// One filled control. Idle it sends; while a turn runs its glyph becomes
  /// `stop` and it cancels, with Queue and the Steer menu beside it for the
  /// follow-up the user is typing.
  updateSendState() {
    const textarea = this.textarea;
    const button = this.sendButton;
    const hasInput = Boolean(textarea && (textarea.value.trim() || this.attachments.length || this.references.length));
    const richReady = !this.attachments.some((attachment) => attachment.state !== 'ready') &&
      !(textarea?.value || '').match(/(^|\s)@[\w./:-]+/);
    const online = typeof navigator === 'undefined' || navigator.onLine !== false;
    const submittable = hasInput && richReady && online && this.conversationReady && !this.chatRequestPending;
    const canQueue = this.streaming && this.ordinaryControls !== false;
    if (button) {
      if (this.streaming) {
        button.type = 'button';
        button.dataset.icon = 'stop';
        button.disabled = !this.canCancel;
        button.setAttribute('aria-label', 'Stop the current turn');
        button.title = 'Stop the current turn';
      } else {
        button.type = 'submit';
        button.dataset.icon = 'arrow-up';
        button.disabled = !submittable;
        button.setAttribute('aria-label', 'Send message');
        button.title = 'Send message';
      }
    }
    if (this.queueButton) {
      this.queueButton.hidden = !canQueue;
      this.queueButton.disabled = !submittable;
    }
    if (this.steerToggle) {
      this.steerToggle.hidden = !canQueue;
      this.steerToggle.disabled = !submittable || !this.canCancel;
    }
    if (this.steerButton) this.steerButton.disabled = !submittable || !this.canCancel;
    if (!canQueue) this.closeSteerMenu();
  }

  disableInput() {
    const textarea = this.textarea;
    if (textarea) {
      textarea.disabled = false;
      textarea.placeholder = 'Write the next message while the agent works…';
    }
    this.streaming = true;
    this.turnFinalized = false;
    document.body.classList.add('streaming');
    this.form?.classList.add('composer--streaming');
    this.closePalettes();
    this._startTurnStatusPolling();
    this.updateSendState();
  }

  enableInput() {
    this.streaming = false;
    if (this.textarea) this.textarea.disabled = false;
    this.handleViewportChange();
    document.body.classList.remove('streaming');
    this.form?.classList.remove('composer--streaming');
    this._stopTurnStatusPolling();
    this.updateSendState();
  }

  isChatFormRequest(event) {
    return event.detail?.ctx?.sourceElement?.id === 'chat-form';
  }

  handleBeforeRequest(event) {
    if (this.isChatFormRequest(event)) {
      if (!this.canSubmitRichInput()) {
        event.preventDefault();
        return;
      }
      this.chatRequestPending = true;
      this.submittedRevisionId = this.draftRevisionId;
      this.submittedDraft = this.currentDraft();
      if (this.submissionIdInput) this.submissionIdInput.value = this.submittedDraft.submissionId;
      if (this.revisionIdInput) this.revisionIdInput.value = this.submittedRevisionId;
      this.hideRecovery();
      beginSessionDraftMutation(this.sessionId);
      this.setSaveStatus('Submitting…', { transient: true });
      this.updateSendState();
    }
    if (event.detail?.ctx?.sourceElement?.id === 'messages') this.captureHistoryViewState();
  }

  handleFinallyRequest(event) {
    const ctx = event.detail?.ctx;
    if (this.isChatFormRequest(event)) {
      if (!this.chatRequestPending) return;
      this.chatRequestPending = false;
      endSessionDraftMutation(this.sessionId);
      if (ctx.status !== 'swapped' || ctx.response?.status >= 400) {
        this.setSaveStatus('Saved on this device', { transient: true });
        this.updateSendState();
        showBanner('error', readHtmxErrorMessage(ctx));
      } else {
        this.element.querySelector('#chat-empty-state')?.remove();
        this.acknowledgeSubmittedDraft();
        if (document.getElementById('streaming-msg')) {
          this.disableInput();
        } else {
          this.announce('Message queued');
          this.refreshConversationState();
        }
      }
      return;
    }

    const streamContentType = ctx?.response?.headers?.get('content-type') || '';
    if (ctx?.sourceElement?.id === 'streaming-msg' &&
        (!ctx.response || ctx.response.status >= 400 || !streamContentType.includes('text/event-stream'))) {
      const streamUrl = new URL(ctx.request.action, location.href);
      this.streamRecoveryTurnId = streamUrl.searchParams.get('turn');
      ctx.sourceElement.remove();
      this.showRecovery('Live response disconnected. Waiting for the active turn to finish.');
      return;
    }

    const elt = ctx?.sourceElement;
    if (!elt) return;
    const isMessagesReload = elt.id === 'messages';
    const isLoadEarlier = elt.matches && elt.matches('[data-load-earlier]');
    if (!isMessagesReload && !isLoadEarlier) return;
    if (isLoadEarlier) {
      elt.disabled = false;
      this.element.querySelector('[data-load-earlier-skeleton]')?.remove();
    }
    if (ctx.status !== 'swapped' || ctx.response?.status >= 400) {
      if (isLoadEarlier) {
        showBanner('error', readHtmxErrorMessage(ctx));
      }
      this.paginationAnchor = null;
      this.paginationAnchorTop = null;
      return;
    }
    this.updateMessagePagination(ctx);
    if (isMessagesReload) requestAnimationFrame(() => this.restoreHistoryViewState());
    if (isLoadEarlier && this.paginationAnchor?.isConnected && this.paginationAnchorTop !== null) {
      const messages = this.element.querySelector('#messages');
      const anchor = this.paginationAnchor;
      const anchorTop = this.paginationAnchorTop;
      requestAnimationFrame(() => {
        if (messages?.isConnected && anchor.isConnected) {
          messages.scrollTop += anchor.getBoundingClientRect().top - anchorTop;
        }
      });
    }
    this.paginationAnchor = null;
    this.paginationAnchorTop = null;
  }

  handleSendButtonClick(event) {
    if (this.streaming) {
      event.preventDefault();
      this.stopTurn();
      return;
    }
    if (!this.chatRequestPending) return;
    event.preventDefault();
  }

  stopTurn() {
    if (!this.sessionId) return;
    this.sendButton.disabled = true;
    this.announce('Stopping current turn');
    const sessionPath = '/api/sessions/' + encodeURIComponent(this.sessionId);
    fetch(sessionPath + '/turn-status')
      .then((response) => {
        if (!response.ok) throw new Error('Status failed');
        return response.json();
      })
      .then((status) => {
        if (!status.turn_id || status.can_cancel !== true) throw new Error('Turn is not cancellable');
        return fetch(sessionPath + '/turns/' + encodeURIComponent(status.turn_id) + '/cancel', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ reason: 'operator_cancel' }),
        });
      })
      .then((response) => {
        if (!response.ok) throw new Error('Stop failed');
        const deferEnableUntilRefresh = Boolean(this.streamRecoveryTurnId);
        this.showRecovery('Turn stopped. Pending messages are held.');
        this.finalizeTurn({ preserveInput: true, refreshMessages: true, deferEnableUntilRefresh });
      })
      .catch(() => {
        this.sendButton.disabled = false;
        showBanner('error', 'Failed to stop active turn');
      });
  }

  _startTurnStatusPolling() {
    this._stopTurnStatusPolling();
    this.canCancel = false;
    this.updateSendState();
    if (!this.sessionId) return;
    const generation = this.turnStatusPollGeneration;
    const sessionId = this.sessionId;
    let nextRequest = 0;
    let lastAppliedRequest = 0;
    const poll = () => {
      if (!this.streaming || this.turnStatusPollGeneration !== generation || this.sessionId !== sessionId) return;
      const request = ++nextRequest;
      fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/turn-status')
        .then((response) => (response.ok ? response.json() : null))
        .then((status) => {
          showToast('info', '', { sourceRef: 'chat-turn-status', recovered: true });
          if (!this.streaming || this.turnStatusPollGeneration !== generation || this.sessionId !== sessionId) return;
          if (request < lastAppliedRequest) return;
          lastAppliedRequest = request;
          if (this._reconcileStreamRecovery(status)) return;
          const next = Boolean(status && status.can_cancel === true);
          if (next !== this.canCancel) {
            this.canCancel = next;
            this.updateSendState();
          }
        })
        .catch(() => {
          showToast('error', 'Turn status updates are unavailable', {
            sourceRef: 'chat-turn-status',
            persistent: true,
          });
        });
    };
    poll();
    this.turnStatusTimer = setInterval(poll, 2500);
  }

  _reconcileStreamRecovery(status) {
    if (!this.streamRecoveryTurnId || status?.turn_id !== this.streamRecoveryTurnId) return false;
    if (!['completed', 'cancelled', 'failed'].includes(status.state)) return false;
    this.streamRecoveryTurnId = null;
    if (status.state === 'completed') {
      this.hideRecovery();
      this.finalizeTurn({ deferEnableUntilRefresh: true });
    } else {
      const message = status.state === 'cancelled'
        ? 'Turn stopped. Edit your message or send again.'
        : 'Turn failed after live updates disconnected. Edit your message or send again.';
      this.showRecovery(message);
      this.finalizeTurn({ preserveInput: true, deferEnableUntilRefresh: true });
    }
    return true;
  }

  _stopTurnStatusPolling() {
    this.turnStatusPollGeneration += 1;
    if (this.turnStatusTimer !== null) {
      clearInterval(this.turnStatusTimer);
      this.turnStatusTimer = null;
    }
    this.canCancel = false;
  }

  handleLoadEarlierClick(event) {
    const button = event.target.closest('[data-load-earlier]');
    if (!button) return;
    event.preventDefault();
    const earliestCursor = this.element.dataset.earliestCursor;
    if (!this.sessionId || !earliestCursor) return;
    button.disabled = true;
    const messages = document.getElementById('messages');
    this.paginationAnchor = messages?.querySelector('.msg') || null;
    this.paginationAnchorTop = this.paginationAnchor?.getBoundingClientRect().top ?? null;
    const loading = document.createElement('div');
    loading.className = 'skeleton skeleton-text';
    loading.dataset.loadEarlierSkeleton = '1';
    messages?.prepend(loading);
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html?before=' + earliestCursor, {
      target: '#messages',
      swap: 'afterbegin',
      source: button,
    });
  }

  handleHistoryClick(event) {
    const jump = event.target.closest('[data-jump-latest]');
    if (jump) {
      scrollToBottom(this.element, { force: true });
      jump.hidden = true;
      return;
    }
    const copy = event.target.closest('[data-copy-message]');
    if (copy) {
      const text = copy.closest('[data-message-id]')?.querySelector('.msg-content')?.textContent || '';
      navigator.clipboard?.writeText(text).then(() => {
        copy.dataset.icon = 'check';
        this.announce('Message copied');
        setTimeout(() => { if (copy.isConnected) copy.dataset.icon = 'copy'; }, 1200);
      }).catch(() => showToast('error', 'Could not copy message'));
      return;
    }
    const approval = event.target.closest('[data-approval-decision]');
    if (approval) {
      this.resolveHistoryApproval(approval);
      return;
    }
    const recovery = event.target.closest('[data-history-action]');
    if (recovery) this.runHistoryAction(recovery);
  }

  resolveHistoryApproval(button) {
    const card = button.closest('[data-approval-request-id]');
    const identity = card?.querySelector('[data-approval-attempt-id]');
    if (!card || !identity || !this.sessionId) return;
    card.querySelectorAll('button').forEach((control) => { control.disabled = true; });
    return fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/approvals/' +
      encodeURIComponent(card.dataset.approvalRequestId), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        decision: button.dataset.approvalDecision,
        attempt_id: identity.dataset.approvalAttemptId,
        turn_id: identity.dataset.approvalTurnId,
      }),
    }).then(async (response) => {
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload?.error?.message || 'Approval is unavailable');
      this.announce('Approval ' + payload.state);
      await this.refreshHistoryMessages();
    }).catch((error) => {
      this.showRecovery(error.message);
      this.refreshConversationState();
    });
  }

  async runHistoryAction(button) {
    const message = button.closest('[data-message-id]');
    if (!message || !this.sessionId) return;
    const action = button.dataset.historyAction;
    let editedMessage;
    if (action === 'edit') {
      editedMessage = await inputDialog({
        title: 'Edit and continue',
        body: 'The original conversation stays unchanged. Files and external effects are not rolled back.',
        inputLabel: 'Message',
        value: message.querySelector('.msg-content')?.textContent || '',
        confirmLabel: 'Continue',
      });
      if (!editedMessage?.trim()) return;
    } else {
      const confirmed = await confirmDialog({
        title: action === 'retry' ? 'Retry attempt?' : 'Fork from here?',
        body: action === 'retry'
          ? 'Retry starts a new attempt. External tool effects may repeat.'
          : 'Create linked conversation history? Files and external effects are not rolled back.',
        confirmLabel: action === 'retry' ? 'Retry' : 'Fork',
      });
      if (!confirmed) return;
    }
    const mutationId = this.generateClientId();
    const path = action === 'retry'
      ? '/api/sessions/' + encodeURIComponent(this.sessionId) + '/attempts/' +
        encodeURIComponent(button.dataset.sourceAttemptId) + '/retry'
      : '/api/sessions/' + encodeURIComponent(this.sessionId) + '/messages/' +
        encodeURIComponent(message.dataset.messageId) + '/branch';
    return fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(action === 'retry'
        ? { mutation_id: mutationId }
        : {
            mutation_id: mutationId,
            kind: action,
            message: editedMessage?.trim(),
            conversation_revision: this.conversationRevision,
          }),
    }).then(async (response) => {
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload?.error?.message || 'History action is unavailable');
      if (payload.destinationSessionId) {
        location.assign('/sessions/' + encodeURIComponent(payload.destinationSessionId));
      } else {
        this.refreshConversationState();
        return this.refreshHistoryMessages();
      }
    }).catch((error) => this.showRecovery(error.message));
  }

  refreshHistoryMessages() {
    if (!this.sessionId) return Promise.resolve();
    return htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html', {
      target: '#messages',
      swap: 'innerHTML',
      source: this.element.querySelector('#messages'),
    }).then(() => renderMarkdown(this.element));
  }

  captureHistoryViewState() {
    const messages = this.element.querySelector('#messages');
    if (!messages) return;
    const anchor = Array.from(messages.querySelectorAll('[data-message-id]'))
      .find((item) => item.getBoundingClientRect().bottom >= messages.getBoundingClientRect().top);
    this.historyViewState = {
      anchorId: anchor?.dataset.messageId || null,
      anchorOffset: anchor ? anchor.getBoundingClientRect().top - messages.getBoundingClientRect().top : 0,
      disclosures: Array.from(messages.querySelectorAll('details[open][data-tool-id]'))
        .map((item) => item.dataset.toolId),
      focus: this.captureHistoryFocus(),
      selection: this.captureHistorySelection(),
    };
  }

  restoreHistoryViewState() {
    const state = this.historyViewState;
    this.historyViewState = null;
    if (!state) return;
    for (const id of state.disclosures) {
      const detail = Array.from(this.element.querySelectorAll('details[data-tool-id]'))
        .find((item) => item.dataset.toolId === id);
      if (detail) detail.open = true;
    }
    const messages = this.element.querySelector('#messages');
    const anchor = Array.from(messages?.querySelectorAll('[data-message-id]') || [])
      .find((item) => item.dataset.messageId === state.anchorId);
    if (messages && anchor) messages.scrollTop += anchor.getBoundingClientRect().top -
      messages.getBoundingClientRect().top - state.anchorOffset;
    this.restoreHistoryFocus(state.focus);
    this.restoreHistorySelection(state.selection);
  }

  captureHistoryFocus() {
    const active = document.activeElement;
    const message = active?.closest?.('[data-message-id]');
    if (!message) return null;
    return {
      messageId: message.dataset.messageId,
      toolId: active.closest?.('[data-tool-id]')?.dataset.toolId || null,
      approvalId: active.closest?.('[data-approval-request-id]')?.dataset.approvalRequestId || null,
      historyAction: active.dataset?.historyAction || null,
      approvalDecision: active.dataset?.approvalDecision || null,
      copy: active.hasAttribute?.('data-copy-message') || false,
    };
  }

  restoreHistoryFocus(saved) {
    if (!saved) return;
    const message = Array.from(this.element.querySelectorAll('[data-message-id]'))
      .find((item) => item.dataset.messageId === saved.messageId);
    if (!message) return;
    let target = null;
    if (saved.toolId) {
      target = Array.from(message.querySelectorAll('[data-tool-id]'))
        .find((item) => item.dataset.toolId === saved.toolId)?.querySelector('summary');
    } else if (saved.approvalId) {
      const card = Array.from(message.querySelectorAll('[data-approval-request-id]'))
        .find((item) => item.dataset.approvalRequestId === saved.approvalId);
      target = saved.approvalDecision
        ? Array.from(card?.querySelectorAll('[data-approval-decision]') || [])
          .find((item) => item.dataset.approvalDecision === saved.approvalDecision)
        : card;
    } else if (saved.historyAction) {
      target = Array.from(message.querySelectorAll('[data-history-action]'))
        .find((item) => item.dataset.historyAction === saved.historyAction);
    } else if (saved.copy) {
      target = message.querySelector('[data-copy-message]');
    }
    target?.focus({ preventScroll: true });
  }

  captureHistorySelection() {
    const selection = window.getSelection?.();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    const content = range.commonAncestorContainer.parentElement?.closest?.('[data-message-id] .msg-content') ||
      range.commonAncestorContainer.closest?.('[data-message-id] .msg-content');
    const message = content?.closest('[data-message-id]');
    if (!content || !message || !content.contains(range.startContainer) || !content.contains(range.endContainer)) {
      return null;
    }
    const prefix = document.createRange();
    prefix.selectNodeContents(content);
    prefix.setEnd(range.startContainer, range.startOffset);
    const selected = document.createRange();
    selected.selectNodeContents(content);
    selected.setEnd(range.endContainer, range.endOffset);
    return { messageId: message.dataset.messageId, start: prefix.toString().length, end: selected.toString().length };
  }

  restoreHistorySelection(saved) {
    if (!saved) return;
    const message = Array.from(this.element.querySelectorAll('[data-message-id]'))
      .find((item) => item.dataset.messageId === saved.messageId);
    const content = message?.querySelector('.msg-content');
    if (!content) return;
    const positions = [];
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    let offset = 0;
    while (walker.nextNode()) {
      const node = walker.currentNode;
      positions.push({ node, start: offset, end: offset + node.data.length });
      offset += node.data.length;
    }
    const start = positions.find((item) => saved.start >= item.start && saved.start <= item.end);
    const end = positions.find((item) => saved.end >= item.start && saved.end <= item.end);
    if (!start || !end) return;
    const range = document.createRange();
    range.setStart(start.node, saved.start - start.start);
    range.setEnd(end.node, saved.end - end.start);
    const selection = window.getSelection?.();
    selection?.removeAllRanges();
    selection?.addRange(range);
  }

  storeHistoryViewState() {
    if (this.isTemporary) return;
    this.captureHistoryViewState();
    if (!this.historyViewState || !this.sessionId) return;
    sessionStorage.setItem('dartclaw:history:' + this.sessionId, JSON.stringify(this.historyViewState));
  }

  restoreStoredHistoryViewState() {
    if (this.isTemporary) return;
    if (!this.sessionId) return;
    const raw = sessionStorage.getItem('dartclaw:history:' + this.sessionId);
    if (!raw) return;
    try {
      this.historyViewState = JSON.parse(raw);
      requestAnimationFrame(() => this.restoreHistoryViewState());
    } catch (_) {
      sessionStorage.removeItem('dartclaw:history:' + this.sessionId);
    }
  }

  revealHistoryTarget() {
    const id = this.element.dataset.targetMessageId;
    if (!id) return;
    const target = Array.from(this.element.querySelectorAll('[data-message-id]'))
      .find((item) => item.dataset.messageId === id);
    if (!target) return;
    let focusTarget = target;
    if (location.hash.startsWith('#record-')) {
      try {
        const recordId = decodeURIComponent(location.hash.slice('#record-'.length));
        focusTarget = Array.from(target.querySelectorAll('[data-tool-id],[data-approval-request-id]'))
          .find((item) => item.dataset.toolId === recordId || item.dataset.approvalRequestId === recordId) || target;
      } catch (_) {}
    }
    focusTarget.tabIndex = -1;
    focusTarget.scrollIntoView({ block: 'center' });
    focusTarget.focus({ preventScroll: true });
  }

  updateMessagePagination(ctx) {
    const headers = ctx?.response?.headers;
    if (!headers) return;
    const earliestCursor = headers.get('x-dartclaw-earliest-cursor');
    if (earliestCursor) {
      this.element.dataset.earliestCursor = earliestCursor;
    } else {
      delete this.element.dataset.earliestCursor;
    }
    const button = this.element.querySelector('[data-load-earlier]');
    if (!button) return;
    const hasEarlierMessages = headers.get('x-dartclaw-has-earlier-messages') === 'true';
    button.hidden = !hasEarlierMessages;
    if (hasEarlierMessages) {
      button.removeAttribute('hidden');
    } else {
      button.setAttribute('hidden', 'hidden');
    }
  }

  handleSseBeforeMessage(event) {
    const message = event.detail?.message;
    if (event.target?.id !== 'streaming-msg' || !message) return;
    const stickToBottom = isAtBottom(this.element.querySelector('.messages'));
    event.detail.waitUntil(this.processSseMessage(event.target, message, stickToBottom));
  }

  async processSseMessage(sourceElement, message, stickToBottom) {
    if (!stickToBottom) {
      const activity = this.element.querySelector('[data-jump-latest]');
      if (activity) activity.hidden = false;
    }
    if (message.event === 'delta') {
      document.getElementById('streaming-msg')?.querySelector('.msg-thinking')?.remove();
      document.getElementById('streaming-content')?.classList.add('streaming');
      await htmx.swap({
        text: message.data,
        target: '#streaming-content',
        swap: 'beforeend',
        sourceElement,
      });
    } else if (message.event === 'tool_use') {
      await htmx.swap({
        text: message.data,
        target: '#tool-container',
        swap: 'beforeend',
        sourceElement,
      });
    } else if (message.event === 'tool_result') {
      await htmx.swap({
        text: message.data,
        target: '#tool-container',
        swap: 'none',
        sourceElement,
      });
    } else if (message.event === 'turn_cancelled') {
      this.handleTurnCancelled();
    } else if (message.event === 'turn_error') {
      await htmx.swap({
        text: message.data,
        target: '#turn-error-target',
        swap: 'innerHTML',
        sourceElement,
      });
      this.handleTurnError();
    }
    scrollToBottom(this.element, { stickToBottom });
  }

  handleTurnCancelled() {
    this.showRecovery('Turn stopped. Edit your message or send again.');
  }

  handleSseClose(event) {
    if (event.detail?.reason !== 'message') return;
    this.finalizeTurn({ preserveInput: this.recoveryActive });
  }

  handleTurnError() {
    const container = document.getElementById('turn-error-target');
    const turnError = container && container.querySelector('.turn-error');
    const message = turnError ? turnError.textContent : 'Stream error';
    if (container) container.innerHTML = '';
    this.showRecovery(message + ' Retry by editing and sending again.');
  }

  finalizeTurn(options = {}) {
    if (this.turnFinalized) return;
    this.turnFinalized = true;
    this.streamRecoveryTurnId = null;
    const refreshMessages = options.refreshMessages !== false;
    const deferEnableUntilRefresh = Boolean(options.deferEnableUntilRefresh);
    document.body.classList.remove('streaming');
    document.getElementById('streaming-content')?.classList.remove('streaming');
    if (!deferEnableUntilRefresh) this.enableInput();
    if (!this.sessionId || !refreshMessages) {
      if (deferEnableUntilRefresh) this.enableInput();
      return;
    }

    const stickToBottom = isAtBottom(this.element.querySelector('.messages'));
    htmx.ajax('GET', '/sessions/' + encodeURIComponent(this.sessionId) + '/messages-html', {
      target: '#messages',
      swap: 'innerHTML',
      source: this.element.querySelector('#messages'),
    })
      .then(() => {
        renderMarkdown(this.element);
        scrollToBottom(this.element, { stickToBottom });
      })
      .catch(() => showToast('error', 'Failed to refresh messages'))
      .finally(() => {
        if (deferEnableUntilRefresh && this.element.isConnected) this.enableInput();
      });
  }

  maybeOpenReferencePalette() {
    const value = this.textarea?.value || '';
    const cursor = this.textarea?.selectionStart || value.length;
    const prefix = value.slice(0, cursor).split(/\s/).pop() || '';
    if (!prefix.startsWith('@')) {
      this.hideReferencePalette();
      return;
    }
    const query = prefix.slice(1);
    this.loadReferences(query);
  }

  loadReferences(query) {
    if (!this.sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/references?q=' + encodeURIComponent(query))
      .then((response) => response.ok ? response.json() : { references: [] })
      .then((payload) => {
        this.filteredReferences = Array.isArray(payload.references) ? payload.references : [];
        this.activeReferenceIndex = 0;
        this.renderReferencePalette();
      })
      .catch(() => {
        this.filteredReferences = [{ type: 'unresolved', id: query, label: query || 'No match', state: 'unresolved' }];
        this.renderReferencePalette();
      });
  }

  renderReferencePalette() {
    const palette = this.referencePalette;
    const list = palette?.querySelector('.composer-palette-list');
    if (!palette || !list) return;
    if (this.filteredReferences.length === 0) {
      list.innerHTML = '<div class="composer-palette-empty">No references found. Keep typing or remove the token.</div>';
      palette.hidden = false;
      return;
    }
    list.innerHTML = this.filteredReferences.map((reference, index) => {
      const selected = index === this.activeReferenceIndex ? ' aria-selected="true"' : '';
      return '<button type="button" role="option" class="composer-palette-option"' + selected +
        ' data-reference-index="' + index + '">' +
        '<span>@' + escapeHtml(reference.label || reference.id || '') + '</span>' +
        '<small>' + escapeHtml(reference.type || 'reference') + '</small>' +
        '</button>';
    }).join('');
    list.querySelectorAll('[data-reference-index]').forEach((button) => {
      button.addEventListener('click', () => this.selectReference(Number(button.dataset.referenceIndex)));
    });
    palette.hidden = false;
  }

  hideReferencePalette() {
    if (this.referencePalette) this.referencePalette.hidden = true;
  }

  handlePaletteKey(event) {
    const items = this.filteredReferences;
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closePalettes();
      return true;
    }
    if (!items.length) return false;
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      this.activeReferenceIndex = (this.activeReferenceIndex + delta + items.length) % items.length;
      this.renderReferencePalette();
      return true;
    }
    if (event.key === 'Enter' || event.key === 'Tab') {
      event.preventDefault();
      this.selectReference(this.activeReferenceIndex);
      return true;
    }
    return false;
  }

  selectReference(index) {
    const reference = this.filteredReferences[index];
    if (!reference) return;
    this.references.push({ type: reference.type, id: reference.id, label: reference.label, state: 'resolved' });
    this.replaceCurrentToken('');
    this.hideReferencePalette();
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  replaceCurrentToken(replacement) {
    const textarea = this.textarea;
    if (!textarea) return;
    const value = textarea.value;
    const cursor = textarea.selectionStart || value.length;
    const before = value.slice(0, cursor);
    const after = value.slice(cursor);
    const tokenStart = Math.max(before.lastIndexOf(' ') + 1, before.lastIndexOf('\n') + 1);
    textarea.value = before.slice(0, tokenStart) + replacement + after;
    const nextCursor = tokenStart + replacement.length;
    textarea.setSelectionRange(nextCursor, nextCursor);
    textarea.focus();
  }

  applySuggestion(event) {
    const text = event.currentTarget?.dataset.text;
    if (!text || !this.textarea) return;
    const spacer = this.textarea.value.trim() ? '\n' : '';
    this.textarea.value += spacer + text;
    this.textarea.focus();
    this.updateSendState();
    this.markDraftChanged();
  }

  closePalettes() {
    this.hideReferencePalette();
  }

  handleDragOver(event) {
    event.preventDefault();
  }

  handleDrop(event) {
    event.preventDefault();
    this.addFiles(event.dataTransfer?.files);
  }

  handlePaste(event) {
    this.addFiles(event.clipboardData?.files);
  }

  addFiles(fileList) {
    const files = Array.from(fileList || []);
    files.forEach((file) => this.uploadAttachment(file));
  }

  chooseFiles(event) {
    this.addFiles(event.currentTarget?.files);
    if (event.currentTarget) event.currentTarget.value = '';
  }

  uploadAttachment(file) {
    if (!file || !this.sessionId) return;
    if (this.maxAttachmentBytes > 0 && file.size > this.maxAttachmentBytes) {
      this.showRecovery('Attachment exceeds the server limit. Remove it or choose a smaller file.');
      return;
    }
    const pendingId = 'pending-' + this.generateClientId();
    const pending = {
      id: pendingId,
      filename: file.name,
      mediaType: file.type || 'application/octet-stream',
      size: file.size,
      state: 'uploading',
      file,
    };
    this.attachments.push(pending);
    this.syncRichInputs();
    this.markDraftChanged();
    this.readFileBase64(file)
      .then((contentBase64) => fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          filename: file.name,
          mediaType: file.type || 'application/octet-stream',
          size: file.size,
          contentBase64,
        }),
      }))
      .then((response) => {
        if (!response.ok) throw new Error('Upload failed');
        return response.json();
      })
      .then((attachment) => {
        this.attachments = this.attachments.map((item) => item.id === pendingId ? { ...attachment, file } : item);
        this.syncRichInputs();
        this.markDraftChanged();
      })
      .catch(() => {
        this.attachments = this.attachments.map((item) => item.id === pendingId ? { ...item, state: 'failed' } : item);
        this.syncRichInputs();
        this.markDraftChanged();
      });
  }

  initializeConversationState() {
    if (!this.sessionId) return;
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments/limits')
      .then((response) => response.ok ? response.json() : null)
      .then((limits) => {
        if (Number.isInteger(limits?.max_attachment_bytes)) this.maxAttachmentBytes = limits.max_attachment_bytes;
      })
      .catch(() => {});
    this.refreshConversationState();
  }

  handleConversationChanged(event) {
    if (event.detail?.session_id !== this.sessionId) return;
    const revision = Number(event.detail?.revision || 0);
    if (!event.detail?.turn_id && revision <= this.conversationRevision) return;
    this.refreshConversationState();
  }

  refreshConversationState() {
    if (!this.sessionId) return Promise.resolve();
    return fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/conversation-state')
      .then((response) => {
        if (response.status === 401 || response.status === 403) {
          document.body.dispatchEvent(new CustomEvent('dartclaw:authorization-revoked'));
          throw new Error('Conversation access was revoked');
        }
        if (!response.ok) throw new Error('Conversation state unavailable');
        return response.json();
      })
      .then((snapshot) => {
        if (Number(snapshot.revision || 0) < this.conversationRevision) return;
        this.conversationRevision = Number(snapshot.revision || 0);
        this.reconcileContext(snapshot);
        this.conversationReady = true;
        this.renderQueue(Array.isArray(snapshot.queue) ? snapshot.queue : []);
        this.renderRequestStrip(Array.isArray(snapshot.records) ? snapshot.records : []);
        const projectedTurn = snapshot.activity?.turn;
        this.ordinaryControls = snapshot.activity?.ordinary_controls !== false;
        const recovery = (snapshot.submissions || []).find((item) =>
          item.commitState === 'integrityFailed' || item.workState === 'uncertain');
        if (recovery) {
          this.showRecovery(recovery.commitState === 'integrityFailed'
            ? 'Submission integrity could not be recovered. Review the held message before sending again.'
            : 'Dispatch status is uncertain after restart. Review the conversation before sending again.');
        }
        const active = (snapshot.submissions || []).find((item) =>
          ['dispatching', 'running', 'stopping'].includes(item.workState));
        const projectedActive = projectedTurn && ['running', 'waiting', 'stuck', 'cancelling'].includes(projectedTurn.state);
        if (active || projectedActive) {
          this.streaming = true;
          this.canCancel = Boolean(projectedTurn?.can_cancel) && active?.workState !== 'stopping';
          this.activeTurnId = active?.turnId || projectedTurn?.turn_id || null;
        } else if (!document.getElementById('streaming-msg')) {
          this.streaming = false;
          this.canCancel = false;
          this.activeTurnId = null;
        }
        this.updateSendState();
        this.handleVisibleReadBoundary();
      })
      .catch((error) => {
        this.conversationReady = false;
        this.setSaveStatus(navigator.onLine === false ? 'Offline — draft stays on this device' : 'Conversation unavailable');
        this.showRecovery(error.message);
        this.updateSendState();
      });
  }

  /// One compact row per pending turn, stacked above the composer. Release is
  /// offered on the oldest held item only — it sends the next queued message,
  /// which is a queue-level action, not a per-row one.
  renderQueue(items) {
    const queue = this.queue;
    if (!queue) return;
    const pending = items.filter((item) => ['queued', 'held'].includes(item.workState));
    this.queueItems = new Map(pending.map((item) => [item.queueId, item]));
    queue.hidden = pending.length === 0;
    const firstHeld = pending.findIndex((item) => item.workState === 'held');
    queue.innerHTML = pending.map((item, index) => {
      const held = item.workState === 'held';
      const files = (item.attachments || []).map((attachment) => attachment.filename).join(', ');
      const title = files ? ' title="' + escapeHtml(item.message + ' · files: ' + files) + '"' : '';
      const release = held && index === firstHeld
        ? '<button type="button" class="btn btn-sm" data-action="dc-chat#releaseQueueItem" ' +
          'title="Send next queued message" aria-label="Send next queued message">Release</button>'
        : '';
      return '<div class="queue-row' + (held ? ' queue-row--held' : '') + '" data-queue-id="' +
        escapeHtml(item.queueId) + '"' + title + '>' +
        '<span class="queue-label">' + (held ? 'Held' : 'Queued') + '</span>' +
        '<span class="queue-text">' + escapeHtml(item.message) + '</span>' + release +
        '<button type="button" class="btn btn-icon-sm" data-icon="pencil" aria-label="Edit queued turn" ' +
        'title="Edit" data-action="dc-chat#editQueueItem"></button>' +
        '<button type="button" class="btn btn-icon-sm" data-icon="x" aria-label="' +
        (held ? 'Discard held turn' : 'Remove from queue') + '" title="Remove" ' +
        'data-action="dc-chat#removeQueueItem"></button>' +
        '</div>';
    }).join('');
  }

  /// A notice plus a jump, never a shortcut past reading the request: the
  /// verdict stays on the approval card the strip points at (PRD E4).
  renderRequestStrip(records) {
    const strip = this.requestStrip;
    if (!strip) return;
    const pending = records.find((record) => record.kind === 'approval' && record.state === 'pending');
    strip.hidden = !pending;
    if (!pending) {
      strip.replaceChildren();
      return;
    }
    strip.innerHTML = '<span class="icon icon-shield-alert" aria-hidden="true"></span>' +
      '<span>Waiting on you — <code>' + escapeHtml(pending.label || 'approval required') + '</code></span>' +
      '<span class="strip-actions"><button type="button" class="btn btn-sm" ' +
      'data-action="dc-chat#reviewRequest" data-request-id="' + escapeHtml(pending.id) + '">Review</button></span>';
  }

  reviewRequest(event) {
    const id = event.currentTarget?.dataset.requestId;
    const card = [...this.element.querySelectorAll('[data-approval-request-id]')]
      .find((item) => item.dataset.approvalRequestId === id);
    if (!card) return;
    card.scrollIntoView({ block: 'center' });
    card.focus({ preventScroll: true });
  }

  queueMutation(path, options) {
    return fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + path, options)
      .then(async (response) => {
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload?.error?.message || payload?.message || 'Queue changed in another view');
        await this.refreshConversationState();
        return payload;
      })
      .catch((error) => {
        this.showRecovery(error.message);
        return this.refreshConversationState();
      });
  }

  async editQueueItem(event) {
    const item = event.currentTarget?.closest('[data-queue-id]');
    if (!item) return;
    const queueId = item.dataset.queueId;
    const queued = this.queueItems.get(queueId);
    const replacement = await inputDialog({
      title: 'Edit queued message',
      inputLabel: 'Message',
      value: queued?.message || '',
      confirmLabel: 'Save',
    });
    if (replacement === null || !replacement.trim()) return;
    this.queueMutation('/queue/' + encodeURIComponent(queueId), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        conversation_revision: this.conversationRevision,
        revision_id: this.generateClientId(),
        message: replacement.trim(),
        attachments: queued?.attachments || [],
        references: queued?.references || [],
      }),
    });
  }

  removeQueueItem(event) {
    const queueId = event.currentTarget?.closest('[data-queue-id]')?.dataset.queueId;
    if (!queueId) return;
    this.queueMutation('/queue/' + encodeURIComponent(queueId), {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversation_revision: this.conversationRevision }),
    });
  }

  releaseQueueItem() {
    this.queueMutation('/queue/release', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversation_revision: this.conversationRevision }),
    });
  }

  steer() {
    if (!this.canSubmitRichInput() || !this.textarea?.value.trim() || !this.canCancel || !this.activeTurnId) return;
    const draft = this.currentDraft();
    this.chatRequestPending = true;
    this.submittedRevisionId = draft.revisionId;
    this.submittedDraft = draft;
    this.announce('Stopping current turn before sending follow-up');
    this.updateSendState();
    fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/steer', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        submission_id: draft.submissionId,
        revision_id: draft.revisionId,
        turn_id: this.activeTurnId,
        conversation_revision: this.conversationRevision,
        message: draft.text.trim(),
        attachments: draft.attachments.filter((item) => item.state === 'ready'),
        references: draft.references,
      }),
    })
      .then(async (response) => {
        if (!response.ok) throw new Error((await response.json().catch(() => null))?.error?.message || 'Steer failed');
        this.acknowledgeSubmittedDraft();
        this.disableInput();
        this.announce('Follow-up accepted after the current turn stopped');
      })
      .catch((error) => this.showRecovery(error.message))
      .finally(() => {
        this.chatRequestPending = false;
        this.updateSendState();
        this.refreshConversationState();
      });
  }

  // --- Find in conversation -------------------------------------------------
  // Occurrences inside loaded messages are marked and stepped through in place.
  // The conversation-search service is still consulted, because it is the only
  // thing that knows about matches on pages this view has not loaded (PRD E7);
  // those remain message-level stops that navigate.

  openFind() {
    const bar = this.findBar;
    if (!bar) return;
    bar.hidden = false;
    this.findQuery?.focus();
    this.findQuery?.select();
    if (this.findQuery?.value.trim()) this.runFind();
  }

  closeFind() {
    if (this.findBar) this.findBar.hidden = true;
    this.clearFindMarks();
    this.findStops = [];
    this.findIndex = 0;
    this.findGeneration = (this.findGeneration || 0) + 1;
    this.setFindCount('');
    this.textarea?.focus();
  }

  findInput() {
    clearTimeout(this.findTimer);
    this.findTimer = setTimeout(() => this.runFind(), 180);
  }

  findKeydown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.closeFind();
      return;
    }
    if (event.key !== 'Enter') return;
    event.preventDefault();
    if (event.shiftKey) this.findPrevious(); else this.findNext();
  }

  /// Unwraps every mark this bar added, restoring the original text nodes.
  clearFindMarks() {
    for (const mark of [...this.element.querySelectorAll('mark.find-hit')]) {
      const parent = mark.parentNode;
      if (!parent) continue;
      parent.replaceChild(document.createTextNode(mark.textContent), mark);
      parent.normalize();
    }
  }

  /// Wraps each occurrence in the loaded transcript. Text nodes only, so no
  /// attribute value and no element the markup owns can be split; code blocks
  /// are skipped because their spans are the highlighter's, not the text's.
  markFindOccurrences(needle) {
    const marks = [];
    for (const content of this.element.querySelectorAll('.messages .msg-content')) {
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) =>
          node.data.toLowerCase().includes(needle) && !node.parentElement?.closest('pre')
            ? NodeFilter.FILTER_ACCEPT
            : NodeFilter.FILTER_REJECT,
      });
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      for (const node of nodes) marks.push(...this.markTextNode(node, needle));
    }
    return marks;
  }

  markTextNode(node, needle) {
    const text = node.data;
    const lower = text.toLowerCase();
    const marks = [];
    const fragment = document.createDocumentFragment();
    let cursor = 0;
    for (let index = lower.indexOf(needle); index >= 0; index = lower.indexOf(needle, cursor)) {
      if (index > cursor) fragment.appendChild(document.createTextNode(text.slice(cursor, index)));
      const mark = document.createElement('mark');
      mark.className = 'find-hit';
      mark.textContent = text.slice(index, index + needle.length);
      fragment.appendChild(mark);
      marks.push(mark);
      cursor = index + needle.length;
    }
    if (!marks.length) return marks;
    if (cursor < text.length) fragment.appendChild(document.createTextNode(text.slice(cursor)));
    node.parentNode?.replaceChild(fragment, node);
    return marks;
  }

  runFind() {
    const query = this.findQuery?.value.trim() || '';
    const generation = (this.findGeneration = (this.findGeneration || 0) + 1);
    this.clearFindMarks();
    this.findStops = [];
    this.findIndex = 0;
    this.findTruncated = false;
    if (!query || !this.sessionId) {
      this.setFindCount('');
      return;
    }

    // Local occurrences are known without asking anyone, so they are marked and
    // counted before the request goes out.
    const marks = this.markFindOccurrences(query.toLowerCase());
    this.findStops = marks.map((mark) => ({ mark }));
    if (this.findStops.length) this.revealFindMatch();
    else this.setFindCount('Searching…');

    const parameters = new URLSearchParams({
      q: query,
      scope: 'current',
      lifecycle: 'all',
      limit: '100',
      session_id: this.sessionId,
      request_token: String(generation),
    });
    fetch('/api/conversation-search?' + parameters.toString())
      .then((response) => response.ok ? response.json() : Promise.reject(new Error('unavailable')))
      .then((payload) => {
        if (generation !== this.findGeneration) return;
        const results = Array.isArray(payload.results) ? payload.results : [];
        // A hit whose message is on screen is already covered by its own
        // occurrences; only the unloaded ones become extra stops.
        const loaded = new Set(
          [...this.element.querySelectorAll('[data-message-id]')].map((item) => item.dataset.messageId),
        );
        const remote = results.filter((hit) => !loaded.has(hit.message_id));
        this.findTruncated = Number(payload.total || 0) > results.length;
        this.findStops = [...this.findStops, ...remote.map((hit) => ({ hit }))];
        if (!this.findStops.length) {
          this.setFindCount('No matches');
          return;
        }
        this.revealFindMatch();
      })
      .catch(() => {
        if (generation !== this.findGeneration) return;
        // Local occurrences still stand; only the unloaded pages are unknown.
        if (!this.findStops.length) this.setFindCount('Search unavailable');
        else this.revealFindMatch();
      });
  }

  findNext() {
    if (!this.findStops?.length) return;
    this.findIndex = (this.findIndex + 1) % this.findStops.length;
    this.revealFindMatch();
  }

  findPrevious() {
    if (!this.findStops?.length) return;
    this.findIndex = (this.findIndex - 1 + this.findStops.length) % this.findStops.length;
    this.revealFindMatch();
  }

  revealFindMatch() {
    const stop = this.findStops[this.findIndex];
    this.setFindCount((this.findIndex + 1) + ' of ' + this.findStops.length + (this.findTruncated ? '+' : ''));
    if (!stop) return;
    this.element.querySelectorAll('mark.find-hit--active')
      .forEach((mark) => mark.classList.remove('find-hit--active'));
    if (stop.mark?.isConnected) {
      stop.mark.classList.add('find-hit--active');
      stop.mark.scrollIntoView({ block: 'center' });
      return;
    }
    // A match on a page this view has not loaded: the hit's own href re-renders
    // the transcript around it.
    if (stop.hit?.href) location.assign(stop.hit.href);
  }

  setFindCount(text) {
    if (this.findCount) this.findCount.textContent = text;
  }

  handleConnectivityChange() {
    if (navigator.onLine === false) {
      this.setSaveStatus('Offline — draft stays on this device');
      this.announce('Disconnected. Drafting remains available.');
      this.updateSendState();
      return;
    }
    this.announce('Reconnected. Review your draft before sending.');
    this.saveDraftNow();
    this.refreshConversationState();
  }

  currentDraft() {
    return {
      key: this.draftKey,
      submissionId: this.draftSubmissionId || (this.draftSubmissionId = this.generateClientId()),
      revisionId: this.draftRevisionId,
      text: this.textarea?.value || '',
      references: this.references.map((item) => ({ ...item })),
      attachments: this.attachments.map((item) => ({ ...item })),
      updatedAt: Date.now(),
    };
  }

  markDraftChanged() {
    this.draftTouched = true;
    this.draftRevisionId = this.generateClientId();
    this.draftSubmissionId = this.generateClientId();
    this.scheduleDraftSave();
  }

  scheduleDraftSave() {
    clearTimeout(this.saveTimer);
    this.setSaveStatus('Saving…', { transient: true });
    this.saveTimer = setTimeout(() => this.saveDraftNow(), 150);
  }

  initializeDraftStorage() {
    if (this.isTemporary) {
      this.draftKey = this.sessionId;
      const draft = temporaryDrafts.get(this.draftKey);
      if (draft) this.applyStoredDraft(draft);
      this.setSaveStatus('Held until this page closes');
      return;
    }
    let instanceId;
    try {
      instanceId = localStorage.getItem('dartclaw.instance-id');
      if (!instanceId) {
        instanceId = this.generateClientId();
        localStorage.setItem('dartclaw.instance-id', instanceId);
      }
    } catch (_) {
      instanceId = 'local';
    }
    this.provisionalDraftKey = instanceId + ':provisional';
    this.draftKey = instanceId + ':' + (this.sessionId || 'provisional');
    if (typeof BroadcastChannel === 'function') {
      this.draftChannel = new BroadcastChannel('dartclaw-drafts');
      this.draftChannel.onmessage = (event) => this.receiveDraftUpdate(event.data);
    }
    this.openDraftDb()
      .then((db) => {
        this.draftDb = db;
        return this.readStoredDraft();
      })
      .then((draft) => {
        if (draft) this.applyStoredDraft(draft);
        this.setSaveStatus(draft ? 'Draft restored' : '', { transient: true });
        this.updateSendState();
      })
      .catch(() => this.showDraftSaveFailure());
  }

  openDraftDb() {
    return openConversationDraftDb();
  }

  draftRequest(mode, operation) {
    if (!this.draftDb) return Promise.reject(new Error('Draft storage unavailable'));
    return new Promise((resolve, reject) => {
      const transaction = this.draftDb.transaction('drafts', mode);
      const request = operation(transaction.objectStore('drafts'));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      transaction.onabort = () => reject(transaction.error);
    });
  }

  readStoredDraft() {
    return this.draftRequest('readonly', (store) => store.get(this.draftKey))
      .then((draft) => draft || this.transferProvisionalDraft());
  }

  transferProvisionalDraft() {
    if (!this.sessionId || this.draftKey === this.provisionalDraftKey || !this.draftDb) return Promise.resolve(null);
    return new Promise((resolve, reject) => {
      const transaction = this.draftDb.transaction('drafts', 'readwrite');
      const store = transaction.objectStore('drafts');
      const request = store.get(this.provisionalDraftKey);
      let transferred = null;
      request.onsuccess = () => {
        if (!request.result) return;
        transferred = { ...request.result, key: this.draftKey };
        store.put(transferred);
        store.delete(this.provisionalDraftKey);
      };
      request.onerror = () => reject(request.error);
      transaction.oncomplete = () => resolve(transferred);
      transaction.onabort = () => reject(transaction.error);
    });
  }

  saveDraftNow() {
    clearTimeout(this.saveTimer);
    const draft = this.currentDraft();
    if (this.isTemporary) {
      temporaryDrafts.set(this.draftKey, draft);
      this.setSaveStatus('Held until this page closes');
      return Promise.resolve();
    }
    return this.draftRequest('readwrite', (store) => store.put(draft))
      .then(() => {
        this.setSaveStatus('Saved on this device', { transient: true });
        this.hideDraftRecoveryActions();
        this.draftChannel?.postMessage({ key: draft.key, revisionId: draft.revisionId, updatedAt: draft.updatedAt });
      })
      .catch(() => this.showDraftSaveFailure());
  }

  showDraftSaveFailure() {
    this.setSaveStatus('Unsaved — this draft will not recover after reload', { failed: true });
    this.showRecovery('Could not save this draft on this device. Keep editing, retry, copy, or download it.');
    if (this.recoveryActions) this.recoveryActions.hidden = false;
  }

  hideDraftRecoveryActions() {
    if (!this.recoveryActions || this.pendingConflict) return;
    this.recoveryActions.hidden = true;
  }

  receiveDraftUpdate(update) {
    if (!update || update.key !== this.draftKey || update.revisionId === this.draftRevisionId) return;
    this.readStoredDraft().then((draft) => {
      if (!draft) return;
      if (this.draftTouched) {
        this.pendingConflict = draft;
        // An unresolved conflict outlives any save report, so it holds the row.
        this.setSaveStatus('Conflicting draft in another tab', { failed: true });
        this.showRecovery('Another tab saved a different revision. Recover it or keep your current draft.');
        if (this.recoveryActions) this.recoveryActions.hidden = false;
        if (this.conflictAction) this.conflictAction.hidden = false;
      } else {
        this.applyStoredDraft(draft);
      }
    }).catch(() => {});
  }

  recoverConflictingDraft() {
    if (!this.pendingConflict) return;
    this.applyStoredDraft(this.pendingConflict);
    this.pendingConflict = null;
    if (this.conflictAction) this.conflictAction.hidden = true;
    this.setSaveStatus('Draft restored', { transient: true });
    this.hideRecovery();
    this.hideDraftRecoveryActions();
  }

  applyStoredDraft(draft) {
    if (this.textarea) this.textarea.value = draft.text || '';
    this.references = Array.isArray(draft.references) ? draft.references : [];
    this.attachments = Array.isArray(draft.attachments) ? draft.attachments : [];
    this.draftRevisionId = draft.revisionId || this.generateClientId();
    this.draftSubmissionId = draft.submissionId || this.generateClientId();
    this.draftTouched = false;
    const localAttachments = this.sessionId
      ? this.attachments.filter((attachment) => attachment.state === 'local' && attachment.file)
      : [];
    if (localAttachments.length > 0) {
      this.attachments = this.attachments.filter((attachment) => !localAttachments.includes(attachment));
      localAttachments.forEach((attachment) => this.uploadAttachment(attachment.file));
    }
    this.syncRichInputs();
  }

  acknowledgeSubmittedDraft() {
    if (!this.submittedDraft) return;
    if (this.draftRevisionId === this.submittedRevisionId) {
      if (this.textarea) this.textarea.value = '';
      this.attachments = [];
      this.references = [];
      this.syncRichInputs();
      this.draftRevisionId = this.generateClientId();
      this.draftSubmissionId = this.generateClientId();
      this.draftTouched = false;
      this.saveDraftNow();
    } else {
      this.saveDraftNow();
    }
    this.submittedDraft = null;
    this.submittedRevisionId = null;
    this.setSaveStatus('Saved on this device', { transient: true });
  }

  copyDraft() {
    const text = this.textarea?.value || '';
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text);
  }

  downloadDraft() {
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([this.textarea?.value || ''], { type: 'text/plain' }));
    link.download = 'dartclaw-draft.txt';
    link.click();
    URL.revokeObjectURL(link.href);
  }

  /// The status is text inside the toolbar row and a glyph carrying the same
  /// label at the touch tier, where the text would cost the model pill its
  /// width. Nothing renders below the composer box.
  ///
  /// At rest it says nothing: a composer with no draft and nothing to report is
  /// not a status, and a standing "No saved draft" is chrome the reader has to
  /// re-read every time. A save in flight or just landed shows and fades; a
  /// failure, a conflict or a degraded retention state stays until it clears.
  setSaveStatus(message, { failed = false, transient = false } = {}) {
    clearTimeout(this.saveStatusTimer);
    this.applySaveStatus(message, failed);
    if (!transient || !message) return;
    this.saveStatusTimer = setTimeout(() => this.applySaveStatus('', false), 2000);
  }

  applySaveStatus(message, failed) {
    const status = this.saveStatus;
    if (status) {
      // The element stays in the DOM and keeps its role="status": clearing the
      // text is what hides it, and an aria-live region that is removed stops
      // announcing the next save.
      status.textContent = message;
      status.classList.toggle('composer-save--error', failed && Boolean(message));
    }
    const glyph = this.saveGlyph;
    if (glyph) {
      glyph.hidden = !message;
      glyph.dataset.icon = failed ? 'triangle-alert' : 'check';
      glyph.title = message;
      glyph.setAttribute('aria-label', message);
      glyph.classList.toggle('composer-save--error', failed && Boolean(message));
    }
  }

  announce(message) {
    if (this.liveStatus) this.liveStatus.textContent = message;
  }

  generateClientId() {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
      return globalThis.crypto.randomUUID();
    }
    return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
  }

  readFileBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || '');
        resolve(result.includes(',') ? result.split(',').pop() : result);
      };
      reader.onerror = () => reject(reader.error || new Error('File read failed'));
      reader.readAsDataURL(file);
    });
  }

  removeAttachment(event) {
    const id = event.currentTarget?.dataset.attachmentId;
    const attachment = this.attachments.find((item) => item.id === id);
    this.attachments = this.attachments.filter((item) => item.id !== id);
    if (attachment && !String(id).startsWith('pending-') && this.sessionId) {
      fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/attachments/' + encodeURIComponent(id), { method: 'DELETE' }).catch(() => {});
    }
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  removeReference(event) {
    const id = event.currentTarget?.dataset.referenceId;
    this.references = this.references.filter((reference) => reference.id !== id);
    this.syncRichInputs();
    this.updateSendState();
    this.markDraftChanged();
  }

  retryAttachment(event) {
    const id = event.currentTarget?.dataset.attachmentId;
    const attachment = this.attachments.find((item) => item.id === id);
    if (!attachment?.file) return;
    this.attachments = this.attachments.filter((item) => item.id !== id);
    this.syncRichInputs();
    this.uploadAttachment(attachment.file);
  }

  syncRichInputs() {
    if (this.attachmentsInput) {
      this.attachmentsInput.value = JSON.stringify(this.attachments.filter((attachment) => attachment.state === 'ready'));
    }
    if (this.referencesInput) {
      this.referencesInput.value = JSON.stringify(this.references.filter((reference) => reference.state === 'resolved'));
    }
    const tray = this.contextTray;
    if (!tray) return;
    const chips = [
      ...this.attachments.map((attachment) => this.renderAttachmentChip(attachment)),
      ...this.references.map((reference) => this.renderReferenceChip(reference)),
    ];
    tray.innerHTML = chips.join('');
    tray.hidden = chips.length === 0;
  }

  /// A failed upload is a state of its own chip, not a second chip beside it:
  /// the retry has to sit on the file it retries.
  renderAttachmentChip(attachment) {
    const failed = attachment.state === 'failed';
    const id = escapeHtml(attachment.id);
    const retry = failed
      ? '<button type="button" class="chip-action" data-action="dc-chat#retryAttachment" ' +
        'data-attachment-id="' + id + '">Retry</button>'
      : '';
    return '<span class="chip">' +
      '<span class="chip-name">' + escapeHtml(attachment.filename) + '</span>' +
      '<span class="chip-meta">' + escapeHtml(attachment.state || 'ready') + '</span>' + retry +
      '<button type="button" class="chip-remove" aria-label="Remove attachment" data-action="dc-chat#removeAttachment" data-attachment-id="' + id + '"></button>' +
      '</span>';
  }

  renderReferenceChip(reference) {
    return '<span class="chip chip--ref">' +
      '<span class="chip-name">@' + escapeHtml(reference.label) + '</span>' +
      '<span class="chip-meta">' + escapeHtml(reference.type) + '</span>' +
      '<button type="button" class="chip-remove" aria-label="Remove reference" data-action="dc-chat#removeReference" data-reference-id="' + escapeHtml(reference.id) + '"></button>' +
      '</span>';
  }

  canSubmitRichInput() {
    if (this.attachments.some((attachment) => attachment.state === 'uploading')) {
      this.showRecovery('Attachment upload is still running. Wait, retry, or remove it.');
      return false;
    }
    if (this.attachments.some((attachment) => attachment.state === 'failed')) {
      this.showRecovery('Attachment upload failed. Retry or remove the failed chip.');
      return false;
    }
    const unresolved = (this.textarea?.value || '').match(/(^|\s)@[\w./:-]+/);
    if (unresolved) {
      this.showRecovery('Resolve or remove the reference token before sending.');
      return false;
    }
    return true;
  }

  showRecovery(message) {
    const recovery = this.recovery;
    if (!recovery) return;
    this.recoveryActive = true;
    recovery.textContent = message;
    recovery.hidden = false;
  }

  hideRecovery() {
    const recovery = this.recovery;
    if (!recovery) return;
    this.recoveryActive = false;
    recovery.hidden = true;
    recovery.textContent = '';
  }

  showTemporaryDialog(id, opener) {
    const dialog = this.element.querySelector(id);
    if (!dialog) return;
    this.temporaryDialogReturnFocus = opener || document.activeElement;
    dialog.showModal();
    dialog.querySelector('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')?.focus();
  }

  openTemporaryCreate(event) {
    this.showTemporaryDialog('#temporary-create-dialog', event?.currentTarget);
  }

  openTemporaryExport(event) {
    this.showTemporaryDialog('#temporary-export-dialog', event?.currentTarget);
  }

  openTemporaryEnd(event) {
    this.showTemporaryDialog('#temporary-end-dialog', event?.currentTarget);
  }

  closeTemporaryDialog(event) {
    event.currentTarget?.closest('dialog')?.close();
  }

  handleTemporaryDialogClose() {
    this.temporaryDialogReturnFocus?.focus();
    this.temporaryDialogReturnFocus = null;
  }

  handleTemporaryDialogKeydown(event) {
    if (event.key !== 'Tab') return;
    const dialog = event.currentTarget;
    const focusable = [...dialog.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')]
      .filter((element) => !element.disabled && element.getAttribute('aria-hidden') !== 'true');
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  async createTemporary(event) {
    const button = event.currentTarget;
    button.disabled = true;
    try {
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ retention: 'process', disclosureAccepted: true }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error?.message || 'Temporary conversation is unavailable');
      window.location.assign('/sessions/' + encodeURIComponent(result.id));
    } catch (error) {
      button.disabled = false;
      showBanner(error.message, 'error');
    }
  }

  async endTemporary(event) {
    event.currentTarget?.closest('dialog')?.close();
    const state = this.element.querySelector('[data-temporary-state]');
    const controls = this.element.querySelectorAll('.conversation-temporary-banner button');
    controls.forEach((button) => { button.disabled = true; });
    if (state) state.textContent = 'Ending…';
    try {
      const response = await fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/end-temporary', {
        method: 'POST',
      });
      if (!response.ok) {
        const result = await response.json().catch(() => ({}));
        throw new Error(result.error?.message || 'Ending could not be confirmed');
      }
      temporaryDrafts.delete(this.sessionId);
      window.location.assign('/');
    } catch (error) {
      if (state) state.textContent = 'End failed: ' + error.message;
      controls.forEach((button) => { button.disabled = false; });
    }
  }

  async exportTemporary(event) {
    const button = event.currentTarget;
    const dialog = button.closest('dialog');
    button.disabled = true;
    try {
      const response = await fetch('/api/sessions/' + encodeURIComponent(this.sessionId) + '/export', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ confirmed: true, durableCopyAccepted: true }),
      });
      if (!response.ok) throw new Error('Export could not be created');
      const blob = await response.blob();
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = 'dartclaw-conversation-' + this.sessionId + '.md';
      link.click();
      URL.revokeObjectURL(link.href);
      dialog?.close();
    } catch (error) {
      showBanner(error.message, 'error');
    } finally {
      button.disabled = false;
    }
  }
}
