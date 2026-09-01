function handleModeCardKeydown(event) {
  var card = event.target.closest('.channel-mode-card');
  if (!card) return;
  var group = card.closest('[role="radiogroup"]');
  if (!group) return;
  var cards = Array.prototype.slice.call(group.querySelectorAll('.channel-mode-card'));
  var index = cards.indexOf(card);
  if (index === -1) return;

  var next = null;
  switch (event.key) {
    case 'ArrowRight':
    case 'ArrowDown':
      next = cards[(index + 1) % cards.length];
      break;
    case 'ArrowLeft':
    case 'ArrowUp':
      next = cards[(index - 1 + cards.length) % cards.length];
      break;
    case 'Home':
      next = cards[0];
      break;
    case 'End':
      next = cards[cards.length - 1];
      break;
    case ' ':
    case 'Enter':
      event.preventDefault();
      card.click();
      return;
    default:
      return;
  }

  event.preventDefault();
  next.focus();
}

export default class DcChannelDetailController extends Stimulus.Controller {
  connect() {
    this.element.addEventListener('keydown', handleModeCardKeydown);
  }

  disconnect() {
    this.element.removeEventListener('keydown', handleModeCardKeydown);
  }
}
