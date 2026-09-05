import '../cli_command.dart';
import '../command_path.dart';
import 'workflow_connection.dart';

abstract class WorkflowConnectedCommand extends CliCommand {
  final WorkflowConnection? connection;

  new({super.config, super.writeLine, super.stderrLine, super.exitFn, this.connection});

  WorkflowConnectionContext get connectionContext => (
    globalResults: globalResults,
    config: injectedConfig,
    writeLine: writeLine,
    stderrLine: stderrLine,
    exitFn: exitFn,
    prefix: commandPrefix(this),
  );
}
