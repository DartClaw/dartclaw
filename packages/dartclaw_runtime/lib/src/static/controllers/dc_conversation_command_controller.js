import { apiQs, showToast } from './shared.js';

const searchDelayMs = 160;
// The page renders exactly this many results, so it is also what the status line
// may claim is reachable — a bare total over a shorter page reports matches the
// reader cannot get to (0.27 said "137 results" and rendered 20).
const searchPageSize = 50;

export default class DcConversationCommandController extends Stimulus.Controller {
  connect() {
    this.catalogs = new Map();
    this.searchGeneration = 0;
    this.activeOption = 0;
    this.searchTimer = null;
    this.handleClick = this.handleClick.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);
    this.handlePointerMove = this.handlePointerMove.bind(this);
    this.handleMouseDown = this.handleMouseDown.bind(this);
    this.handlePointerDown = this.handlePointerDown.bind(this);
    this.handleInput = this.handleInput.bind(this);
    this.handlePopstate = this.handlePopstate.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);
    this.handleSlashPaletteRequest = this.handleSlashPaletteRequest.bind(this);
    this.handleSlashPaletteClose = this.handleSlashPaletteClose.bind(this);
    document.addEventListener('click', this.handleClick);
    document.addEventListener('keydown', this.handleKeydown);
    document.addEventListener('pointermove', this.handlePointerMove);
    document.addEventListener('mousedown', this.handleMouseDown);
    document.addEventListener('pointerdown', this.handlePointerDown);
    document.addEventListener('input', this.handleInput);
    document.addEventListener('change', this.handleInput);
    document.addEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest);
    document.addEventListener('dartclaw:slash-palette-close', this.handleSlashPaletteClose);
    window.addEventListener('popstate', this.handlePopstate);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    this.restoreSearchReturn();
  }

  disconnect() {
    document.removeEventListener('click', this.handleClick);
    document.removeEventListener('keydown', this.handleKeydown);
    document.removeEventListener('pointermove', this.handlePointerMove);
    document.removeEventListener('mousedown', this.handleMouseDown);
    document.removeEventListener('pointerdown', this.handlePointerDown);
    document.removeEventListener('input', this.handleInput);
    document.removeEventListener('change', this.handleInput);
    document.removeEventListener('dartclaw:slash-palette', this.handleSlashPaletteRequest);
    document.removeEventListener('dartclaw:slash-palette-close', this.handleSlashPaletteClose);
    window.removeEventListener('popstate', this.handlePopstate);
    document.body.removeEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    clearTimeout(this.searchTimer);
  }

  handleConversationChanged() {
    this.catalogs.clear();
  }

  handlePopstate() {
    this.restoreSearchReturn();
  }

  get sessionId() {
    return document.querySelector('.chat-area')?.dataset.sessionId || '';
  }

  get isTemporary() {
    return document.querySelector('.chat-area')?.dataset.retention === 'process';
  }

  handleClick(event) {
    const open = event.target.closest('[data-command-open]');
    if (open) {
      event.preventDefault();
      this.openDialog(open.dataset.commandOpen);
      return;
    }
    if (event.target.closest('[data-command-close]')) {
      this.closeDialog(event.target.closest('dialog'));
      return;
    }
    const lifecycle = event.target.closest('[data-search-lifecycle-option]');
    if (lifecycle) {
      event.preventDefault();
      const dialog = lifecycle.closest('dialog');
      dialog.dataset.searchLifecycle = lifecycle.dataset.searchLifecycleOption;
      for (const chip of dialog.querySelectorAll('[data-search-lifecycle-option]')) {
        chip.setAttribute('aria-pressed', String(chip === lifecycle));
      }
      this.refreshDialog(dialog);
      return;
    }
    const option = event.target.closest('[data-command-option]');
    if (option) {
      event.preventDefault();
      this.chooseOption(option);
    }
  }

  handleKeydown(event) {
    if (event.isComposing) return;
    if ((event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      this.openDialog('global');
      return;
    }
    const dialog = document.querySelector('dialog.command-dialog[open]');
    const slash = document.querySelector('[data-slash-palette]:not([hidden])');
    const host = dialog || slash;
    if (!host) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      if (dialog) this.closeDialog(dialog);
      else slash.hidden = true;
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const options = [...host.querySelectorAll('[data-command-option]:not([disabled])')];
      if (!options.length) return;
      this.activeOption = (this.activeOption + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
      this.markActive(options);
      return;
    }
    if (event.key === 'Enter' && host.querySelector('[data-command-option].palette-item--active')) {
      event.preventDefault();
      this.chooseOption(host.querySelector('[data-command-option].palette-item--active'));
      return;
    }
    if (event.key === 'Tab' && dialog) this.trapFocus(event, dialog);
  }

  /// The pointer moves the same cursor the arrow keys do. A move, not an
  /// enter: a list scrolled under a resting pointer must not take the cursor
  /// back from the key that scrolled it.
  handlePointerMove(event) {
    const option = event.target.closest?.('[data-command-option]');
    if (!option || option.disabled || option.classList.contains('palette-item--active')) return;
    const host = option.closest('dialog.command-dialog[open], [data-slash-palette]');
    if (!host) return;
    const options = [...host.querySelectorAll('[data-command-option]:not([disabled])')];
    const index = options.indexOf(option);
    if (index < 0) return;
    this.activeOption = index;
    this.markActive(options, { scroll: false });
  }

  /// A press inside a palette must leave focus in its input: the rows and the
  /// header are not focusable, so the browser would hand focus to the nearest
  /// focusable ancestor (`#main-content`) and the arrow keys with it. `click`
  /// still fires, so a row is still chosen.
  handleMouseDown(event) {
    if (event.target.closest?.('[data-slash-palette], dialog.command-dialog [data-command-results]')) {
      event.preventDefault();
    }
  }

  /// A press outside the slash palette closes it, on pointerdown like every
  /// other composer popover. The composer keeps it open because its text drives
  /// the palette, and the commands button because its own click toggles it.
  handlePointerDown(event) {
    const palette = document.querySelector('[data-slash-palette]:not([hidden])');
    if (!palette) return;
    if (event.target.closest?.('[data-slash-palette], #message-input, [data-action~="dc-chat#openCommands"]')) return;
    palette.hidden = true;
  }

  handleInput(event) {
    if (event.target.matches?.('[data-search-project]')) {
      this.refreshDialog(event.target.closest('dialog'));
      return;
    }
    const queryInput = event.target.closest('[data-command-query]');
    if (queryInput) {
      clearTimeout(this.searchTimer);
      const generation = ++this.searchGeneration;
      this.searchTimer = setTimeout(
        () => this.refreshDialog(queryInput.closest('dialog'), generation),
        searchDelayMs,
      );
      return;
    }
    if (event.target.id !== 'message-input') return;
    const value = event.target.value;
    const palette = document.querySelector('[data-slash-palette]');
    if (!palette) return;
    if (!value.startsWith('/') || value.includes('\n')) {
      palette.hidden = true;
      return;
    }
    if (palette.hidden) this.catalogs.delete('slash|' + this.sessionId);
    palette.hidden = false;
    this.renderSlash(value).catch(() => {
      palette.hidden = true;
    });
  }

  async openDialog(scope) {
    const dialog = document.querySelector('[data-command-dialog="' + scope + '"]');
    if (!dialog) return;
    this.returnFocus = document.activeElement;
    this.activeOption = 0;
    this.catalogs.delete(scope + '|' + this.sessionId);
    if (!dialog.open) dialog.showModal();
    const input = dialog.querySelector('[data-command-query]');
    input?.focus();
    input?.select();
    await this.refreshDialog(dialog, ++this.searchGeneration);
  }

  closeDialog(dialog) {
    if (!dialog?.open) return;
    this.searchGeneration++;
    dialog.close();
    this.returnFocus?.focus();
  }

  async refreshDialog(dialog, generation = ++this.searchGeneration) {
    if (!dialog?.open || generation !== this.searchGeneration) return;
    const input = dialog.querySelector('[data-command-query]');
    const query = input?.value || '';
    if (dialog.dataset.commandDialog === 'global' && query.startsWith('/')) {
      const catalog = await this.catalog('global');
      if (generation !== this.searchGeneration) return;
      this.renderCatalog(dialog.querySelector('[data-command-results]'), catalog, query);
      this.setStatus(dialog, catalog.entries.length + ' commands available');
      return;
    }
    if (!query.trim()) {
      if (dialog.dataset.commandDialog === 'global') {
        const catalog = await this.catalog('global');
        if (generation !== this.searchGeneration) return;
        this.renderCatalog(dialog.querySelector('[data-command-results]'), catalog, '');
        this.setStatus(dialog, this.sessionId ? 'Commands for this conversation.' : 'Open a conversation for session commands.');
      } else {
        dialog.querySelector('[data-command-results]').replaceChildren();
        this.setStatus(dialog, 'Type to search.');
      }
      return;
    }
    await this.search(dialog, query, generation);
  }

  async search(dialog, query, generation) {
    const scope = dialog.dataset.commandDialog;
    this.setStatus(dialog, 'Searching…');
    let failureMessage = 'Search is unavailable';
    const parameters = new URLSearchParams({
      q: query,
      scope,
      lifecycle: dialog.dataset.searchLifecycle || 'all',
      limit: String(searchPageSize),
      request_token: String(generation),
    });
    if (scope === 'current') parameters.set('session_id', this.sessionId);
    const project = dialog.querySelector('[data-search-project]')?.value;
    if (project !== undefined && project !== ':all') parameters.set('project_id', project);
    try {
      const response = await fetch(this.apiUrl('/api/conversation-search', parameters));
      const data = await response.json();
      if (generation !== this.searchGeneration) return;
      if (!response.ok) {
        failureMessage = data.error?.message || failureMessage;
        throw new Error(failureMessage);
      }
      if (data.request_token !== String(generation)) return;
      const results = data.results || [];
      this.renderSearch(dialog.querySelector('[data-command-results]'), results);
      const total = Number(data.total) || 0;
      this.setStatus(dialog, !total
        ? 'No matching conversations.'
        : total > results.length
          ? results.length + ' of ' + total + ' results — narrow the search to reach the rest'
          : total + ' results');
    } catch (_) {
      if (generation !== this.searchGeneration) return;
      dialog.querySelector('[data-command-results]').replaceChildren();
      this.setStatus(dialog, failureMessage);
    }
  }

  async catalog(surface) {
    const key = surface + '|' + this.sessionId;
    if (this.catalogs.has(key)) return this.catalogs.get(key);
    const parameters = new URLSearchParams({ surface });
    if (this.sessionId) parameters.set('session_id', this.sessionId);
    const response = await fetch(this.apiUrl('/api/command-catalog', parameters));
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || 'Commands are unavailable');
    this.catalogs.set(key, data);
    return data;
  }

  /// The composer button asks for the whole catalogue: it is opening the
  /// palette, not typing a query, and the composer may hold a draft that is no
  /// query at all.
  handleSlashPaletteClose() {
    const palette = document.querySelector('[data-slash-palette]');
    if (palette) palette.hidden = true;
  }

  handleSlashPaletteRequest() {
    const palette = document.querySelector('[data-slash-palette]');
    if (!palette) return;
    this.catalogs.delete('slash|' + this.sessionId);
    palette.hidden = false;
    this.renderSlash('').catch(() => {
      palette.hidden = true;
    });
  }

  async renderSlash(query) {
    const palette = document.querySelector('[data-slash-palette]');
    const target = palette.querySelector('[data-slash-results]');
    const catalog = await this.catalog('slash');
    this.renderCatalog(target, catalog, query);
    if (!target.children.length) {
      const button = this.optionButton({ label: 'Send to provider', description: 'Send this text unchanged' });
      button.dataset.passthrough = 'true';
      target.append(button);
    }
  }

  renderCatalog(target, catalog, query) {
    const normalized = query.toLowerCase();
    target.replaceChildren();
    for (const entry of catalog.entries) {
      if (normalized && !entry.label.toLowerCase().includes(normalized) && !entry.description.toLowerCase().includes(normalized)) continue;
      const button = this.optionButton(entry);
      button.dataset.commandId = entry.id;
      button.dataset.identityToken = catalog.identity_token;
      button.dataset.confirmation = entry.confirmation || '';
      button.disabled = !entry.enabled;
      target.append(button);
    }
    this.activeOption = 0;
    this.markActive([...target.querySelectorAll('[data-command-option]:not([disabled])')]);
  }

  renderSearch(target, results) {
    target.replaceChildren();
    for (const result of results) {
      const button = this.optionButton({ label: result.title, description: '' });
      const description = button.querySelector('.palette-item-context');
      const snippet = String(result.snippet || '');
      const start = Math.max(0, Math.min(Number(result.highlight_start) || 0, snippet.length));
      const end = Math.max(start, Math.min(Number(result.highlight_end) || 0, snippet.length));
      description.append(document.createTextNode(snippet.slice(0, start)));
      if (end > start) {
        const highlight = document.createElement('mark');
        highlight.textContent = snippet.slice(start, end);
        description.append(highlight);
      }
      description.append(document.createTextNode(snippet.slice(end) + ' · ' + result.citation));
      button.dataset.searchSession = result.session_id;
      button.dataset.searchMessage = result.message_id;
      button.dataset.searchHref = result.href;
      target.append(button);
    }
    this.activeOption = 0;
    this.markActive([...target.querySelectorAll('[data-command-option]')]);
  }

  /// Canon `.palette-item`: icon · label · context · shortcut. The bespoke
  /// `.command-option` this replaced carried its own borders and text tiers.
  optionButton(entry) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'palette-item';
    button.dataset.commandOption = 'true';
    button.setAttribute('role', 'option');
    const icon = document.createElement('span');
    // A `/name` entry is a command; everything else in these lists is a chat.
    icon.className = 'icon ' + (entry.label?.startsWith('/') ? 'icon-terminal' : 'icon-message-circle');
    icon.setAttribute('aria-hidden', 'true');
    const label = document.createElement('span');
    label.className = 'palette-item-label';
    label.textContent = entry.label;
    const description = document.createElement('span');
    description.className = 'palette-item-context';
    description.textContent = entry.description;
    button.append(icon, label, description);
    return button;
  }

  markActive(options, { scroll = true } = {}) {
    options.forEach((option, index) => {
      const active = index === this.activeOption;
      option.classList.toggle('palette-item--active', active);
      option.setAttribute('aria-selected', String(active));
      if (active && scroll) option.scrollIntoView({ block: 'nearest' });
    });
  }

  async chooseOption(option) {
    if (option.dataset.passthrough) {
      document.querySelector('[data-slash-palette]').hidden = true;
      this.textarea()?.focus();
      return;
    }
    if (option.dataset.searchSession) {
      await this.openSearchTarget(option);
      return;
    }
    await this.runCommand(option);
  }

  async openSearchTarget(option) {
    const parameters = new URLSearchParams({
      session_id: option.dataset.searchSession,
      message_id: option.dataset.searchMessage,
    });
    const response = await fetch(this.apiUrl('/api/conversation-search/target', parameters));
    if (!response.ok) {
      const dialog = option.closest('dialog');
      this.setStatus(dialog, 'That message is no longer available. Search again.');
      option.remove();
      return;
    }
    if (this.isTemporary) {
      sessionStorage.removeItem('dartclaw-search-return');
    } else {
      sessionStorage.setItem('dartclaw-search-return', JSON.stringify({
        href: location.href,
        scope: option.closest('dialog')?.dataset.commandDialog || 'global',
        query: option.closest('dialog')?.querySelector('[data-command-query]')?.value || '',
        draft: this.textarea()?.value || '',
        position: this.activeOption,
      }));
    }
    location.assign(this.withToken(option.dataset.searchHref));
  }

  async runCommand(option) {
    if (option.dataset.confirmation && !globalThis.confirm(option.dataset.confirmation)) return;
    const body = {
      command_id: option.dataset.commandId,
      identity_token: option.dataset.identityToken,
      session_id: this.sessionId || null,
      confirmed: Boolean(option.dataset.confirmation),
    };
    if (option.dataset.commandId === 'built-in:fork') {
      body.source_message_id = document.querySelector('[data-message-id]:last-of-type')?.dataset.messageId;
      body.mutation_id = globalThis.crypto?.randomUUID?.() || String(Date.now());
    }
    const response = await fetch(this.apiUrl('/api/command-actions'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await response.json();
    if (!response.ok) {
      if (response.status === 409) this.catalogs.clear();
      showToast('error', data.error?.message || 'Command failed');
      return;
    }
    if (data.action === 'navigate') location.assign(this.withToken(data.href));
    if (data.action === 'refresh') location.reload();
    // Both routed fields live in the model popover. Asking dc-chat to open it
    // rather than clicking the pill keeps the route idempotent — a click would
    // toggle a popover the reader already has open.
    if (data.action === 'open_context') {
      document.getElementById('main-content')?.dispatchEvent(
        new CustomEvent('dartclaw:chat-action', { bubbles: true, detail: { action: 'model-context' } }),
      );
      document.querySelector('[name="' + data.field + '"]')?.focus();
    }
    if (data.action === 'show_help') showToast('info', 'Use ↑/↓ to choose and Enter to run. Unknown slash text is sent to the provider.');
    if (data.action === 'status') showToast('info', 'Conversation revision ' + data.conversation_revision);
    if (data.action === 'send_provider') {
      const textarea = this.textarea();
      if (textarea) {
        textarea.value = data.message;
        textarea.dispatchEvent(new Event('input', { bubbles: true }));
        textarea.focus();
      }
      document.querySelector('[data-slash-palette]')?.setAttribute('hidden', '');
      document.querySelector('dialog.command-dialog[open]')?.close();
    }
  }

  textarea() {
    return document.getElementById('message-input');
  }

  async restoreSearchReturn() {
    if (this.isTemporary) {
      sessionStorage.removeItem('dartclaw-search-return');
      return;
    }
    let saved;
    try {
      saved = JSON.parse(sessionStorage.getItem('dartclaw-search-return') || 'null');
    } catch (_) {
      sessionStorage.removeItem('dartclaw-search-return');
      return;
    }
    if (!saved || new URL(saved.href, location.origin).href !== location.href) return;
    sessionStorage.removeItem('dartclaw-search-return');
    const textarea = this.textarea();
    if (textarea && typeof saved.draft === 'string') {
      textarea.value = saved.draft;
      textarea.dispatchEvent(new Event('input', { bubbles: true }));
    }
    const scope = saved.scope === 'current' ? 'current' : 'global';
    const dialog = document.querySelector('[data-command-dialog="' + scope + '"]');
    const input = dialog?.querySelector('[data-command-query]');
    if (input && typeof saved.query === 'string') input.value = saved.query;
    if (!dialog) return;
    await this.openDialog(scope);
    const options = [...dialog.querySelectorAll('[data-command-option]:not([disabled])')];
    this.activeOption = Math.min(Number(saved.position) || 0, Math.max(0, options.length - 1));
    this.markActive(options);
  }

  apiUrl(path, parameters = new URLSearchParams()) {
    const token = new URLSearchParams(apiQs().slice(1)).get('token');
    if (token) parameters.set('token', token);
    const query = parameters.toString();
    return path + (query ? '?' + query : '');
  }

  withToken(href) {
    const token = new URLSearchParams(apiQs().slice(1)).get('token');
    if (!token) return href;
    const target = new URL(href, location.origin);
    target.searchParams.set('token', token);
    return target.pathname + target.search + target.hash;
  }

  setStatus(dialog, message) {
    const status = dialog?.querySelector('[data-command-status]');
    if (status) status.textContent = message;
  }

  trapFocus(event, dialog) {
    const focusable = [...dialog.querySelectorAll('button:not([disabled]),input:not([disabled]),select:not([disabled]),a[href]')]
      .filter((element) => !element.hidden);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }
}
