import 'connected_command_support.dart';

/// Stops every running turn and task on a connected server.
///
/// The channel-free half of the emergency stop path: an install with no chat
/// channel enabled has no `/stop` to send, so this is the way out.
class StopCommand extends ConnectedCommand {
  new({super.config, super.apiClient, super.writeLine, super.exitFn});

  @override
  String get name => 'stop';

  @override
  String get description => 'Emergency stop: cancel all running turns and tasks';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final result = await apiClient.postObject('/api/emergency-stop');
    writeLine('Emergency stop: ${result['turnsCancelled']} turns and ${result['tasksCancelled']} tasks cancelled.');
  });
}
