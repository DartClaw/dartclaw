import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

const hostWorktreeGitOptions = ['-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false'];

Future<ProcessResult> runHostWorktreeGit(
  List<String> args, {
  required String workingDirectory,
  ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
}) => runGit([...hostWorktreeGitOptions, ...args], workingDirectory: workingDirectory, plan: plan);
