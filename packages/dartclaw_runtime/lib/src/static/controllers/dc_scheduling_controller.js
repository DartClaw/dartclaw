export default class DcSchedulingController extends Stimulus.Controller {
  connect() {
    this.updateJobCronPreview();
    this.updateTaskCronPreview();
  }

  updateJobCronPreview(event) {
    const input = event?.currentTarget || document.getElementById('job-schedule');
    const output = document.getElementById('cron-preview');
    if (output) output.textContent = this.describeCron(input?.value || '');
  }

  updateTaskCronPreview(event) {
    const input = event?.currentTarget || document.getElementById('task-schedule');
    const output = document.getElementById('task-cron-preview');
    if (output) output.textContent = this.describeCron(input?.value || '');
  }

  describeCron(expression) {
    const parts = expression.trim().split(/\s+/);
    if (parts.length !== 5) return '';
    const [minute, hour, day, month, weekday] = parts;
    if (expression.trim() === '* * * * *') return 'Every minute';
    const minuteInterval = minute.match(/^\*\/(\d+)$/);
    if (minuteInterval && hour === '*' && day === '*' && month === '*' && weekday === '*') {
      return 'Every ' + minuteInterval[1] + ' minutes';
    }
    const hourInterval = hour.match(/^\*\/(\d+)$/);
    if (minute === '0' && hourInterval && day === '*' && month === '*' && weekday === '*') {
      return 'Every ' + hourInterval[1] + ' hours';
    }
    if (minute === '0' && hour === '*' && day === '*' && month === '*' && weekday === '*') return 'Every hour';
    if (/^\d+$/.test(minute) && /^\d+$/.test(hour) && day === '*' && month === '*' && weekday === '*') {
      return 'Daily at ' + this.formatTime(+hour, +minute);
    }
    const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    if (/^\d+$/.test(minute) && /^\d+$/.test(hour) && day === '*' && month === '*' && /^\d$/.test(weekday)) {
      return 'Weekly on ' + (dayNames[+weekday] || weekday) + ' at ' + this.formatTime(+hour, +minute);
    }
    if (/^\d+$/.test(minute) && /^\d+$/.test(hour) && /^\d+$/.test(day) && month === '*' && weekday === '*') {
      const suffix = day === '1' ? 'st' : day === '2' ? 'nd' : day === '3' ? 'rd' : 'th';
      return 'Monthly on the ' + day + suffix + ' at ' + this.formatTime(+hour, +minute);
    }
    return '';
  }

  formatTime(hour, minute) {
    const suffix = hour >= 12 ? 'PM' : 'AM';
    return (hour % 12 || 12) + ':' + String(minute).padStart(2, '0') + ' ' + suffix;
  }

  confirmDelete(event) {
    const button = event?.currentTarget;
    const message = button?.dataset?.deleteMessage;
    const url = button?.dataset?.deleteUrl;
    const row = button?.closest('tr');
    if (!row || !message || !url) return;

    const confirmRow = document.createElement('tr');
    confirmRow.className = 'delete-confirm-row';
    const cell = document.createElement('td');
    cell.colSpan = row.cells.length;
    const bar = document.createElement('div');
    bar.className = 'delete-confirm-bar';
    const copy = document.createElement('span');
    copy.className = 'confirm-msg';
    copy.textContent = message;
    const confirm = document.createElement('button');
    confirm.className = 'btn btn-danger-fill btn-sm';
    confirm.textContent = 'Confirm Delete';
    confirm.setAttribute('hx-post', url);
    confirm.setAttribute('hx-target', url.includes('/tasks/') ? '#scheduling-tasks-table' : '#scheduling-jobs-table');
    confirm.setAttribute('hx-swap', 'outerHTML');
    const cancel = document.createElement('button');
    cancel.className = 'btn btn-ghost btn-sm';
    cancel.dataset.action = 'click->dc-scheduling#cancelDelete';
    cancel.textContent = 'Cancel';
    bar.append(copy, confirm, cancel);
    cell.appendChild(bar);
    confirmRow.appendChild(cell);
    row.parentNode.insertBefore(confirmRow, row.nextSibling);
    row.style.display = 'none';
    const table = button.closest('.table-wrap');
    if (table) {
      bar.style.width = table.clientWidth + 'px';
      table.scrollLeft = 0;
    }
    htmx.process(confirm);
  }

  cancelDelete(event) {
    const confirmRow = event?.currentTarget?.closest('.delete-confirm-row');
    if (!confirmRow) return;
    const row = confirmRow.previousElementSibling;
    if (row) row.style.display = '';
    confirmRow.remove();
  }
}
