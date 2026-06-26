import DcChannelDetailController from './dc_channel_detail_controller.js';
import DcChatController from './dc_chat_controller.js';
import DcHealthController from './dc_health_controller.js';
import DcMemoryController from './dc_memory_controller.js';
import DcProjectsController from './dc_projects_controller.js';
import DcAttributionController from './dc_attribution_controller.js';
import DcSchedulingController from './dc_scheduling_controller.js';
import DcSettingsController from './dc_settings_controller.js';
import DcShellController from './dc_shell_controller.js';
import DcTasksController from './dc_tasks_controller.js';
import DcToastController from './dc_toast_controller.js';
import DcWorkflowsController from './dc_workflows_controller.js';
import DcWhatsappController from './dc_whatsapp_controller.js';
import { installCompatibilityNamespace } from './shared.js';

const stimulus = window.Stimulus;

if (!stimulus || !stimulus.Application) {
  console.error('Stimulus failed to load from /static/stimulus.min.js');
} else {
  const dartclaw = installCompatibilityNamespace();
  const application = stimulus.Application.start();

  application.register('dc-channel-detail', DcChannelDetailController);
  application.register('dc-chat', DcChatController);
  application.register('dc-health', DcHealthController);
  application.register('dc-memory', DcMemoryController);
  application.register('dc-projects', DcProjectsController);
  application.register('dc-attribution', DcAttributionController);
  application.register('dc-scheduling', DcSchedulingController);
  application.register('dc-settings', DcSettingsController);
  application.register('dc-shell', DcShellController);
  application.register('dc-tasks', DcTasksController);
  application.register('dc-toast', DcToastController);
  application.register('dc-workflows', DcWorkflowsController);
  application.register('dc-whatsapp', DcWhatsappController);

  dartclaw.stimulus = application;
}
