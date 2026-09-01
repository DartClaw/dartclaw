import { updateRunningWorkflowsSection } from './sidebar_sections.js';

  const dartclaw = window.dartclaw = window.dartclaw || {};
  dartclaw.ui = dartclaw.ui || {};
  const ui = dartclaw.ui;
  let cachedActiveWorkflows = [];
  let workflowNotificationCount = 0;

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
        refreshAffectedStepCards(data);
        break;
      case 'task_status_changed':
        refreshAffectedStepCards(data);
        break;
      case 'loop_iteration_completed':
        refreshAffectedStepCards(data);
        break;
      case 'parallel_group_completed':
        refreshAffectedStepCards(data);
        break;
    }
  }

  function _connectedStepsDiffer(steps) {
    if (!Array.isArray(steps)) return false;
    return steps.some((step) => {
      const stepCard = document.querySelector('.pipeline-step[data-step-index="' + step.index + '"]');
      return !stepCard || stepCard.getAttribute('data-step-status') !== step.status;
    });
  }

  function refreshWorkflowDetail(owner) {
    if (!document.querySelector('.workflow-detail-page')) return;
    cleanupWorkflowSSE(owner);
    const qs = dartclaw.shell && typeof dartclaw.shell.apiQs === 'function'
      ? dartclaw.shell.apiQs()
      : '';
    const runId = document.querySelector('.workflow-detail-page')?.getAttribute('data-run-id');
    if (!runId) return;
    htmx.ajax('GET', '/workflows/' + encodeURIComponent(runId) + qs, {
      target: '#main-content',
      select: '#main-content',
      swap: 'outerHTML',
    });
  }

  function refreshAffectedStepCards(data) {
    if (data.type === 'parallel_group_completed' && data.failureCount > 0) return;
    const cards = new Set();
    if (data.stepIndex != null) {
      const card = document.querySelector('.pipeline-step[data-step-index="' + data.stepIndex + '"]');
      if (card) cards.add(card);
    }
    if (data.type === 'loop_iteration_completed') {
      document.querySelectorAll('.workflow-loop-badge[data-loop-id="' + data.loopId + '"]').forEach((badge) => {
        const card = badge.closest('.pipeline-step');
        if (card) cards.add(card);
      });
    }
    (data.stepIds || []).forEach((stepId) => {
      const card = document.querySelector('.pipeline-step[data-step-id="' + stepId + '"]');
      if (card) cards.add(card);
    });
    cards.forEach(refreshStepCard);
  }

  function refreshStepCard(card) {
    const runId = document.querySelector('.workflow-detail-page')?.getAttribute('data-run-id');
    const stepIndex = card.getAttribute('data-step-index');
    if (!runId || stepIndex == null) return;
    htmx.ajax(
      'GET',
      '/workflows/' + encodeURIComponent(runId) + '/steps/' + encodeURIComponent(stepIndex) + '/card',
      { target: card, swap: 'outerHTML' }
    );
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
        const stepCard = stepToggle.closest('.pipeline-step');
        const detail = stepCard && stepCard.querySelector('.workflow-step-detail');
        if (!detail) return;
        const isHidden = detail.hidden;
        detail.hidden = !isHidden;
        const icon = stepToggle.querySelector('.icon');
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
    bindWorkflowDetailToggles();
    if (owner) initWorkflowDetailSSE(owner);
    resetWorkflowNotificationIfOnWorkflowsPage();
  }

  const workflowsControllerApi = {
    renderSidebar: updateWorkflowSidebar,
    restoreSidebar() {
      updateWorkflowSidebar(cachedActiveWorkflows);
    },
    incrementNotification: incrementWorkflowNotification,
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
