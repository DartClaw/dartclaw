(() => {
  'use strict';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  dartclaw.pages = dartclaw.pages || {};

  const ui = dartclaw.ui;
  const workflowsPage = dartclaw.pages.workflows = dartclaw.pages.workflows || {};

  let cachedActiveWorkflows = [];
  let workflowNotificationCount = 0;
  let workflowEventSource = null;
  let cachedWorkflowDefs = null;
  let selectedWorkflow = null;

  function renderWorkflowSidebar(workflows) {
    cachedActiveWorkflows = Array.isArray(workflows) ? workflows : [];

    const existing = document.getElementById('sidebar-workflows');
    if (!cachedActiveWorkflows.length) {
      existing && existing.remove();
      return;
    }

    const sidebar = document.getElementById('sidebar');
    if (!sidebar) return;

    const runningSection = document.getElementById('sidebar-running');
    const chatsLabel = Array.from(sidebar.querySelectorAll('.sidebar-section-label'))
      .find((element) => element.textContent.trim() === 'Chats');
    if (!chatsLabel || !chatsLabel.parentNode) return;

    const itemsHtml = cachedActiveWorkflows.map((workflow) => {
      const workflowId = encodeURIComponent(workflow.id || '');
      const href = '/workflows/' + workflowId;
      const name = ui.escapeHtml(workflow.definitionName || 'Workflow');
      const progress = (workflow.completedSteps || 0) + '/' + (workflow.totalSteps || 0);
      const statusClass = workflow.status === 'paused'
        ? 'status-dot status-dot--warning'
        : 'status-dot status-dot--live';

      return (
        '<div class="session-item sidebar-workflow-item">' +
          '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
            ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML"' +
            ' hx-push-url="true" hx-select-oob="#topbar,#sidebar">' +
            '<span class="' + statusClass + '" aria-hidden="true"></span>' +
            '<span class="session-item-title">' + name + '</span>' +
            '<span class="workflow-step-progress">' + progress + '</span>' +
          '</a>' +
        '</div>'
      );
    }).join('');

    const container = document.createElement('div');
    container.id = 'sidebar-workflows';
    container.innerHTML =
      '<div class="sidebar-section-label sidebar-workflows-label">Workflows</div>' +
      itemsHtml +
      '<hr class="sidebar-divider sidebar-workflows-divider">';

    if (existing) {
      existing.replaceWith(container);
    } else {
      const insertBefore = runningSection ? runningSection.nextElementSibling : chatsLabel;
      if (insertBefore && insertBefore.parentNode) {
        insertBefore.parentNode.insertBefore(container, insertBefore);
      } else {
        chatsLabel.parentNode.insertBefore(container, chatsLabel);
      }
    }

    htmx.process(container);
  }

  function updateWorkflowBadge(count) {
    workflowNotificationCount = count;
    const badge = document.getElementById('workflows-badge');
    if (!badge) return;
    if (count > 0) {
      badge.textContent = count;
      badge.style.display = '';
    } else {
      badge.style.display = 'none';
    }
  }

  function incrementWorkflowNotification() {
    if (window.location.pathname === '/workflows') return;
    workflowNotificationCount++;
    updateWorkflowBadge(workflowNotificationCount);
  }

  function resetWorkflowNotification() {
    workflowNotificationCount = 0;
    updateWorkflowBadge(0);
  }

  function resetWorkflowNotificationIfOnWorkflowsPage() {
    if (window.location.pathname === '/workflows') {
      resetWorkflowNotification();
    }
  }

  function filterByDefinition(value) {
    const url = new URL(window.location.href);
    if (value) {
      url.searchParams.set('definition', value);
    } else {
      url.searchParams.delete('definition');
    }
    htmx.ajax('GET', url.pathname + url.search, {
      target: '#main-content',
      select: '#main-content',
      swap: 'outerHTML',
      headers: { 'HX-Push-Url': url.pathname + url.search },
    });
  }

  function bindWorkflowFilters() {
    const filter = document.getElementById('workflow-definition-filter');
    if (!filter || filter.dataset.workflowFilterInit) return;
    filter.dataset.workflowFilterInit = '1';
    filter.addEventListener('change', () => filterByDefinition(filter.value));
  }

  function fetchWorkflowDefinitions() {
    const listCards = document.querySelector('.workflow-list-cards');
    const loadingEl = document.querySelector('.workflow-list-loading');
    const emptyEl = document.querySelector('.workflow-list-empty');
    if (!listCards) return;

    const qs = dartclaw.shell && typeof dartclaw.shell.apiQs === 'function'
      ? dartclaw.shell.apiQs()
      : '';

    if (loadingEl) loadingEl.style.display = '';
    if (emptyEl) emptyEl.style.display = 'none';
    listCards.innerHTML = '';

    fetch('/api/workflows/definitions' + qs)
      .then((response) => {
        if (!response.ok) throw new Error('Failed to load workflows');
        return response.json();
      })
      .then((definitions) => {
        cachedWorkflowDefs = definitions;
        if (loadingEl) loadingEl.style.display = 'none';
        if (!definitions.length) {
          if (emptyEl) emptyEl.style.display = '';
          return;
        }
        listCards.innerHTML = definitions.map(renderWorkflowCard).join('');
        listCards.querySelectorAll('.workflow-card').forEach((card) => {
          card.addEventListener('click', () => selectWorkflow(card.dataset.workflowName));
        });
      })
      .catch((error) => {
        if (loadingEl) loadingEl.style.display = 'none';
        listCards.innerHTML =
          '<p class="empty-state-text">Failed to load workflows. ' +
          ui.escapeHtml(error.message) + '</p>';
      });
  }

  function renderWorkflowCard(definition) {
    const name = ui.escapeHtml(definition.name);
    const description = ui.escapeHtml(definition.description || '');
    const steps = definition.stepCount || 0;
    const loopBadge = definition.hasLoops
      ? '<span class="workflow-badge workflow-badge-loop">Loop</span>'
      : '';
    const variableCount = Object.keys(definition.variables || {}).length;
    return (
      '<div class="card workflow-card" data-workflow-name="' + name + '">' +
        '<div class="workflow-card-header">' +
          '<span class="workflow-card-name">' + formatWorkflowName(definition.name) + '</span>' +
          '<span class="workflow-card-steps">' + steps + ' step' + (steps !== 1 ? 's' : '') + '</span>' +
        '</div>' +
        '<div class="workflow-card-desc">' + description + '</div>' +
        '<div class="workflow-card-meta">' +
          '<span class="workflow-badge">' + variableCount + ' variable' + (variableCount !== 1 ? 's' : '') + '</span>' +
          loopBadge +
        '</div>' +
      '</div>'
    );
  }

  function formatWorkflowName(name) {
    return ui.escapeHtml(name.replace(/-/g, ' ').replace(/\b\w/g, (character) => character.toUpperCase()));
  }

  function selectWorkflow(name) {
    const formEl = document.getElementById('workflow-form');
    const varsEl = document.getElementById('workflow-vars');
    const projectEl = document.getElementById('workflow-project-select');

    if (selectedWorkflow === name) {
      selectedWorkflow = null;
      if (formEl) formEl.style.display = 'none';
      document.querySelectorAll('.workflow-card').forEach((card) => {
        card.classList.remove('workflow-card-selected');
      });
      return;
    }

    selectedWorkflow = name;
    const definition = (cachedWorkflowDefs || []).find((item) => item.name === name);
    if (!definition) return;

    document.querySelectorAll('.workflow-card').forEach((card) => {
      card.classList.toggle('workflow-card-selected', card.dataset.workflowName === name);
    });

    const variables = definition.variables || {};
    const variableNames = Object.keys(variables);

    if (varsEl) {
      if (!variableNames.length) {
        varsEl.innerHTML = '<p class="empty-state-text">This workflow has no input variables.</p>';
      } else {
        varsEl.innerHTML = variableNames.map((variableName) => {
          const variable = variables[variableName] || {};
          const isRequired = variable.required !== false;
          const label = formatVariableName(variableName);
          const placeholder = ui.escapeHtml(variable.description || '');
          const defaultVal = variable.default != null ? ui.escapeHtml(String(variable.default)) : '';
          const requiredAttr = isRequired ? ' required' : '';
          const requiredMark = isRequired ? ' <span class="form-required">*</span>' : '';
          const isLongForm = ['FEATURE', 'BUG_DESCRIPTION', 'QUESTION', 'TARGET'].includes(variableName);
          const inputHtml = isLongForm
            ? '<textarea class="form-input" name="wf-var-' + ui.escapeHtml(variableName) +
              '" rows="3" placeholder="' + placeholder + '"' + requiredAttr + '>' +
              defaultVal + '</textarea>'
            : '<input type="text" class="form-input" name="wf-var-' + ui.escapeHtml(variableName) +
              '" value="' + defaultVal + '" placeholder="' + placeholder + '"' +
              requiredAttr + '>';
          return (
            '<div class="form-group">' +
              '<label class="form-label">' + label + requiredMark + '</label>' +
              inputHtml +
            '</div>'
          );
        }).join('');
      }
    }

    const hasProjectVar = variableNames.some((key) => key.toUpperCase() === 'PROJECT');
    if (projectEl) projectEl.style.display = hasProjectVar ? '' : 'none';
    if (formEl) formEl.style.display = '';
  }

  function formatVariableName(name) {
    return ui.escapeHtml(name.toLowerCase().replace(/_/g, ' ').replace(/\b\w/g, (character) => character.toUpperCase()));
  }

  async function handleWorkflowSubmit(errorEl) {
    if (!selectedWorkflow) {
      if (errorEl) errorEl.textContent = 'Please select a workflow.';
      return false;
    }

    const definition = (cachedWorkflowDefs || []).find((item) => item.name === selectedWorkflow);
    if (!definition) {
      if (errorEl) errorEl.textContent = 'Selected workflow not found.';
      return false;
    }

    const variables = {};
    const variableNames = Object.keys(definition.variables || {});
    for (const variableName of variableNames) {
      const input = document.querySelector('[name="wf-var-' + variableName + '"]');
      if (!input) continue;
      const value = input.value.trim();
      if ((definition.variables[variableName] || {}).required !== false && !value) {
        if (errorEl) errorEl.textContent = formatVariableName(variableName) + ' is required.';
        input.focus();
        return false;
      }
      if (value) variables[variableName] = value;
    }

    const projectSelect = document.getElementById('workflow-project');
    const project = projectSelect ? projectSelect.value : '';
    if (project && definition.variables && definition.variables.PROJECT !== undefined) {
      variables.PROJECT = project;
    }

    const qs = dartclaw.shell && typeof dartclaw.shell.apiQs === 'function'
      ? dartclaw.shell.apiQs()
      : '';

    const body = { definition: selectedWorkflow, variables };
    if (project) body.project = project;

    try {
      const response = await fetch('/api/workflows/run' + qs, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (response.ok || response.status === 201) {
        const data = await response.json();
        const dialog = document.getElementById('new-task-dialog');
        if (dialog) dialog.close();
        if (data.id) {
          window.location.href = '/workflows/' + data.id + qs;
        } else {
          window.location.href = '/tasks' + qs;
        }
        return true;
      }

      const data = await response.json().catch(() => ({}));
      if (errorEl) {
        errorEl.textContent = (data.error && data.error.message) || 'Failed to start workflow';
      }
    } catch (_) {
      if (errorEl) errorEl.textContent = 'Failed to reach server';
    }
    return false;
  }

  function initWorkflowDialogTabs() {
    const tabBtns = document.querySelectorAll('[data-task-tab]');
    const tabPanels = document.querySelectorAll('[data-task-panel]');
    const submitBtn = document.getElementById('task-dialog-submit');
    const dialog = document.getElementById('new-task-dialog');
    if (!dialog) return;

    let workflowsFetched = false;

    tabBtns.forEach((btn) => {
      if (btn.dataset.taskTabInit) return;
      btn.dataset.taskTabInit = '1';
      btn.addEventListener('click', () => {
        const target = btn.dataset.taskTab;
        tabBtns.forEach((tab) => tab.classList.toggle('active', tab.dataset.taskTab === target));
        tabPanels.forEach((panel) => panel.classList.toggle('active', panel.dataset.taskPanel === target));
        if (submitBtn) {
          submitBtn.textContent = target === 'workflow' ? 'Run Workflow' : 'Create Task';
        }
        if (target === 'workflow' && !workflowsFetched) {
          workflowsFetched = true;
          fetchWorkflowDefinitions();
        }
        const errorEl = document.getElementById('new-task-error');
        if (errorEl) errorEl.textContent = '';
      });
    });

    if (dialog.dataset.workflowCloseInit) return;
    dialog.dataset.workflowCloseInit = '1';
    dialog.addEventListener('close', () => {
      selectedWorkflow = null;
      cachedWorkflowDefs = null;
      workflowsFetched = false;

      tabBtns.forEach((btn) => btn.classList.toggle('active', btn.dataset.taskTab === 'single'));
      tabPanels.forEach((panel) => panel.classList.toggle('active', panel.dataset.taskPanel === 'single'));

      if (submitBtn) submitBtn.textContent = 'Create Task';

      const listCards = document.querySelector('.workflow-list-cards');
      if (listCards) listCards.innerHTML = '';
      const formEl = document.getElementById('workflow-form');
      if (formEl) formEl.style.display = 'none';
      const loadingEl = document.querySelector('.workflow-list-loading');
      if (loadingEl) loadingEl.style.display = 'none';
      const emptyEl = document.querySelector('.workflow-list-empty');
      if (emptyEl) emptyEl.style.display = 'none';
      const errorEl = document.getElementById('new-task-error');
      if (errorEl) errorEl.textContent = '';
    });
  }

  function initWorkflowDetailSSE() {
    const detailPage = document.querySelector('.workflow-detail-page');
    if (!detailPage) {
      cleanupWorkflowSSE();
      return;
    }

    const runId = detailPage.getAttribute('data-run-id');
    if (!runId || workflowEventSource) return;

    workflowEventSource = new EventSource(
      '/api/workflows/runs/' + runId + '/events',
      { withCredentials: true }
    );

    workflowEventSource.onmessage = function(event) {
      try {
        const data = JSON.parse(event.data);
        handleWorkflowEvent(data);
      } catch (_) {}
    };

    workflowEventSource.onerror = function() {
      // Reconnect handled automatically by EventSource.
    };
  }

  function cleanupWorkflowSSE() {
    if (workflowEventSource) {
      workflowEventSource.close();
      workflowEventSource = null;
    }
  }

  function handleWorkflowEvent(data) {
    switch (data.type) {
      case 'connected':
        break;
      case 'workflow_status_changed':
        updateWorkflowStatus(data);
        break;
      case 'workflow_step_completed':
        updateStepCompleted(data);
        updateProgressBar(data);
        break;
      case 'task_status_changed':
        updateStepTaskStatus(data);
        break;
      case 'loop_iteration_completed':
        updateLoopIteration(data);
        break;
      case 'parallel_group_completed':
        updateParallelGroup(data);
        break;
    }
  }

  function updateWorkflowStatus(data) {
    const badge = document.querySelector('.workflow-meta-card .status-badge');
    if (badge) {
      badge.textContent = _wfTitleCase(data.newStatus);
      badge.className = 'status-badge status-badge-' + data.newStatus;
    }

    const errorEl = document.querySelector('.workflow-error-message');
    if (data.errorMessage && errorEl) {
      const msgSpan = errorEl.querySelector('span:last-child');
      if (msgSpan) msgSpan.textContent = data.errorMessage;
      errorEl.style.display = '';
    }

    const isRunning = data.newStatus === 'running';
    const isPaused = data.newStatus === 'paused';
    const isTerminal = ['completed', 'failed', 'cancelled'].includes(data.newStatus);

    document.querySelectorAll('.workflow-actions button').forEach((btn) => {
      const label = btn.textContent.trim();
      if (label === 'Pause') btn.style.display = isRunning ? '' : 'none';
      if (label === 'Resume') btn.style.display = isPaused ? '' : 'none';
      if (label === 'Cancel') btn.style.display = (isRunning || isPaused) ? '' : 'none';
    });

    if (isTerminal) cleanupWorkflowSSE();
  }

  function updateStepCompleted(data) {
    const stepCard = document.querySelector('.workflow-step-card[data-step-index="' + data.stepIndex + '"]');
    if (!stepCard) return;

    const status = data.success ? 'completed' : 'failed';
    const badge = stepCard.querySelector('.status-badge');
    if (badge) {
      badge.textContent = _wfTitleCase(status);
      badge.className = 'status-badge status-badge-' + status;
    }
    stepCard.classList.remove('workflow-step-active');
    stepCard.setAttribute('data-step-status', status);

    const nextStep = document.querySelector('.workflow-step-card[data-step-index="' + (data.stepIndex + 1) + '"]');
    if (nextStep && nextStep.getAttribute('data-step-status') === 'pending') {
      nextStep.classList.add('workflow-step-active');
      const nextBadge = nextStep.querySelector('.status-badge');
      if (nextBadge) {
        nextBadge.textContent = 'Running';
        nextBadge.className = 'status-badge status-badge-running';
      }
      nextStep.setAttribute('data-step-status', 'running');
      nextStep.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  }

  function updateStepTaskStatus(data) {
    if (data.stepIndex == null) return;
    const stepCard = document.querySelector('.workflow-step-card[data-step-index="' + data.stepIndex + '"]');
    if (!stepCard) return;

    const displayStatus = _mapTaskStatusToStepStatus(data.newStatus);
    const badge = stepCard.querySelector('.status-badge');
    if (badge) {
      badge.textContent = _wfTitleCase(displayStatus);
      badge.className = 'status-badge status-badge-' + displayStatus;
    }
    if (data.newStatus === 'running') {
      stepCard.classList.add('workflow-step-active');
    } else {
      stepCard.classList.remove('workflow-step-active');
    }
    stepCard.setAttribute('data-step-status', displayStatus);
  }

  function updateLoopIteration(data) {
    document.querySelectorAll('.workflow-loop-badge').forEach((badge) => {
      const stepCard = badge.closest('.workflow-step-card');
      if (stepCard && badge.getAttribute('data-loop-id') === data.loopId) {
        badge.textContent = 'Iteration ' + data.iteration + '/' + data.maxIterations;
      }
    });
  }

  function updateParallelGroup(data) {
    (data.stepIds || []).forEach((stepId) => {
      const stepCard = document.querySelector('.workflow-step-card[data-step-id="' + stepId + '"]');
      if (!stepCard) return;

      const badge = stepCard.querySelector('.status-badge');
      if (badge) {
        badge.textContent = 'Completed';
        badge.className = 'status-badge status-badge-completed';
      }
      stepCard.classList.remove('workflow-step-active');
      stepCard.setAttribute('data-step-status', 'completed');
    });
  }

  function updateProgressBar(data) {
    const fill = document.querySelector('.workflow-progress-fill');
    const label = document.querySelector('.workflow-progress-label');
    if (!fill || !data.totalSteps) return;

    const completed = document.querySelectorAll('.workflow-step-card[data-step-status="completed"]').length;
    const percent = Math.round((completed / data.totalSteps) * 100);
    fill.style.width = percent + '%';
    if (label) {
      label.innerHTML = '<span>' + completed + '</span> / <span>' + data.totalSteps + '</span> steps';
    }
  }

  function _mapTaskStatusToStepStatus(taskStatus) {
    switch (taskStatus) {
      case 'draft':
      case 'queued':
        return 'queued';
      case 'running':
        return 'running';
      case 'review':
        return 'review';
      case 'accepted':
      case 'completed':
        return 'completed';
      case 'failed':
        return 'failed';
      case 'cancelled':
        return 'cancelled';
      case 'rejected':
        return 'failed';
      default:
        return 'pending';
    }
  }

  function _wfTitleCase(value) {
    return value ? value.charAt(0).toUpperCase() + value.slice(1) : '';
  }

  function bindWorkflowDetailToggles() {
    if (document.body.dataset.workflowDetailToggleInit) return;
    document.body.dataset.workflowDetailToggleInit = '1';

    document.addEventListener('click', (event) => {
      const stepToggle = event.target.closest('[data-step-toggle]');
      if (stepToggle) {
        const stepCard = stepToggle.closest('.workflow-step-card');
        const detail = stepCard && stepCard.querySelector('.workflow-step-detail');
        if (!detail) return;
        const isHidden = detail.style.display === 'none';
        detail.style.display = isHidden ? '' : 'none';
        const icon = stepToggle.querySelector('.workflow-step-expand-icon');
        if (icon) {
          icon.classList.toggle('icon-chevron-up', isHidden);
          icon.classList.toggle('icon-chevron-down', !isHidden);
        }
        return;
      }

      const contextToggle = event.target.closest('[data-context-toggle]');
      if (!contextToggle) return;
      const viewer = contextToggle.closest('.workflow-context-viewer');
      const body = viewer && viewer.querySelector('.workflow-context-body');
      if (!body) return;
      const isHidden = body.style.display === 'none';
      body.style.display = isHidden ? '' : 'none';
      const icon = contextToggle.querySelector('.icon');
      if (icon) {
        icon.classList.toggle('icon-chevron-up', isHidden);
        icon.classList.toggle('icon-chevron-down', !isHidden);
      }
    });
  }

  function runWorkflowInitializers() {
    bindWorkflowFilters();
    bindWorkflowDetailToggles();
    initWorkflowDialogTabs();
    initWorkflowDetailSSE();
    resetWorkflowNotificationIfOnWorkflowsPage();
  }

  workflowsPage.renderSidebar = renderWorkflowSidebar;
  workflowsPage.restoreSidebar = function() {
    renderWorkflowSidebar(cachedActiveWorkflows);
  };
  workflowsPage.incrementNotification = incrementWorkflowNotification;
  workflowsPage.handleDialogSubmit = handleWorkflowSubmit;
  workflowsPage.onLoad = runWorkflowInitializers;
  workflowsPage.onAfterSwap = runWorkflowInitializers;
  workflowsPage.onHistoryRestore = runWorkflowInitializers;
  workflowsPage.onBeforeSwap = function(event) {
    const target = event && event.detail ? event.detail.target : null;
    if (!target || target.id === 'main-content') {
      cleanupWorkflowSSE();
    }
  };
})();
