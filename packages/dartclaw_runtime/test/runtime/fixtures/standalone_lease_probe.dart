import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/standalone_execution_lease.dart';

Future<void> main(List<String> args) async {
  try {
    final lease = await StandaloneExecutionLease.acquire(args.single);
    await lease.release();
  } on StandaloneExecutionLeaseException {
    exitCode = 3;
  }
}
