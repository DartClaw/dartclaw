import { apiQs, showToast } from './shared.js';

const searchDelayMs = 160;

export default class DcConversationCommandController extends Stimulus.Controller {
  connect() {
    this.catalogs = new Map();
    this.searchGeneration = 0;
    this.activeOption = 0;
    this.searchTimer = null;
    this.handleClick = this.handleClick.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);
    this.handleInput = this.handleInput.bind(this);
    this.handlePopstate = this.handlePopstate.bind(this);
    this.handleConversationChanged = this.handleConversationChanged.bind(this);
    document.addEventListener('click', this.handleClick);
    document.addEventListener('keydown', this.handleKeydown);
    document.addEventListener('input', this.handleInput);
    window.addEventListener('popstate', this.handlePopstate);
    document.body.addEventListener('dartclaw:conversation-changed', this.handleConversationChanged);
    this.restoreSearchReturn();
  }

  disconnect() {
    document.removeEventListener('click', this.handleClick);
    document.removeEventListener('keydown', this.handleKeydown);
    document.removeEventListener('input', this.handleInput);
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
    if (event.key === 'Enter' && host.querySelector('[data-command-option].active')) {
      event.preventDefault();
      this.chooseOption(host.querySelector('[data-command-option].active'));
      return;
    }
    if (event.key === 'Tab' && dialog) this.trapFocus(event, dialog);
  }

  handleInput(event) {
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
    const parameters = new URLSearchParams({
      q: query,
      scope,
      lifecycle: dialog.querySelector('[data-search-lifecycle]')?.value || 'all',
      request_token: String(generation),
    });
    if (scope === 'current') parameters.set('session_id', this.sessionId);
    const project = dialog.querySelector('[data-search-project]')?.value.trim();
    if (project) parameters.set('project_id', project);
    try {
      const response = await fetch(this.apiUrl('/api/conversation-search', parameters));
      const data = await response.json();
      if (generation !== this.searchGeneration || data.request_token !== String(generation)) return;
      if (!response.ok) throw new Error(data.error?.message || 'Search is unavailable');
      this.renderSearch(dialog.querySelector('[data-command-results]'), data.results || []);
      this.setStatus(dialog, data.total ? data.total + ' results' : 'No matching conversations.');
    } catch (error) {
      if (generation !== this.searchGeneration) return;
      dialog.querySelector('[data-command-results]').replaceChildren();
      this.setStatus(dialog, error.message || 'Search is unavailable');
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
      const button = this.optionButton({
        label: result.title,
        description: '',
      });
      const description = button.querySelector('span');
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

  optionButton(entry) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'command-option';
    button.dataset.commandOption = 'true';
    button.setAttribute('role', 'option');
    const label = document.createElement('strong');
    label.textContent = entry.label;
    const description = document.createElement('span');
    description.textContent = entry.description;
    button.append(label, description);
    return button;
  }

  markActive(options) {
    options.forEach((option, index) => {
      const active = index === this.activeOption;
      option.classList.toggle('active', active);
      option.setAttribute('aria-selected', String(active));
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
    if (data.action === 'open_context') {
      document.getElementById('effective-context-open')?.click();
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
