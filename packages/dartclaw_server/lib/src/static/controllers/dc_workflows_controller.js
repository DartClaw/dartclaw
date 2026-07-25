import { updateRunningWorkflowsSection } from './sidebar_sections.js';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  const ui = dartclaw.ui;
  let cachedActiveWorkflows = [];
  let workflowNotificationCount = 0;
  let cachedWorkflowDefs = null;
  let selectedWorkflow = null;

  function updateWorkflowSidebar(workflows) {
    cachedActiveWorkflows = updateRunningWorkflowsSection(workflows);
  }

  function updateWorkflowBadge(count) {
    workflowNotificationCount = count;
    const badge = document.getElementById('workflows-badge');
    if (!badge) return;
    if (count > 0) {
      badge.textContent = count;
    }
    badge.hidden = count <= 0;
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

    if (loadingEl) loadingEl.hidden = false;
    if (emptyEl) emptyEl.hidden = true;
    listCards.innerHTML = '';

    fetch('/api/workflows/definitions' + qs)
      .then((response) => {
        if (!response.ok) throw new Error('Failed to load workflows');
        return response.json();
      })
      .then((definitions) => {
        cachedWorkflowDefs = definitions;
        if (loadingEl) loadingEl.hidden = true;
        if (!definitions.length) {
          if (emptyEl) emptyEl.hidden = false;
          return;
        }
        listCards.innerHTML = definitions.map(renderWorkflowCard).join('');
        listCards.querySelectorAll('.workflow-card').forEach((card) => {
          card.addEventListener('click', () => selectWorkflow(card.dataset.workflowName));
        });
      })
      .catch((error) => {
        if (loadingEl) loadingEl.hidden = true;
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
      if (formEl) formEl.hidden = true;
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
    if (projectEl) projectEl.hidden = !hasProjectVar;
    if (formEl) formEl.hidden = false;
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
      if (formEl) formEl.hidden = true;
      const loadingEl = document.querySelector('.workflow-list-loading');
      if (loadingEl) loadingEl.hidden = true;
      const emptyEl = document.querySelector('.workflow-list-empty');
      if (emptyEl) emptyEl.hidden = true;
      const errorEl = document.getElementById('new-task-error');
      if (errorEl) errorEl.textContent = '';
    });
  }

  function initWorkflowDetailSSE(owner) {
    const detailPage = document.querySelector('.workflow-detail-page');
    if (!detailPage) {
      cleanupWorkflowSSE(owner);
      return;
    }

    const runId = detailPage.getAttribute('data-run-id');
    const runStatus = detailPage.getAttribute('data-run-status');
    if (['completed', 'failed', 'cancelled'].includes(runStatus)) {
      cleanupWorkflowSSE(owner);
      return;
    }
    if (!runId || owner.workflowEventSource) return;

    owner.workflowEventSource = new EventSource(
      '/api/workflows/runs/' + runId + '/events',
      { withCredentials: true }
    );

    owner.workflowEventSource.onmessage = function(event) {
      try {
        const data = JSON.parse(event.data);
        handleWorkflowEvent(data, owner);
      } catch (_) {}
    };

    owner.workflowEventSource.onerror = function() {
      // Reconnect handled automatically by EventSource.
    };
  }

  function cleanupWorkflowSSE(owner) {
    if (owner.workflowEventSource) {
      owner.workflowEventSource.close();
      owner.workflowEventSource = null;
    }
  }

  function handleWorkflowEvent(data, owner) {
    switch (data.type) {
      case 'connected':
        if (data.run && data.run.status) {
          const detailPage = document.querySelector('.workflow-detail-page');
          const statusChanged = detailPage && detailPage.getAttribute('data-run-status') !== data.run.status;
          const stepsChanged = _connectedStepsDiffer(data.steps);
          if (statusChanged || stepsChanged) {
            refreshWorkflowDetail(owner);
          }
        }
        break;
      case 'workflow_status_changed':
        refreshWorkflowDetail(owner);
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

  function _connectedStepsDiffer(steps) {
    if (!Array.isArray(steps)) return false;
    return steps.some((step) => {
      const stepCard = document.querySelector('.workflow-step-card[data-step-index="' + step.index + '"]');
      return !stepCard || stepCard.getAttribute('data-step-status') !== step.status;
    });
  }

  function refreshWorkflowDetail(owner) {
    if (!document.querySelector('.workflow-detail-page')) return;
    cleanupWorkflowSSE(owner);
    const qs = dartclaw.shell && typeof dartclaw.shell.apiQs === 'function'
      ? dartclaw.shell.apiQs()
      : '';
    htmx.ajax('GET', window.location.pathname + qs, {
      target: '#main-content',
      select: '#main-content',
      swap: 'outerHTML',
    });
  }

  function updateStepCompleted(data) {
    const stepCard = document.querySelector('.workflow-step-card[data-step-index="' + data.stepIndex + '"]');
    if (!stepCard) return;

    const status = _mapStepCompletionStatus(data);
    _updateWorkflowStepVisual(stepCard, status);
  }

  function updateStepTaskStatus(data) {
    if (data.stepIndex == null) return;
    const stepCard = document.querySelector('.workflow-step-card[data-step-index="' + data.stepIndex + '"]');
    if (!stepCard) return;

    const displayStatus = _mapTaskStatusToStepStatus(data.newStatus);
    _updateWorkflowStepVisual(stepCard, displayStatus);
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
    if (data.failureCount > 0) return;

    (data.stepIds || []).forEach((stepId) => {
      const stepCard = document.querySelector('.workflow-step-card[data-step-id="' + stepId + '"]');
      if (!stepCard) return;

      _updateWorkflowStepVisual(stepCard, 'completed');
    });
  }

  function _updateWorkflowStepVisual(stepCard, status) {
    const icon = stepCard.querySelector('.workflow-step-icon');
    if (icon) {
      for (const className of [...icon.classList]) {
        if (className.startsWith('workflow-step-icon--')) icon.classList.remove(className);
      }
      icon.classList.add('workflow-step-icon--' + status);
      icon.textContent = _workflowStepIcon(status);
    }
    stepCard.classList.toggle('workflow-step-active', status === 'running');
    stepCard.setAttribute('data-step-status', status);
  }

  function _workflowStepIcon(status) {
    switch (status) {
      case 'completed':
        return '✓';
      case 'running':
        return '•';
      case 'interrupted':
        return '!';
      case 'failed':
      case 'rejected':
        return '✗';
      case 'awaiting_approval':
        return '●';
      default:
        return '○';
    }
  }

  function updateProgressBar(data) {
    const section = document.querySelector('.workflow-progress-section');
    const fill = section?.querySelector('.meter-fill');
    const label = section?.querySelector('.workflow-progress-label');
    const percentage = section?.querySelector('.workflow-progress-pct');
    if (!fill || !data.totalSteps) return;

    const completed = document.querySelectorAll('.workflow-step-card[data-step-status="completed"]').length;
    const percent = Math.round((completed / data.totalSteps) * 100);
    fill.style.width = percent + '%';
    if (label) {
      label.textContent = completed + ' / ' + data.totalSteps + ' steps complete';
    }
    if (percentage) percentage.textContent = percent + '%';
  }

  function _mapTaskStatusToStepStatus(taskStatus) {
    switch (taskStatus) {
      case 'draft':
      case 'queued':
        return 'queued';
      case 'running':
        return 'running';
      case 'interrupted':
        return 'interrupted';
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

  function _mapStepCompletionStatus(data) {
    switch (data.outcome) {
      case 'succeeded':
        return 'completed';
      case 'failed':
        return 'failed';
      case 'needsInput':
      case 'blocked':
        return 'interrupted';
      case 'cancelled':
        return 'cancelled';
      default:
        return data.success ? 'completed' : 'failed';
    }
  }

  function _showStepDetailError(source) {
    const loading = source.querySelector('[data-step-detail-loading]');
    const error = source.querySelector('[data-step-detail-error]');
    if (loading) loading.hidden = true;
    if (error) error.hidden = false;
  }

  function _retryStepDetail(button) {
    const source = button.closest('.workflow-step-detail-loading');
    if (!source) return;
    const loading = source.querySelector('[data-step-detail-loading]');
    const error = source.querySelector('[data-step-detail-error]');
    if (loading) loading.hidden = false;
    if (error) error.hidden = true;
    htmx.trigger(source, 'workflow-step-detail-retry');
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
        const isHidden = detail.hidden;
        detail.hidden = !isHidden;
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
      const isHidden = body.hidden;
      body.hidden = !isHidden;
      const icon = contextToggle.querySelector('.icon');
      if (icon) {
        icon.classList.toggle('icon-chevron-up', isHidden);
        icon.classList.toggle('icon-chevron-down', !isHidden);
      }
    });
  }

  function runWorkflowInitializers(owner) {
    bindWorkflowFilters();
    bindWorkflowDetailToggles();
    initWorkflowDialogTabs();
    if (owner) initWorkflowDetailSSE(owner);
    resetWorkflowNotificationIfOnWorkflowsPage();
  }

  const workflowsControllerApi = {
    renderSidebar: updateWorkflowSidebar,
    restoreSidebar() {
      updateWorkflowSidebar(cachedActiveWorkflows);
    },
    incrementNotification: incrementWorkflowNotification,
    handleDialogSubmit: handleWorkflowSubmit,
    onLoad: runWorkflowInitializers,
    onAfterSwap: runWorkflowInitializers,
    onHistoryRestore: runWorkflowInitializers,
    onBeforeSwap(owner, event) {
      const target = event && event.detail ? event.detail.target : null;
      if (!target || target.id === 'main-content') {
        cleanupWorkflowSSE(owner);
      }
    },
  };

  dartclaw.workflowsControllerApi = workflowsControllerApi;

export default class DcWorkflowsController extends Stimulus.Controller {
  connect() {
    this.workflowEventSource = null;
    workflowsControllerApi.onLoad(this);
  }

  disconnect() {
    workflowsControllerApi.onBeforeSwap(this);
  }

  showStepDetailError(event) {
    const source = event.detail?.elt;
    if (source?.matches('.workflow-step-detail-loading')) {
      _showStepDetailError(source);
    }
  }

  retryStepDetail(event) {
    _retryStepDetail(event.currentTarget);
  }
}
