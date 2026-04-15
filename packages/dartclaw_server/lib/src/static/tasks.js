(() => {
  'use strict';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  dartclaw.shell = dartclaw.shell || {};
  dartclaw.pages = dartclaw.pages || {};

  const ui = dartclaw.ui;
  const shell = dartclaw.shell;
  const tasksPage = dartclaw.pages.tasks = dartclaw.pages.tasks || {};

  let taskEventSource = null;
  let latestTaskReviewCount = null;
  let cachedActiveTasks = [];
  let taskElapsedTimer = null;
  let taskDetailRefreshTimer = null;

  function workflowPage() {
    return dartclaw.pages && dartclaw.pages.workflows ? dartclaw.pages.workflows : {};
  }

  function renderRunningSidebar(tasks) {
    cachedActiveTasks = Array.isArray(tasks) ? tasks : [];

    const existing = document.getElementById('sidebar-running');
    if (!cachedActiveTasks.length) {
      existing && existing.remove();
      return;
    }

    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;

    const chatsLabel = Array.from(sidebar.querySelectorAll('.sidebar-section-label'))
      .find((element) => element.textContent.trim() === 'Chats');
    if (!chatsLabel || !chatsLabel.parentNode) return;

    const itemsHtml = cachedActiveTasks.map((task) => {
      const taskId = encodeURIComponent(task.id || '');
      const href = '/tasks/' + taskId;
      const provider = ui.sanitizeClassToken(task.provider || 'claude', 'claude');
      const providerLabel = ui.escapeHtml(task.providerLabel || task.provider || 'Claude');
      const title = ui.escapeHtml(task.title || 'Untitled Task');
      const statusClass = task.status === 'review'
        ? 'status-dot status-dot--warning'
        : 'status-dot status-dot--live';
      const trailingMeta = task.status === 'review'
        ? '<span class="running-review-label">review</span>'
        : task.startedAt
          ? '<span class="task-elapsed running-elapsed" data-started-at="' +
              ui.escapeHtml(task.startedAt) +
              '"></span>'
          : '<span class="task-elapsed running-elapsed">--:--</span>';

      return (
        '<div class="session-item sidebar-running-item">' +
          '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
            ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML" hx-push-url="true"' +
            ' hx-select-oob="#topbar,#sidebar">' +
            '<span class="' + statusClass + '" aria-hidden="true"></span>' +
            '<span class="session-item-title">' + title + '</span>' +
            trailingMeta +
            '<span class="provider-badge provider-badge-' + provider + '">' + providerLabel + '</span>' +
          '</a>' +
        '</div>'
      );
    }).join('');

    const container = document.createElement('div');
    container.id = 'sidebar-running';
    container.innerHTML =
      '<div class="sidebar-section-label sidebar-running-label">Running</div>' +
      itemsHtml +
      '<hr class="sidebar-divider sidebar-running-divider">';

    if (existing) {
      existing.replaceWith(container);
    } else {
      chatsLabel.parentNode.insertBefore(container, chatsLabel);
    }

    htmx.process(container);
    initTaskElapsedTimers();
  }

  async function refreshSidebarTaskState() {
    if (!document.querySelector('[data-tasks-enabled]')) return;

    try {
      const response = await fetch('/api/tasks/sidebar-state');
      if (!response.ok) return;

      const payload = await response.json();
      latestTaskReviewCount = payload.reviewCount ?? 0;
      updateTaskBadge(latestTaskReviewCount);
      renderRunningSidebar(payload.activeTasks || []);
      if (typeof workflowPage().renderSidebar === 'function') {
        workflowPage().renderSidebar(payload.activeWorkflows || []);
      }
    } catch (_) {}
  }

  function initTaskSse() {
    if (taskEventSource || !document.querySelector('[data-tasks-enabled]')) return;
    try {
      taskEventSource = new EventSource('/api/tasks/events');
    } catch (_) {
      return;
    }

    taskEventSource.onmessage = function(event) {
      try {
        const data = JSON.parse(event.data);

        if (data.type === 'connected') {
          updateTaskBadge(data.reviewCount || 0);
          renderRunningSidebar(data.activeTasks || []);
          if (typeof workflowPage().renderSidebar === 'function') {
            workflowPage().renderSidebar(data.activeWorkflows || []);
          }
          if (Array.isArray(data.projects)) {
            data.projects.forEach((project) => updateProjectStatusBadge(project.id, project.status));
          }
          return;
        }

        if (data.type === 'task_status_changed') {
          updateTaskBadge(data.reviewCount || 0);
          renderRunningSidebar(data.activeTasks || []);
          if (Array.isArray(data.activeWorkflows) && typeof workflowPage().renderSidebar === 'function') {
            workflowPage().renderSidebar(data.activeWorkflows);
          }
          if (shouldRefreshTaskContent(data.taskId)) {
            refreshTasksPageContent();
          }
          return;
        }

        if (data.type === 'workflow_sidebar_update') {
          if (typeof workflowPage().renderSidebar === 'function') {
            workflowPage().renderSidebar(data.activeWorkflows || []);
          }
          if (data.notification && typeof workflowPage().incrementNotification === 'function') {
            workflowPage().incrementNotification();
          }
          return;
        }

        if (data.type === 'agent_state') {
          if (shouldRefreshTaskContent(data.currentTaskId)) {
            refreshTasksPageContent();
          }
          return;
        }

        if (data.type === 'project_status') {
          updateProjectStatusBadge(data.projectId, data.newStatus);
          updateProjectSelectorOption(data.projectId, data.newStatus);
          return;
        }

        if (data.type === 'task_progress') {
          updateTaskProgress(data);
          updateDashboardProgress(data);
          return;
        }

        if (data.type === 'task_event') {
          updateDashboardEvents(data);
        }
      } catch (_) {}
    };

    taskEventSource.onerror = function() {
      // EventSource auto-reconnects. No custom logic needed.
    };
  }

  function updateTaskProgress(data) {
    const taskId = data.taskId;

    const activityEl = document.getElementById('task-activity-text-' + taskId);
    if (activityEl && data.currentActivity) {
      activityEl.textContent = data.currentActivity;
    }

    const fillEl = document.getElementById('task-progress-fill-' + taskId);
    if (fillEl) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        fillEl.classList.remove('indeterminate');
        const pct = Math.min(Math.max(data.progress || 0, 0), 100);
        fillEl.style.width = pct + '%';
        fillEl.setAttribute('aria-valuenow', pct);
      } else {
        fillEl.classList.add('indeterminate');
      }
    }

    const labelEl = document.getElementById('task-progress-label-' + taskId);
    if (labelEl) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        labelEl.textContent = formatTokenCount(data.tokensUsed) +
          ' / ' + formatTokenCount(data.tokenBudget) +
          ' tokens (' + (data.progress || 0) + '%)';
      } else {
        labelEl.textContent = formatTokenCount(data.tokensUsed) + ' tokens used';
      }
    }

    const section = document.getElementById('task-progress-section');
    if (section) section.style.display = '';

    if (data.isComplete) {
      const activityIndicator = document.getElementById('task-activity-' + taskId);
      if (activityIndicator) activityIndicator.style.display = 'none';
    }
  }

  function updateDashboardProgress(data) {
    const taskId = data.taskId;
    const progressEl = document.getElementById('task-progress-' + taskId);
    if (!progressEl) return;

    const fillEl = progressEl.querySelector('.task-progress-fill');
    if (fillEl) {
      if (data.tokenBudget != null && data.tokenBudget > 0) {
        progressEl.classList.remove('task-progress-indeterminate');
        const pct = Math.min(Math.max(data.progress || 0, 0), 100);
        fillEl.style.width = pct + '%';
      } else {
        progressEl.classList.add('task-progress-indeterminate');
      }
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

  function updateDashboardEvents(data) {
    const taskId = data.taskId;
    let eventsEl = document.getElementById('task-events-' + taskId);

    if (!eventsEl) {
      const card = document.querySelector('[id^="task-progress-' + taskId + '"]');
      const parent = card ? card.closest('.task-card-running') : null;
      if (!parent) return;
      eventsEl = document.createElement('div');
      eventsEl.className = 'task-events';
      eventsEl.id = 'task-events-' + taskId;
      parent.appendChild(eventsEl);
    }

    const eventDiv = document.createElement('div');
    eventDiv.className = 'task-event';
    eventDiv.innerHTML =
      '<span class="task-event-icon ' + ui.escapeHtml(data.iconClass || '') + '">' +
      ui.escapeHtml(data.iconChar || '\u25CF') + '</span>' +
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
      badge.style.display = '';
    } else {
      badge.style.display = 'none';
    }
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

  async function refreshTaskDetailContent() {
    try {
      const response = await fetch(window.location.pathname + window.location.search, {
        headers: { 'HX-Request': 'true' },
      });
      if (!response.ok) return;

      const html = await response.text();
      const parsed = new DOMParser().parseFromString(html, 'text/html');
      const nextContent = parsed.getElementById('main-content');
      const currentContent = document.getElementById('main-content');
      if (!nextContent || !currentContent) return;

      currentContent.replaceWith(nextContent);
      reinitializeTaskUi();
      if (typeof shell.renderMarkdown === 'function') {
        shell.renderMarkdown();
      }
    } catch (_) {}
  }

  function applyTaskFilters() {
    const status = document.getElementById('task-status-filter');
    const type = document.getElementById('task-type-filter');
    const params = new URLSearchParams();
    if (status && status.value) params.set('status', status.value);
    if (type && type.value) params.set('type', type.value);
    const qs = params.toString();
    window.location.href = '/tasks' + (qs ? '?' + qs : '');
  }

  function initTaskListControls() {
    ui.initCustomSelects(document);

    document.querySelectorAll('[data-task-filter]').forEach((select) => {
      if (select.dataset.taskFilterInit) return;
      select.dataset.taskFilterInit = '1';
      select.addEventListener('change', applyTaskFilters);
    });

    document.querySelectorAll('[data-task-dialog-open]').forEach((button) => {
      if (button.dataset.taskDialogOpenInit) return;
      button.dataset.taskDialogOpenInit = '1';
      button.addEventListener('click', () => {
        const dialog = document.getElementById('new-task-dialog');
        if (dialog) dialog.showModal();
      });
    });

    document.querySelectorAll('[data-task-dialog-close]').forEach((button) => {
      if (button.dataset.taskDialogCloseInit) return;
      button.dataset.taskDialogCloseInit = '1';
      button.addEventListener('click', () => {
        const dialog = button.closest('dialog');
        if (dialog) dialog.close();
      });
    });
  }

  function initTaskReviewActions() {
    const reviewBar = document.querySelector('.task-review-bar');
    if (!reviewBar || reviewBar.dataset.reviewInit) return;
    reviewBar.dataset.reviewInit = '1';

    const page = document.querySelector('.task-detail-page');
    const taskId = page ? page.getAttribute('data-task-id') : null;
    if (!taskId) return;

    const qs = typeof shell.apiQs === 'function' ? shell.apiQs() : '';

    reviewBar.addEventListener('click', async (event) => {
      const btn = event.target.closest('[data-action]');
      if (!btn) return;
      const action = btn.getAttribute('data-action');

      if (action === 'push_back') {
        const commentArea = reviewBar.querySelector('.pushback-comment');
        if (commentArea && commentArea.style.display === 'none') {
          commentArea.style.display = '';
          return;
        }
      }

      if (action === 'push_back') {
        return;
      }

      try {
        const response = await fetch('/api/tasks/' + taskId + '/review' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: action }),
        });
        if (response.ok) {
          window.location.href = '/tasks' + qs;
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Review action failed');
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
      }
    });

    const submitBtn = reviewBar.querySelector('.btn-pushback-submit');
    if (!submitBtn) return;
    submitBtn.addEventListener('click', async () => {
      const textarea = document.getElementById('pushback-comment');
      const comment = textarea ? textarea.value.trim() : '';
      if (!comment) {
        ui.showToast('error', 'Comment is required for push back');
        return;
      }
      try {
        const response = await fetch('/api/tasks/' + taskId + '/review' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'push_back', comment: comment }),
        });
        if (response.ok) {
          window.location.href = '/tasks' + qs;
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Push back failed');
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
      }
    });
  }

  function initTaskStartActions() {
    const page = document.querySelector('.task-detail-page');
    if (!page) return;

    const startBtn = page.querySelector('[data-task-start]');
    if (!startBtn || startBtn.dataset.taskStartInit) return;
    startBtn.dataset.taskStartInit = '1';

    const taskId = page.getAttribute('data-task-id');
    if (!taskId) return;

    const qs = typeof shell.apiQs === 'function' ? shell.apiQs() : '';

    startBtn.addEventListener('click', async () => {
      startBtn.disabled = true;
      try {
        const response = await fetch('/api/tasks/' + taskId + '/start' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({}),
        });
        if (response.ok) {
          window.location.reload();
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Failed to start task');
          startBtn.disabled = false;
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
        startBtn.disabled = false;
      }
    });
  }

  function initTaskCancelActions() {
    const page = document.querySelector('.task-detail-page');
    if (!page) return;

    const cancelBtn = page.querySelector('[data-task-cancel]');
    if (!cancelBtn || cancelBtn.dataset.taskCancelInit) return;
    cancelBtn.dataset.taskCancelInit = '1';

    const taskId = page.getAttribute('data-task-id');
    if (!taskId) return;

    const qs = typeof shell.apiQs === 'function' ? shell.apiQs() : '';

    cancelBtn.addEventListener('click', async () => {
      cancelBtn.disabled = true;
      try {
        const response = await fetch('/api/tasks/' + taskId + '/cancel' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({}),
        });
        if (response.ok) {
          window.location.href = '/tasks' + qs;
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Failed to cancel task');
          cancelBtn.disabled = false;
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
        cancelBtn.disabled = false;
      }
    });
  }

  function initNewTaskForm() {
    const form = document.getElementById('new-task-form');
    if (!form || form.dataset.taskFormInit) return;
    form.dataset.taskFormInit = '1';
    ui.initCustomSelects(form);

    const qs = typeof shell.apiQs === 'function' ? shell.apiQs() : '';
    const typeSelect = form.querySelector('[name="type"]');
    const goalSelect = form.querySelector('[name="goalId"]');
    const hintEl = form.querySelector('[data-task-type-hint]');
    const descriptionLabel = form.querySelector('[data-task-description-label]');
    const descriptionInput = form.querySelector('[data-task-description-input]');
    const criteriaLabel = form.querySelector('[data-task-criteria-label]');
    const criteriaInput = form.querySelector('[data-task-criteria-input]');

    const typeConfig = {
      coding: {
        hint: 'Coding tasks run in isolated git worktrees and produce diffs for review.',
        descriptionLabel: 'Implementation Brief',
        descriptionPlaceholder: 'What should change in the codebase?',
        criteriaLabel: 'Definition of Done',
        criteriaPlaceholder: 'What files, behaviors, or tests should be complete?',
      },
      research: {
        hint: 'Research tasks produce reviewable written artifacts and can run in the restricted profile.',
        descriptionLabel: 'Research Brief',
        descriptionPlaceholder: 'What should the agent investigate or summarize?',
        criteriaLabel: 'Success Criteria',
        criteriaPlaceholder: 'What should the final write-up answer or include?',
      },
      writing: {
        hint: 'Writing tasks focus on producing polished documents or copy for review.',
        descriptionLabel: 'Writing Brief',
        descriptionPlaceholder: 'What should the agent write or rewrite?',
        criteriaLabel: 'Editorial Criteria',
        criteriaPlaceholder: 'Tone, audience, structure, and completion criteria',
      },
      analysis: {
        hint: 'Analysis tasks are best for diagnostics, comparisons, and structured conclusions.',
        descriptionLabel: 'Analysis Brief',
        descriptionPlaceholder: 'What should the agent analyze?',
        criteriaLabel: 'Expected Output',
        criteriaPlaceholder: 'What conclusion, report, or artifact should come back?',
      },
      automation: {
        hint: 'Automation tasks are useful for repeatable operational runs that still end in review.',
        descriptionLabel: 'Automation Brief',
        descriptionPlaceholder: 'What repeatable operation should the agent run?',
        criteriaLabel: 'Completion Check',
        criteriaPlaceholder: 'What makes the run successful and ready for review?',
      },
      custom: {
        hint: 'Custom tasks use the generic task pipeline when none of the standard types fit cleanly.',
        descriptionLabel: 'Task Brief',
        descriptionPlaceholder: 'Describe the task clearly and concretely.',
        criteriaLabel: 'Acceptance Criteria',
        criteriaPlaceholder: 'How will you know when it is done?',
      },
    };

    function applyTaskTypeFormBehavior() {
      const config = typeConfig[(typeSelect && typeSelect.value) || 'custom'] || typeConfig.custom;
      if (hintEl) hintEl.textContent = config.hint;
      if (descriptionLabel) descriptionLabel.textContent = config.descriptionLabel;
      if (descriptionInput) descriptionInput.placeholder = config.descriptionPlaceholder;
      if (criteriaLabel) criteriaLabel.textContent = config.criteriaLabel;
      if (criteriaInput) criteriaInput.placeholder = config.criteriaPlaceholder;
    }

    if (typeSelect && !typeSelect.dataset.taskTypeInit) {
      typeSelect.dataset.taskTypeInit = '1';
      typeSelect.addEventListener('change', applyTaskTypeFormBehavior);
    }
    applyTaskTypeFormBehavior();

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const errorEl = document.getElementById('new-task-error');

      const activePanel = document.querySelector('[data-task-panel].active');
      const isWorkflow = activePanel && activePanel.dataset.taskPanel === 'workflow';
      if (isWorkflow && typeof workflowPage().handleDialogSubmit === 'function') {
        await workflowPage().handleDialogSubmit(errorEl);
        return;
      }

      const title = form.querySelector('[name="title"]').value.trim();
      const description = form.querySelector('[name="description"]').value.trim();
      const type = form.querySelector('[name="type"]').value;
      const goalId = goalSelect ? goalSelect.value.trim() : '';
      const acceptanceCriteria = form.querySelector('[name="acceptanceCriteria"]').value.trim();
      const model = form.querySelector('[name="model"]').value.trim();
      const tokenBudget = form.querySelector('[name="tokenBudget"]').value.trim();
      const allowedToolsChecked = Array.from(form.querySelectorAll('[name="allowedTools"]:checked')).map((cb) => cb.value);
      const reviewMode = (form.querySelector('[name="reviewMode"]') || {}).value || '';
      const autoStart = form.querySelector('[name="autoStart"]').checked;

      if (!title || !description || !type) {
        if (errorEl) errorEl.textContent = 'Title, description, and type are required.';
        return;
      }

      const projectSelect = form.querySelector('[name="projectId"]');
      const projectId = projectSelect ? projectSelect.value.trim() : '';

      const body = { title, description, type, autoStart };
      if (goalId) body.goalId = goalId;
      if (projectId) body.projectId = projectId;
      if (acceptanceCriteria) body.acceptanceCriteria = acceptanceCriteria;
      if (model) body.configJson = { model };
      if (tokenBudget) body.configJson = { ...(body.configJson || {}), tokenBudget: parseInt(tokenBudget, 10) };
      if (allowedToolsChecked.length > 0) body.configJson = { ...(body.configJson || {}), allowedTools: allowedToolsChecked };
      if (reviewMode) body.configJson = { ...(body.configJson || {}), reviewMode };

      try {
        const response = await fetch('/api/tasks' + qs, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (response.ok || response.status === 201) {
          const data = await response.json();
          const dialog = document.getElementById('new-task-dialog');
          if (dialog) dialog.close();
          window.location.href = '/tasks/' + data.id + qs;
        } else {
          const data = await response.json().catch(() => ({}));
          if (errorEl) errorEl.textContent = data.error?.message || 'Failed to create task';
        }
      } catch (_) {
        if (errorEl) errorEl.textContent = 'Failed to reach server';
      }
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

    const errorBanner = card.querySelector('.project-error-banner');
    if (newStatus === 'ready' && errorBanner) {
      errorBanner.style.display = 'none';
    } else if (newStatus !== 'ready' && newStatus !== 'cloning' && errorBanner) {
      errorBanner.style.display = '';
    }
  }

  function updateProjectSelectorOption(projectId, newStatus) {
    ['task-project-select', 'workflow-project'].forEach((selectId) => {
      const select = document.getElementById(selectId);
      if (!select) return;

      const option = select.querySelector('option[value="' + projectId + '"]');
      if (!option) return;

      const isReady = newStatus === 'ready';
      option.disabled = !isReady;

      if (selectId === 'workflow-project') {
        return;
      }

      const baseName = option.textContent
        .replace(/ [\u2713\u26a0]$/, '')
        .replace(/ \(cloning\)$/, '')
        .replace(/ \(error\)$/, '')
        .trim();
      const indicator = newStatus === 'ready'
        ? ' \u2713'
        : newStatus === 'cloning'
          ? ' (cloning)'
          : newStatus === 'error'
            ? ' (error)'
            : newStatus === 'stale'
              ? ' \u26a0'
              : '';
      option.textContent = baseName + indicator;
    });
  }

  function initProjectHandlers() {
    if (document.body.dataset.projectHandlersInit) return;
    document.body.dataset.projectHandlersInit = '1';

    document.addEventListener('click', (event) => {
      if (event.target.closest('[data-project-dialog-open]')) {
        const dialog = document.getElementById('add-project-dialog');
        if (dialog) {
          dialog.querySelector('form')?.reset();
          const errorEl = dialog.querySelector('#add-project-error');
          if (errorEl) errorEl.textContent = '';
          dialog.showModal();
        }
      }
    });

    document.addEventListener('click', (event) => {
      if (event.target.closest('[data-project-dialog-close]')) {
        const dialog = document.getElementById('add-project-dialog');
        if (dialog) dialog.close();
      }
    });

    document.addEventListener('submit', async (event) => {
      if (event.target.id !== 'add-project-form') return;
      event.preventDefault();
      const form = event.target;
      const errorEl = document.getElementById('add-project-error');

      const remoteUrl = form.querySelector('[name="remoteUrl"]')?.value.trim() || '';
      const name = form.querySelector('[name="name"]')?.value.trim() || '';
      const defaultBranch = form.querySelector('[name="defaultBranch"]')?.value.trim() || 'main';
      const credentialsRef = form.querySelector('[name="credentialsRef"]')?.value.trim() || '';
      const prStrategy = form.querySelector('[name="prStrategy"]')?.value || 'branchOnly';
      const draft = form.querySelector('[name="draft"]')?.checked ?? true;
      const labelsRaw = form.querySelector('[name="labels"]')?.value.trim() || '';
      const labels = labelsRaw ? labelsRaw.split(',').map((label) => label.trim()).filter(Boolean) : [];

      if (!remoteUrl || !name) {
        if (errorEl) errorEl.textContent = 'Remote URL and Name are required.';
        return;
      }

      const body = { remoteUrl, name, defaultBranch, pr: { strategy: prStrategy, draft, labels } };
      if (credentialsRef) body.credentialsRef = credentialsRef;

      try {
        const response = await fetch('/api/projects', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (response.ok || response.status === 201) {
          const dialog = document.getElementById('add-project-dialog');
          if (dialog) dialog.close();
          window.location.reload();
        } else {
          const data = await response.json().catch(() => ({}));
          if (errorEl) errorEl.textContent = data.error?.message || 'Failed to add project';
        }
      } catch (_) {
        if (errorEl) errorEl.textContent = 'Failed to reach server';
      }
    });

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('[data-project-fetch]');
      if (!btn) return;
      const projectId = btn.dataset.projectFetch;
      btn.disabled = true;
      const origText = btn.textContent;
      btn.textContent = 'Fetching…';
      try {
        const response = await fetch('/api/projects/' + projectId + '/fetch', { method: 'POST' });
        if (response.ok) {
          window.location.reload();
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Fetch failed');
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
      } finally {
        btn.disabled = false;
        btn.textContent = origText;
      }
    });

    document.addEventListener('click', async (event) => {
      const btn = event.target.closest('[data-project-remove]');
      if (!btn) return;
      const projectId = btn.dataset.projectRemove;
      const projectName = btn.dataset.projectName || projectId;
      const confirmed = window.confirm(
        'Remove project \'' + projectName + '\'? Running tasks will be cancelled.'
      );
      if (!confirmed) return;
      try {
        const response = await fetch('/api/projects/' + projectId, { method: 'DELETE' });
        if (response.ok || response.status === 204) {
          window.location.reload();
        } else {
          const data = await response.json().catch(() => ({}));
          ui.showToast('error', data.error?.message || 'Failed to remove project');
        }
      } catch (_) {
        ui.showToast('error', 'Failed to reach server');
      }
    });

    document.addEventListener('click', (event) => {
      const btn = event.target.closest('[data-project-edit]');
      if (!btn) return;
      const projectId = btn.dataset.projectEdit;
      const dialog = document.getElementById('add-project-dialog');
      if (!dialog) return;

      dialog.querySelector('h2').textContent = 'Edit Project';
      dialog.querySelector('[type="submit"]').textContent = 'Save Changes';
      const form = dialog.querySelector('form');
      form.dataset.editProjectId = projectId;
      const errorEl = dialog.querySelector('#add-project-error');
      if (errorEl) errorEl.textContent = '';

      const setVal = (name, value) => {
        const el = form.querySelector('[name="' + name + '"]');
        if (el) el.value = value || '';
      };
      const setChecked = (name, value) => {
        const el = form.querySelector('[name="' + name + '"]');
        if (el) el.checked = value === 'true' || value === true;
      };
      setVal('remoteUrl', btn.dataset.projectUrl);
      setVal('name', btn.dataset.projectName);
      setVal('defaultBranch', btn.dataset.projectBranch);
      setVal('credentialsRef', btn.dataset.projectCreds);
      setVal('prStrategy', btn.dataset.projectStrategy);
      setChecked('draft', btn.dataset.projectDraft);
      setVal('labels', btn.dataset.projectLabels);

      dialog.showModal();
    });

    document.addEventListener('submit', async (event) => {
      if (event.target.id !== 'add-project-form') return;
      const form = event.target;
      const editProjectId = form.dataset.editProjectId;
      if (!editProjectId) return;
      event.stopImmediatePropagation();
      event.preventDefault();

      const errorEl = document.getElementById('add-project-error');
      const remoteUrl = form.querySelector('[name="remoteUrl"]')?.value.trim() || '';
      const name = form.querySelector('[name="name"]')?.value.trim() || '';
      const defaultBranch = form.querySelector('[name="defaultBranch"]')?.value.trim() || 'main';
      const credentialsRef = form.querySelector('[name="credentialsRef"]')?.value.trim() || '';
      const prStrategy = form.querySelector('[name="prStrategy"]')?.value || 'branchOnly';
      const draft = form.querySelector('[name="draft"]')?.checked ?? true;
      const labelsRaw = form.querySelector('[name="labels"]')?.value.trim() || '';
      const labels = labelsRaw ? labelsRaw.split(',').map((label) => label.trim()).filter(Boolean) : [];

      const body = { name, defaultBranch, pr: { strategy: prStrategy, draft, labels } };
      if (remoteUrl) body.remoteUrl = remoteUrl;
      if (credentialsRef) body.credentialsRef = credentialsRef;

      try {
        const response = await fetch('/api/projects/' + editProjectId, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (response.ok) {
          delete form.dataset.editProjectId;
          const dialog = document.getElementById('add-project-dialog');
          if (dialog) {
            dialog.querySelector('h2').textContent = 'Add Project';
            dialog.querySelector('[type="submit"]').textContent = 'Add Project';
            dialog.close();
          }
          window.location.reload();
        } else if (response.status === 409) {
          const data = await response.json().catch(() => ({}));
          if (errorEl) errorEl.textContent = data.error?.message || 'Cannot edit: active tasks exist on this project';
        } else {
          const data = await response.json().catch(() => ({}));
          if (errorEl) errorEl.textContent = data.error?.message || 'Failed to update project';
        }
      } catch (_) {
        if (errorEl) errorEl.textContent = 'Failed to reach server';
      }
    }, true);
  }

  function reinitializeTaskUi() {
    initTaskElapsedTimers();
    initTaskListControls();
    initTaskReviewActions();
    initTaskStartActions();
    initTaskCancelActions();
    if (typeof workflowPage().onLoad === 'function') {
      workflowPage().onLoad();
    }
    initNewTaskForm();
    initTaskDetailRefresh();
    initProjectHandlers();
  }

  tasksPage.renderSidebar = renderRunningSidebar;
  tasksPage.onLoad = function() {
    initTaskSse();
    reinitializeTaskUi();
  };
  tasksPage.onAfterSwap = function(context) {
    const target = context ? context.target : null;
    if (target && target.id === 'main-content') {
      refreshSidebarTaskState();
    } else {
      restoreTaskBadge();
      renderRunningSidebar(cachedActiveTasks);
      if (typeof workflowPage().restoreSidebar === 'function') {
        workflowPage().restoreSidebar();
      }
    }
    reinitializeTaskUi();
  };
  tasksPage.onHistoryRestore = function() {
    refreshSidebarTaskState();
    reinitializeTaskUi();
  };
})();
