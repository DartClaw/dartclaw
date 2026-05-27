import { cleanupChannelDetail, runChannelDetailInitializers } from './dc_settings_controller.js';

export default class DcChannelDetailController extends Stimulus.Controller {
  connect() {
    runChannelDetailInitializers();
  }

  disconnect() {
    cleanupChannelDetail();
  }
}
