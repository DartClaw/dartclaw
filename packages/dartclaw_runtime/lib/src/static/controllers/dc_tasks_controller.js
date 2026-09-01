import { updateRunningTasksSection, updateRunningWorkflowsSection } from './sidebar_sections.js';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  dartclaw.shell = dartclaw.shell || {};
  const ui = dartclaw.ui;
  const shell = dartclaw.shell;
  let taskEventSource = null;
  let latestTaskReviewCount = null;
  let cachedActiveTasks = [];
  let taskElapsedTimer = null;
  let taskDetailRefreshTimer = null;
  let taskControllerGeneration = 0;
  let turnStatusRefreshGeneration = 0;
  const activeTurnStates = new Set(['running', 'waiting', 'stuck', 'cancelling']);
  const tasksApiPath = '/api/tasks';

  // Mirror of templates/task_event_display.dart#eventIconClass, keyed by the
  // `kind` the task_event SSE payload already carries. Canonical keys are the
  // TaskEventKind value names; 'error' is TaskEventKind.fromName's legacy alias
  // for taskError. A new kind must be added in both places — task_event_icon_map_test
  // asserts exact map equality, so the omission fails there rather than in the UI.
  const TASK_EVENT_ICON_CLASSES = {
    statusChanged: 'icon-circle-check',
    toolCalled: 'icon-wrench',
    artifactCreated: 'icon-file-text',
    structuredOutputFinalizerUsed: 'icon-file-json',
    structuredOutputInlineUsed: 'icon-file-json',
    structuredOutputFallbackUsed: 'icon-file-warning',
    structuredOutputValidationFailed: 'icon-file-warning',
    pushBack: 'icon-message-circle',
    tokenUpdate: 'icon-gauge',
    taskError: 'icon-triangle-alert',
    compaction: 'icon-layers',
    error: 'icon-triangle-alert',
  };

  // Null for an unrecognized kind. The caller then emits neither the base `icon`
  // class nor a mask, because a masked element with no mask paints a solid block.
  function taskEventIconClass(kind) {
    return Object.prototype.hasOwnProperty.call(TASK_EVENT_ICON_CLASSES, kind)
      ? TASK_EVENT_ICON_CLASSES[kind]
      : null;
  }

  function workflowPage() {
    return dartclaw.workflowsControllerApi || {};
  }

  function updateTaskSidebar(tasks) {
    cachedActiveTasks = updateRunningTasksSection(tasks);
    initTaskElapsedTimers();
  }

  async function refreshSidebarTaskState() {
    if (!document.querySelector('[data-tasks-enabled]')) return;

    try {
      const response = await fetch(`${tasksApiPath}/sidebar-state`);
      if (!response.ok) return;

      const payload = await response.json();
      latestTaskReviewCount = payload.reviewCount ?? 0;
      updateTaskBadge(latestTaskReviewCount);
      updateTaskSidebar(payload.activeTasks || []);
      updateRunningWorkflowsSection(payload.activeWorkflows || []);
    } catch (_) {}
  }

  function initTaskSse() {
    if (taskEventSource || !document.querySelector('[data-tasks-enabled]')) return;
    try {
      taskEventSource = new EventSource(`${tasksApiPath}/events`);
    } catch (_) {
      return;
    }

    taskEventSource.onmessage = function(event) {
      try {
        const data = JSON.parse(event.data);

        if (data.type === 'connected') {
          updateTaskBadge(data.reviewCount || 0);
          updateTaskSidebar(data.activeTasks || []);
          updateRunningWorkflowsSection(data.activeWorkflows || []);
          refreshDisplayedTurnStatus();
          if (Array.isArray(data.projects)) {
            data.projects.forEach((project) => updateProjectStatusBadge(project.id, project.status));
          }
          return;
        }

        if (data.type === 'task_status_changed') {
          updateTaskBadge(data.reviewCount || 0);
          updateTaskSidebar(data.activeTasks || []);
          if (Array.isArray(data.activeWorkflows)) {
            updateRunningWorkflowsSection(data.activeWorkflows);
          }
          if (shouldRefreshTaskContent(data.taskId)) {
            refreshTasksPageContent();
          }
          return;
        }

        if (data.type === 'workflow_sidebar_update') {
          updateRunningWorkflowsSection(data.activeWorkflows || []);
          if (data.notification && typeof workflowPage().incrementNotification === 'function') {
            workflowPage().incrementNotification();
          }
          return;
        }

        if (data.type === 'runner_state') {
          if (shouldRefreshTaskContent(data.currentTaskId)) {
            refreshTasksPageContent();
          }
          return;
        }

        if (data.type === 'execution_capacity') {
          refreshTasksPageContent();
          return;
        }

        if (data.type === 'project_status') {
          updateProjectStatusBadge(data.projectId, data.newStatus);
          return;
        }

        if (data.type === 'task_progress') {
          updateTaskProgress(data);
          updateDashboardProgress(data);
          return;
        }

        if (data.type === 'task_event') {
          updateDashboardEvents(data);
          return;
        }

        if (data.type === 'turn_wait_state') {
          applyTurnWaitState(data);
        }
      } catch (_) {}
    };

    taskEventSource.onerror = function() {
      // Intentionally empty: EventSource auto-reconnects, and the turn-status
      // snapshot refresh re-fires from the 'connected' event handler above.
    };
  }

  function displayedTurnPanel() {
    return document.querySelector('[data-turn-status-session-id]');
  }

  function refreshDisplayedTurnStatus() {
    const panel = displayedTurnPanel();
    if (!panel) return;
    const sessionId = panel.getAttribute('data-turn-status-session-id');
    if (!sessionId) return;
    const generation = ++turnStatusRefreshGeneration;
    fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/turn-status')
      .then((response) => response.ok ? response.json() : null)
      .then((payload) => {
        const currentPanel = displayedTurnPanel();
        if (
          payload &&
          generation === turnStatusRefreshGeneration &&
          currentPanel?.getAttribute('data-turn-status-session-id') === sessionId
        ) {
          applyTurnWaitState(payload);
        }
      })
      .catch(() => {});
  }

  function applyTurnWaitState(data) {
    const panel = displayedTurnPanel();
    if (!panel || panel.getAttribute('data-turn-status-session-id') !== data.session_id) return;
    const state = data.state || 'idle';
    const hasActiveTurn = activeTurnStates.has(state) && Boolean(data.turn_id);
    panel.hidden = !hasActiveTurn;
    if (!hasActiveTurn) {
      panel.removeAttribute('data-turn-status-turn-id');
    } else {
      panel.setAttribute('data-turn-status-turn-id', data.turn_id);
    }
    const reason = (data.wait_reason || '').replace(/_/g, ' ');
    const stateEl = panel.querySelector('[data-turn-status-state]');
    if (stateEl) stateEl.textContent = state.charAt(0).toUpperCase() + state.slice(1);
    const reasonEl = panel.querySelector('[data-turn-status-reason]');
    if (reasonEl) {
      // Same absent treatment the server rendered into this element: canon's
      // .value-absent supplies the dash from an empty span, so writing one here
      // would leave the live update and the first paint disagreeing.
      reasonEl.textContent = reason;
      reasonEl.classList.toggle('value-absent', reason === '');
    }
    setPanelText(panel, '[data-turn-status-waiting]', formatElapsedTimeIso(data.waiting_since));
    setPanelText(panel, '[data-turn-status-stuck]', formatElapsedTimeIso(data.stuck_since));
    setPanelText(panel, '[data-turn-status-timeout]', formatRemainingTimeIso(data.global_timeout_at));
    const button = panel.querySelector('[data-turn-cancel]');
    if (button) {
      button.hidden = !hasActiveTurn || data.can_cancel !== true;
      button.disabled = !hasActiveTurn || data.can_cancel !== true;
      if (hasActiveTurn) {
        button.setAttribute('data-turn-id', data.turn_id);
      } else {
        button.removeAttribute('data-turn-id');
      }
    }
  }

  function setPanelText(panel, selector, value) {
    const el = panel.querySelector(selector);
    if (el) el.textContent = value;
  }

  function formatElapsedTimeIso(value) {
    if (!value) return '';
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) return '';
    const elapsedMs = Date.now() - parsed.getTime();
    const days = Math.trunc(elapsedMs / 86400000);
    if (days > 30) {
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      const date = parsed.getDate() + ' ' + months[parsed.getMonth()];
      return parsed.getFullYear() === new Date().getFullYear() ? date : date + ' ' + parsed.getFullYear();
    }
    if (days > 0) return days + 'd ago';
    const hours = Math.trunc(elapsedMs / 3600000);
    if (hours > 0) return hours + 'h ago';
    const minutes = Math.trunc(elapsedMs / 60000);
    if (minutes > 0) return minutes + 'm ago';
    return 'just now';
  }

  function formatRemainingTimeIso(value) {
    if (!value) return '';
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) return '';
    const remainingMs = parsed.getTime() - Date.now();
    if (remainingMs < 0) return '';
    const days = Math.trunc(remainingMs / 86400000);
    if (days > 0) return 'in ' + days + 'd';
    const hours = Math.trunc(remainingMs / 3600000);
    if (hours > 0) return 'in ' + hours + 'h';
    const minutes = Math.trunc(remainingMs / 60000);
    return minutes > 0 ? 'in ' + minutes + 'm' : 'in under a minute';
  }

  function initTurnCancelActions() {
    document.querySelectorAll('[data-turn-cancel]').forEach((button) => {
      if (button.dataset.turnCancelInit) return;
      button.dataset.turnCancelInit = '1';
      button.addEventListener('click', async () => {
        const sessionId = button.getAttribute('data-session-id');
        const turnId = button.getAttribute('data-turn-id');
        if (!sessionId || !turnId || button.disabled) return;
        button.disabled = true;
        try {
          await fetch(
            '/api/sessions/' + encodeURIComponent(sessionId) + '/turns/' + encodeURIComponent(turnId) + '/cancel',
            {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: '{"reason":"operator_cancel"}',
            },
          );
          refreshDisplayedTurnStatus();
        } catch (_) {
          button.disabled = false;
        }
      });
    });
  }

  function updateTaskProgress(data) {
    const taskId = data.taskId;

    const activityEl = document.getElementById('task-activity-text-' + taskId);
    if (activityEl && data.currentActivity) {
      activityEl.textContent = data.currentActivity;
    }

    const wrapper = document.getElementById('task-meter-wrapper-' + taskId);
    if (wrapper) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        const pct = Math.min(Math.max(data.progress || 0, 0), 100);
        const fillEl = ensureMeter(wrapper, taskId);
        fillEl.style.width = pct + '%';
        fillEl.setAttribute('aria-valuenow', pct);
      } else {
        showScanBar(wrapper);
      }
    }

    const labelEl = document.getElementById('task-meter-label-' + taskId);
    if (labelEl) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        labelEl.textContent = formatTokenCount(data.tokensUsed) +
          ' / ' + formatTokenCount(data.tokenBudget) +
          ' tokens (' + (data.progress || 0) + '%)';
      } else {
        labelEl.textContent = formatTokenCount(data.tokensUsed) + ' tokens used';
      }
    }

    const section = document.getElementById('task-feedback-section');
    if (section) section.style.display = '';

    if (data.isComplete) {
      const activityIndicator = document.getElementById('task-activity-' + taskId);
      if (activityIndicator) activityIndicator.style.display = 'none';
    }
  }

  function updateDashboardProgress(data) {
    const taskId = data.taskId;
    const progressEl = document.getElementById('task-meter-' + taskId);
    if (!progressEl) return;

    if (data.tokenBudget != null && data.tokenBudget > 0) {
      const pct = Math.min(Math.max(data.progress || 0, 0), 100);
      const fillEl = ensureMeter(progressEl);
      fillEl.style.width = pct + '%';
    } else {
      showScanBar(progressEl);
    }

    const tokensEl = document.getElementById('task-tokens-' + taskId);
    if (tokensEl) {
      const span = tokensEl.querySelector('span');
      if (span) {
        if (data.tokenBudget != null && data.tokenBudget > 0) {
          span.textContent = formatTokenCount(data.tokensUsed) +
            ' / ' + formatTokenCount(data.tokenBudget) +
            ' tokens (' + (data.progress || 0) + '%)';
        } else {
          span.textContent = formatTokenCount(data.tokensUsed) + ' tokens';
        }
      }
    }

    if (data.isComplete) {
      progressEl.style.display = 'none';
    }
  }

  function ensureMeter(container, taskId) {
    let meter = container.querySelector('.meter');
    if (!meter) {
      meter = document.createElement('div');
      meter.className = 'meter';
      const scanBar = container.querySelector('.scan-bar');
      if (scanBar) {
        scanBar.replaceWith(meter);
      } else {
        container.appendChild(meter);
      }
    }
    let fill = meter.querySelector('.meter-fill');
    if (!fill) {
      fill = document.createElement('div');
      fill.className = 'meter-fill';
      if (taskId) {
        fill.setAttribute('role', 'progressbar');
        fill.setAttribute('aria-valuemin', '0');
        fill.setAttribute('aria-valuemax', '100');
      }
      meter.appendChild(fill);
    }
    return fill;
  }

  function showScanBar(container) {
    if (container.querySelector('.scan-bar')) return;
    const scanBar = document.createElement('div');
    scanBar.className = 'scan-bar';
    const meter = container.querySelector('.meter');
    if (meter) {
      meter.replaceWith(scanBar);
    } else {
      container.appendChild(scanBar);
    }
  }

  function updateDashboardEvents(data) {
    const taskId = data.taskId;
    let eventsEl = document.getElementById('task-events-' + taskId);

    if (!eventsEl) {
      const card = document.querySelector('[id^="task-meter-' + taskId + '"]');
      const parent = card ? card.closest('.task-card-running') : null;
      if (!parent) return;
      eventsEl = document.createElement('div');
      eventsEl.className = 'task-events';
      eventsEl.id = 'task-events-' + taskId;
      parent.appendChild(eventsEl);
    }

    const maskClass = taskEventIconClass(data.kind);
    const iconClasses = ['task-event-icon', data.iconClass || '']
      .concat(maskClass ? ['icon', maskClass] : [])
      .filter(Boolean)
      .join(' ');

    const eventDiv = document.createElement('div');
    eventDiv.className = 'task-event';
    eventDiv.innerHTML =
      '<span class="' + ui.escapeHtml(iconClasses) + '" aria-hidden="true"></span>' +
      '<span>' + ui.escapeHtml(data.text || '') + '</span>';

    eventsEl.insertBefore(eventDiv, eventsEl.firstChild);
    while (eventsEl.children.length > 3) {
      eventsEl.removeChild(eventsEl.lastChild);
    }
  }

  function formatTokenCount(value) {
    if (value == null) return '0';
    return value.toLocaleString();
  }

  function currentTaskDetailId() {
    const detailPage = document.querySelector('.task-detail-page');
    return detailPage ? detailPage.getAttribute('data-task-id') : null;
  }

  function shouldRefreshTaskContent(taskId) {
    return Boolean(document.getElementById('tasks-content')) || currentTaskDetailId() === taskId;
  }

  function updateTaskBadge(count) {
    latestTaskReviewCount = count;
    const badge = document.getElementById('tasks-badge');
    if (!badge) return;
    if (count > 0) {
      badge.textContent = count;
    }
    badge.hidden = count <= 0;
  }

  function initTaskElapsedTimers() {
    const timers = document.querySelectorAll('.task-elapsed[data-started-at]');
    if (!timers.length) {
      if (taskElapsedTimer) {
        clearInterval(taskElapsedTimer);
        taskElapsedTimer = null;
      }
      return;
    }

    refreshTaskElapsedTimes();
    if (taskElapsedTimer) return;
    taskElapsedTimer = setInterval(refreshTaskElapsedTimes, 1000);
  }

  function initTaskDetailRefresh() {
    const detailPage = document.querySelector('.task-detail-page');
    if (!detailPage) {
      if (taskDetailRefreshTimer) {
        clearInterval(taskDetailRefreshTimer);
        taskDetailRefreshTimer = null;
      }
      return;
    }

    const statusText = detailPage
      .querySelector('.task-meta-card .status-badge')
      ?.textContent
      ?.trim()
      .toLowerCase();
    const shouldPoll = statusText === 'queued' || statusText === 'running';
    if (!shouldPoll) {
      if (taskDetailRefreshTimer) {
        clearInterval(taskDetailRefreshTimer);
        taskDetailRefreshTimer = null;
      }
      return;
    }

    if (taskDetailRefreshTimer) return;

    taskDetailRefreshTimer = setInterval(async () => {
      if (!document.querySelector('.task-detail-page')) {
        clearInterval(taskDetailRefreshTimer);
        taskDetailRefreshTimer = null;
        return;
      }

      await refreshTasksPageContent();

      const nextStatus = document
        .querySelector('.task-detail-page .task-meta-card .status-badge')
        ?.textContent
        ?.trim()
        .toLowerCase();
      if (nextStatus !== 'queued' && nextStatus !== 'running') {
        clearInterval(taskDetailRefreshTimer);
        taskDetailRefreshTimer = null;
      }
    }, 2000);
  }

  function refreshTaskElapsedTimes() {
    document.querySelectorAll('.task-elapsed[data-started-at]').forEach((el) => {
      const started = el.getAttribute('data-started-at');
      if (!started) return;
      const diff = Math.floor((Date.now() - new Date(started).getTime()) / 1000);
      if (diff < 0) {
        el.textContent = '--:--';
        return;
      }
      const m = Math.floor(diff / 60);
      const s = diff % 60;
      el.textContent = m + 'm ' + String(s).padStart(2, '0') + 's';
    });
  }

  function restoreTaskBadge() {
    if (latestTaskReviewCount !== null) {
      updateTaskBadge(latestTaskReviewCount);
    }
  }

  async function refreshTasksPageContent() {
    try {
      const response = await fetch(window.location.pathname + window.location.search, {
        headers: { 'HX-Request': 'true' },
      });
      if (!response.ok) return;

      const html = await response.text();
      const parsed = new DOMParser().parseFromString(html, 'text/html');
      const nextContent = parsed.getElementById('tasks-content');
      const currentContent = document.getElementById('tasks-content');
      if (!nextContent || !currentContent) return;

      currentContent.replaceWith(nextContent);
      reinitializeTaskUi();
      if (typeof shell.renderMarkdown === 'function') {
        shell.renderMarkdown();
      }
    } catch (_) {}
  }

  function initTaskListControls() {
    ui.initCustomSelects(document);
  }

  function initTaskDialogTabs() {
    const dialog = document.getElementById('new-task-dialog');
    if (!dialog || dialog.dataset.taskTabsInit) return;
    dialog.dataset.taskTabsInit = '1';

    const activate = (target, focus = false) => {
      let activeTab = null;
      dialog.querySelectorAll('[data-task-tab]').forEach((tab) => {
        const active = tab.dataset.taskTab === target;
        tab.classList.toggle('active', active);
        tab.setAttribute('aria-selected', active ? 'true' : 'false');
        tab.setAttribute('tabindex', active ? '0' : '-1');
        if (active) activeTab = tab;
      });
      dialog.querySelectorAll('[data-task-panel]').forEach((panel) => {
        panel.classList.toggle('active', panel.dataset.taskPanel === target);
      });
      dialog.querySelectorAll('[data-task-action]').forEach((actions) => {
        actions.hidden = actions.dataset.taskAction !== target;
      });
      if (focus) activeTab?.focus();
    };

    dialog.addEventListener('click', (event) => {
      const button = event.target.closest('[data-task-tab]');
      if (!button) return;
      activate(button.dataset.taskTab);
    });
    dialog.addEventListener('keydown', (event) => {
      const button = event.target.closest('[data-task-tab]');
      if (!button) return;
      const tabs = Array.from(dialog.querySelectorAll('[data-task-tab]'));
      const index = tabs.indexOf(button);
      let next = null;
      if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
      if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
      if (event.key === 'Home') next = tabs[0];
      if (event.key === 'End') next = tabs[tabs.length - 1];
      if (!next) return;
      event.preventDefault();
      activate(next.dataset.taskTab, true);
    });
  }

  function updateProjectStatusBadge(projectId, newStatus) {
    const card = document.querySelector('[data-project-id="' + projectId + '"]');
    if (!card) return;

    const badge = card.querySelector('.status-badge');
    if (badge) {
      const classMap = {
        ready: 'status-badge-success',
        cloning: 'status-badge-info',
        error: 'status-badge-error',
        stale: 'status-badge-warning',
      };
      badge.className = 'status-badge ' + (classMap[newStatus] || '');
      badge.textContent = newStatus.charAt(0).toUpperCase() + newStatus.slice(1);
    }

    const errorBanner = card.querySelector('[data-project-error]');
    if (newStatus === 'ready' && errorBanner) {
      errorBanner.style.display = 'none';
    } else if (newStatus !== 'ready' && newStatus !== 'cloning' && errorBanner) {
      errorBanner.style.display = '';
    }
  }

  function reinitializeTaskUi() {
    initTaskElapsedTimers();
    initTaskListControls();
    initTurnCancelActions();
    if (typeof workflowPage().onLoad === 'function') {
      workflowPage().onLoad();
    }
    initTaskDialogTabs();
    initTaskDetailRefresh();
  }

  function cleanupTaskController() {
    if (taskEventSource) {
      taskEventSource.close();
      taskEventSource = null;
    }
    if (taskElapsedTimer) {
      clearInterval(taskElapsedTimer);
      taskElapsedTimer = null;
    }
    if (taskDetailRefreshTimer) {
      clearInterval(taskDetailRefreshTimer);
      taskDetailRefreshTimer = null;
    }
  }

  const tasksControllerApi = {
    renderSidebar: updateTaskSidebar,
    onLoad() {
      initTaskSse();
      reinitializeTaskUi();
    },
    onAfterSwap(context) {
      const target = context ? context.target : null;
      if (target && target.id === 'main-content') {
        refreshSidebarTaskState();
      } else {
        restoreTaskBadge();
        updateTaskSidebar(cachedActiveTasks);
        updateRunningWorkflowsSection([]);
      }
      reinitializeTaskUi();
    },
    onHistoryRestore() {
      refreshSidebarTaskState();
      reinitializeTaskUi();
    },
    onBeforeSwap: cleanupTaskController,
  };

  dartclaw.tasksControllerApi = tasksControllerApi;

export default class DcTasksController extends Stimulus.Controller {
  connect() {
    if (this.element && this.element.matches('#new-task-dialog')) {
      initTaskDialogTabs();
      return;
    }
    this.taskControllerGeneration = ++taskControllerGeneration;
    tasksControllerApi.onLoad();
  }

  disconnect() {
    if (this.element && this.element.matches('#new-task-dialog')) return;
    if (this.taskControllerGeneration !== taskControllerGeneration) return;
    tasksControllerApi.onBeforeSwap();
  }
}
