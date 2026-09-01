export default class DcMemoryController extends Stimulus.Controller {
  connect() {
    this.afterSwapHandler = (event) => this.afterSwap(event);
    this.element.addEventListener('htmx:afterSwap', this.afterSwapHandler);
    this.initializeView();
  }

  disconnect() {
    if (this.afterSwapHandler) {
      this.element.removeEventListener('htmx:afterSwap', this.afterSwapHandler);
      this.afterSwapHandler = null;
    }
  }

  get apiQs() {
    return window.dartclaw?.shell?.apiQs?.() || '';
  }

  afterSwap(event) {
    const target = event?.detail?.target;
    if (target?.id === 'memory-content' || target?.id === 'memory-inner') {
      this.initializeView();
    }
  }

  initializeView() {
    this.initMemoryViewToggle();
    this.initMemoryDefaultTab();
  }

  initMemoryViewToggle() {
    const mode = localStorage.getItem('dartclaw-memory-view') === 'rendered' ? 'rendered' : 'raw';
    this.element.querySelectorAll('.toggle-btn[data-mode]').forEach((button) => {
      const active = button.dataset.mode === mode;
      button.classList.toggle('active', active);
      button.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
  }

  initMemoryDefaultTab() {
    const activeTab = this.element.querySelector('.tab.active[data-action="click->dc-memory#switchTab"][data-tab]');
    if (!activeTab) return;

    const tabId = activeTab.dataset.tab;
    const panel = document.getElementById(tabId);
    if (!panel) return;

    const preview = panel.querySelector('.memory-preview');
    if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
      this.loadPreview(preview);
    }
  }

  switchTab(event) {
    const button = event?.currentTarget;
    const tabId = button?.dataset?.tab;
    if (!button || !tabId) return;

    const card = button.closest('.card');
    if (!card) return;

    card.querySelectorAll('.tab').forEach((tab) => {
      tab.classList.remove('active');
      tab.setAttribute('aria-selected', 'false');
      tab.setAttribute('tabindex', '-1');
    });
    button.classList.add('active');
    button.setAttribute('aria-selected', 'true');
    button.setAttribute('tabindex', '0');

    card.querySelectorAll('.tab-panel').forEach((panel) => panel.classList.remove('active'));
    const panel = card.querySelector('#' + CSS.escape(tabId));
    if (panel) panel.classList.add('active');

    const preview = panel?.querySelector('.memory-preview');
    if (preview && !preview.dataset.loaded && !preview.dataset.loading) {
      this.loadPreview(preview);
    }
  }

  navigateTabs(event) {
    const tablist = event?.currentTarget;
    const tab = event?.target?.closest?.('[role="tab"]');
    if (!tablist || !tab || !tablist.contains(tab)) return;

    const tabs = Array.from(tablist.querySelectorAll('[role="tab"]'));
    const index = tabs.indexOf(tab);
    if (index === -1) return;

    let next;
    switch (event.key) {
      case 'ArrowRight':
        next = tabs[(index + 1) % tabs.length];
        break;
      case 'ArrowLeft':
        next = tabs[(index - 1 + tabs.length) % tabs.length];
        break;
      case 'Home':
        next = tabs[0];
        break;
      case 'End':
        next = tabs[tabs.length - 1];
        break;
      default:
        return;
    }
    if (!next) return;

    event.preventDefault();
    next.click();
    next.focus();
    next.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  toggleView(event) {
    const button = event?.currentTarget;
    const mode = button?.dataset?.mode;
    if (!button || !mode) return;

    const group = button.closest('.toggle-btn-group');
    if (group) {
      group.querySelectorAll('.toggle-btn').forEach((toggleButton) => {
        const active = toggleButton === button;
        toggleButton.classList.toggle('active', active);
        toggleButton.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
    }
    localStorage.setItem('dartclaw-memory-view', mode);
    this.element.querySelectorAll('.memory-preview[data-loaded]').forEach((preview) => this.applyMemoryViewMode(preview));
  }

  async loadPreview(preview) {
    const fileName = preview.dataset.file;
    if (!fileName) return;

    preview.dataset.loading = '1';
    preview.innerHTML = '<div class="skeleton skeleton-text"></div>';
    try {
      const response = await fetch('/api/memory/files/' + encodeURIComponent(fileName) + this.apiQs);
      if (!response.ok) throw new Error('Memory file request failed');

      preview.dataset.rawContent = await response.text();
      preview.dataset.loaded = '1';
      delete preview.dataset.loading;
      this.applyMemoryViewMode(preview);
    } catch (_) {
      delete preview.dataset.loading;
      preview.textContent = 'Failed to load file content.';
    }
  }

  applyMemoryViewMode(preview) {
    const rawContent = preview.dataset.rawContent;
    if (rawContent == null) return;

    if (rawContent === '') {
      preview.textContent = 'File is empty - no entries yet.';
      return;
    }

    const mode = localStorage.getItem('dartclaw-memory-view') || 'raw';
    if (mode === 'rendered' && window.marked && window.DOMPurify) {
      preview.innerHTML = window.DOMPurify.sanitize(window.marked.parse(rawContent));
      preview.querySelectorAll('h1, h2, h3, h4, h5').forEach((heading) => {
        const level = Math.min(Number(heading.tagName.slice(1)) + 2, 6);
        const replacement = document.createElement('h' + level);
        for (const attribute of heading.attributes) {
          replacement.setAttribute(attribute.name, attribute.value);
        }
        replacement.append(...heading.childNodes);
        heading.replaceWith(replacement);
      });
    } else {
      preview.textContent = rawContent;
    }
  }

}
