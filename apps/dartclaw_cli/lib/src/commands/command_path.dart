import 'package:args/command_runner.dart';

String commandPath(Command<void> command) => '${commandPrefix(command)} ${command.name}';

String commandPrefix(Command<void> command) {
  final parents = <String>[];
  for (var parent = command.parent; parent != null; parent = parent.parent) {
    parents.add(parent.name);
  }
  return [command.runner!.executableName, ...parents.reversed].join(' ');
}
