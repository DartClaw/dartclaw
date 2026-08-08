import { escapeHtml, sanitizeClassToken } from './shared.js';

function insertSidebarSection(container, afterRunning = false) {
  const sidebar = document.getElementById('sidebar');
  if (!sidebar) return;
  const runningSection = document.getElementById('sidebar-running');
  const workflowSection = document.getElementById('sidebar-workflows');
  const chatsSection = sidebar.querySelector('.sidebar-chat-section');
  if (!chatsSection || !chatsSection.parentNode) return;
  const insertBefore = afterRunning
    ? runningSection?.nextElementSibling || chatsSection
    : workflowSection || chatsSection;
  if (insertBefore && insertBefore.parentNode) {
    insertBefore.parentNode.insertBefore(container, insertBefore);
  } else {
    chatsSection.parentNode.insertBefore(container, chatsSection);
  }
}

export function updateRunningTasksSection(tasks) {
  const activeTasks = Array.isArray(tasks) ? tasks : [];
  const existing = document.getElementById('sidebar-running');
  if (!activeTasks.length) {
    existing?.remove();
    return activeTasks;
  }

  // Mirrors the server-side uniformity gate so an injected row does not
  // reintroduce the badge the rendered rail deliberately suppressed.
  const showBadges = document.getElementById('sidebar')?.dataset.providerBadges !== 'hidden';

  const itemsHtml = activeTasks.map((task) => {
    const taskId = encodeURIComponent(task.id || '');
    const href = '/tasks/' + taskId;
    const provider = sanitizeClassToken(task.provider || 'claude', 'claude');
    const providerLabel = escapeHtml(task.providerLabel || task.provider || 'Claude');
    const title = escapeHtml(task.title || 'Untitled Task');
    const statusClass = task.status === 'review' ? 'status-dot status-dot--warning' : 'status-dot status-dot--live';
    const trailingMeta = task.status === 'review'
      ? '<span class="running-review-label">review</span>'
      : task.startedAt
        ? '<span class="task-elapsed running-elapsed" data-started-at="' + escapeHtml(task.startedAt) + '"></span>'
        : '<span class="task-elapsed running-elapsed">--:--</span>';
    return (
      '<div class="session-item sidebar-running-item">' +
        '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
          ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML" hx-push-url="true"' +
          ' hx-select-oob="#topbar,#restart-banner-slot,#sidebar">' +
          '<span class="' + statusClass + '" aria-hidden="true"></span>' +
          '<span class="session-item-title">' + title + '</span>' +
          trailingMeta +
          (showBadges
            ? '<span class="provider-badge provider-badge-' + provider + '">' + providerLabel + '</span>'
            : '') +
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
    insertSidebarSection(container);
  }
  window.htmx?.process(container);
  return activeTasks;
}

export function updateRunningWorkflowsSection(workflows) {
  const activeWorkflows = Array.isArray(workflows) ? workflows : [];
  const existing = document.getElementById('sidebar-workflows');
  if (!activeWorkflows.length) {
    existing?.remove();
    return activeWorkflows;
  }

  const itemsHtml = activeWorkflows.map((workflow) => {
    const workflowId = encodeURIComponent(workflow.id || '');
    const href = '/workflows/' + workflowId;
    const name = escapeHtml(workflow.definitionName || 'Workflow');
    const progress = (workflow.completedSteps || 0) + '/' + (workflow.totalSteps || 0);
    const statusClass = workflow.status === 'paused' ? 'status-dot status-dot--warning' : 'status-dot status-dot--live';
    return (
      '<div class="session-item sidebar-workflow-item">' +
        '<a href="' + href + '" hx-get="' + href + '" class="session-item-link"' +
          ' hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML"' +
          ' hx-push-url="true" hx-select-oob="#topbar,#restart-banner-slot,#sidebar">' +
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
    insertSidebarSection(container, true);
  }
  window.htmx?.process(container);
  return activeWorkflows;
}
