part of 'bash_step_runner.dart';

typedef WindowsProcessTreeTerminator = Future<ProcessResult> Function(int rootPid);
typedef PosixProcessIdentityLookup = Future<String?> Function(int pid);
typedef PosixProcessSnapshot = ({String identity, int parentPid});
typedef PosixProcessSnapshotLookup = Future<PosixProcessSnapshot?> Function(int pid);
typedef PosixChildPidLookup = Future<List<int>> Function(int parentPid);
typedef PosixProcessSignaler = bool Function(int pid, ProcessSignal signal);

final class PosixProcessInspectionException implements Exception {
  final String message;
  final Object? cause;

  const PosixProcessInspectionException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

/// Terminates a Bash process tree and reports whether ownership was released.
Future<bool> terminateBashProcessTree(
  Process process,
  PlatformCapabilities capabilities, {
  required String? rootProcessIdentity,
  Duration gracePeriod = const Duration(seconds: 2),
  WindowsProcessTreeTerminator? windowsTreeTerminator,
  Map<int, String> knownDescendantIdentities = const <int, String>{},
  void Function(Map<int, String> identities)? onOwnedDescendantsChanged,
  PosixProcessIdentityLookup? posixProcessIdentityLookup,
  PosixProcessSnapshotLookup? posixProcessSnapshotLookup,
  PosixChildPidLookup? posixChildPidLookup,
  PosixProcessSignaler? posixProcessSignaler,
  bool windowsTreeCleanupPreviouslyUnconfirmed = false,
  void Function(bool unconfirmed)? onWindowsTreeCleanupStateChanged,
  bool rootExitAlreadyObserved = false,
}) async {
  if (!capabilities.posixSignalsAvailable) {
    return _terminateWindowsBashProcessTree(
      process,
      capabilities,
      gracePeriod: gracePeriod,
      windowsTreeTerminator: windowsTreeTerminator,
      windowsTreeCleanupPreviouslyUnconfirmed: windowsTreeCleanupPreviouslyUnconfirmed,
      onWindowsTreeCleanupStateChanged: onWindowsTreeCleanupStateChanged,
      rootExitAlreadyObserved: rootExitAlreadyObserved,
    );
  }
  try {
    return await _terminatePosixBashProcessTree(
      process,
      rootProcessIdentity: rootProcessIdentity,
      gracePeriod: gracePeriod,
      knownDescendantIdentities: knownDescendantIdentities,
      onOwnedDescendantsChanged: onOwnedDescendantsChanged,
      posixProcessIdentityLookup: posixProcessIdentityLookup,
      posixProcessSnapshotLookup: posixProcessSnapshotLookup,
      posixChildPidLookup: posixChildPidLookup,
      posixProcessSignaler: posixProcessSignaler,
      rootExitAlreadyObserved: rootExitAlreadyObserved,
    );
  } on PosixProcessInspectionException catch (error, stackTrace) {
    _log.warning('Workflow Bash process-tree inspection failed; ownership retained', error, stackTrace);
    if (!rootExitAlreadyObserved) process.kill();
    return false;
  }
}

Future<bool> cleanupTimedOutBashProcess(
  BashProcessOwner owner,
  Process process,
  PlatformCapabilities capabilities, {
  required Future<Map<int, String>> descendantTracking,
  required bool rootExitAlreadyObserved,
  Duration gracePeriod = const Duration(seconds: 2),
  WindowsProcessTreeTerminator? windowsTreeTerminator,
  PosixProcessIdentityLookup? posixProcessIdentityLookup,
  PosixProcessSnapshotLookup? posixProcessSnapshotLookup,
  PosixChildPidLookup? posixChildPidLookup,
  PosixProcessSignaler? posixProcessSignaler,
  Future<bool> Function()? confirmDescendantOutputsClosed,
}) async {
  return owner.runCleanupAttempt(process, () async {
    if (rootExitAlreadyObserved) {
      final tracked = await descendantTracking;
      owner.replaceDescendants(process, {...owner.descendantIdentitiesOf(process), ...tracked});
    }
    var confirmed = await terminateBashProcessTree(
      process,
      capabilities,
      rootProcessIdentity: owner.rootIdentityOf(process),
      gracePeriod: gracePeriod,
      windowsTreeTerminator: windowsTreeTerminator,
      knownDescendantIdentities: owner.descendantIdentitiesOf(process),
      onOwnedDescendantsChanged: (identities) => owner.replaceDescendants(process, identities),
      posixProcessIdentityLookup: posixProcessIdentityLookup,
      posixProcessSnapshotLookup: posixProcessSnapshotLookup,
      posixChildPidLookup: posixChildPidLookup,
      posixProcessSignaler: posixProcessSignaler,
      windowsTreeCleanupPreviouslyUnconfirmed: owner.windowsTreeCleanupUnconfirmed(process),
      onWindowsTreeCleanupStateChanged: (unconfirmed) =>
          owner.setWindowsTreeCleanupUnconfirmed(process, unconfirmed: unconfirmed),
      rootExitAlreadyObserved: rootExitAlreadyObserved,
    );
    if (!rootExitAlreadyObserved && confirmed) {
      final tracked = await descendantTracking;
      owner.replaceDescendants(process, {...owner.descendantIdentitiesOf(process), ...tracked});
      final lateDescendants = owner.descendantIdentitiesOf(process);
      if (lateDescendants.isNotEmpty) {
        confirmed = await terminateBashProcessTree(
          process,
          capabilities,
          rootProcessIdentity: owner.rootIdentityOf(process),
          gracePeriod: gracePeriod,
          knownDescendantIdentities: lateDescendants,
          onOwnedDescendantsChanged: (identities) => owner.replaceDescendants(process, identities),
          posixProcessIdentityLookup: posixProcessIdentityLookup,
          posixProcessSnapshotLookup: posixProcessSnapshotLookup,
          posixChildPidLookup: posixChildPidLookup,
          posixProcessSignaler: posixProcessSignaler,
          rootExitAlreadyObserved: true,
        );
      }
    }
    if (confirmed && owner.unidentifiedDescendantCleanup(process)) return false;
    if (confirmed && confirmDescendantOutputsClosed != null && !await confirmDescendantOutputsClosed()) {
      owner.markUnidentifiedDescendantCleanup(process);
      return false;
    }
    return confirmed;
  });
}

Future<bool> _terminateWindowsBashProcessTree(
  Process process,
  PlatformCapabilities capabilities, {
  required Duration gracePeriod,
  WindowsProcessTreeTerminator? windowsTreeTerminator,
  required bool windowsTreeCleanupPreviouslyUnconfirmed,
  void Function(bool unconfirmed)? onWindowsTreeCleanupStateChanged,
  required bool rootExitAlreadyObserved,
}) async {
  if (rootExitAlreadyObserved) return !windowsTreeCleanupPreviouslyUnconfirmed;
  final result = await killWithEscalation(
    process,
    label: 'workflow bash step',
    gracePeriod: gracePeriod,
    log: _log,
    platformCapabilities: capabilities,
    windowsProcessTreeTerminator: _adaptWindowsTreeTerminator(windowsTreeTerminator),
  );
  onWindowsTreeCleanupStateChanged?.call(!result.processTreeTerminationAccepted);
  return result.exitConfirmed && result.processTreeTerminationAccepted;
}

Future<bool> Function(int rootPid)? _adaptWindowsTreeTerminator(WindowsProcessTreeTerminator? terminator) {
  if (terminator == null) return null;
  return (rootPid) async {
    try {
      final result = await terminator(rootPid);
      if (result.exitCode == 0) return true;
      _log.warning('Windows workflow bash process-tree termination failed with exit code ${result.exitCode}');
    } on ProcessException catch (error) {
      _log.warning('Windows workflow bash process-tree termination failed: $error');
    }
    return false;
  };
}

Future<bool> _terminatePosixBashProcessTree(
  Process process, {
  required String? rootProcessIdentity,
  required Duration gracePeriod,
  required Map<int, String> knownDescendantIdentities,
  void Function(Map<int, String> identities)? onOwnedDescendantsChanged,
  PosixProcessIdentityLookup? posixProcessIdentityLookup,
  PosixProcessSnapshotLookup? posixProcessSnapshotLookup,
  PosixChildPidLookup? posixChildPidLookup,
  PosixProcessSignaler? posixProcessSignaler,
  required bool rootExitAlreadyObserved,
}) async {
  final descendantOwnershipIdentified = rootProcessIdentity != null || knownDescendantIdentities.isNotEmpty;
  final dependencies = _resolvePosixCleanupDependencies(
    identityLookup: posixProcessIdentityLookup,
    snapshotLookup: posixProcessSnapshotLookup,
    childPidLookup: posixChildPidLookup,
    signaler: posixProcessSignaler,
  );
  final descendants = await _ownedDescendants(
    process,
    rootProcessIdentity: rootProcessIdentity,
    rootExitAlreadyObserved: rootExitAlreadyObserved,
    knownDescendantIdentities: knownDescendantIdentities,
    snapshotLookup: dependencies.snapshotLookup,
    childPidLookup: dependencies.childPidLookup,
  );
  onOwnedDescendantsChanged?.call(descendants);
  await _requestPosixTermination(
    process,
    descendants,
    rootExitAlreadyObserved: rootExitAlreadyObserved,
    identityLookup: dependencies.identityLookup,
    signaler: dependencies.signaler,
  );
  final cleanup = await _observePosixCleanup(
    process,
    descendants,
    rootExitAlreadyObserved: rootExitAlreadyObserved,
    timeout: gracePeriod,
    identityLookup: dependencies.identityLookup,
  );
  if (_posixCleanupConfirmed(cleanup)) {
    onOwnedDescendantsChanged?.call(const <int, String>{});
    return descendantOwnershipIdentified;
  }
  final confirmed = await _escalatePosixCleanup(
    process,
    cleanup,
    gracePeriod: gracePeriod,
    onOwnedDescendantsChanged: onOwnedDescendantsChanged,
    identityLookup: dependencies.identityLookup,
    signaler: dependencies.signaler,
  );
  return confirmed && descendantOwnershipIdentified;
}

({
  PosixProcessIdentityLookup identityLookup,
  PosixProcessSnapshotLookup snapshotLookup,
  PosixChildPidLookup childPidLookup,
  PosixProcessSignaler signaler,
})
_resolvePosixCleanupDependencies({
  PosixProcessIdentityLookup? identityLookup,
  PosixProcessSnapshotLookup? snapshotLookup,
  PosixChildPidLookup? childPidLookup,
  PosixProcessSignaler? signaler,
}) => (
  identityLookup: identityLookup ?? _posixProcessIdentity,
  snapshotLookup: snapshotLookup ?? _posixProcessSnapshot,
  childPidLookup: childPidLookup ?? _childPids,
  signaler: signaler ?? ((pid, signal) => Process.killPid(pid, signal)),
);

Future<void> _requestPosixTermination(
  Process process,
  Map<int, String> descendants, {
  required bool rootExitAlreadyObserved,
  required PosixProcessIdentityLookup identityLookup,
  required PosixProcessSignaler signaler,
}) async {
  if (!rootExitAlreadyObserved) process.kill();
  await _signalIdentities(descendants, ProcessSignal.sigterm, identityLookup, signaler);
}

bool _posixCleanupConfirmed(({bool rootExited, Map<int, String> survivors}) cleanup) =>
    cleanup.rootExited && cleanup.survivors.isEmpty;

Future<bool> _escalatePosixCleanup(
  Process process,
  ({bool rootExited, Map<int, String> survivors}) cleanup, {
  required Duration gracePeriod,
  void Function(Map<int, String> identities)? onOwnedDescendantsChanged,
  required PosixProcessIdentityLookup identityLookup,
  required PosixProcessSignaler signaler,
}) async {
  if (!cleanup.rootExited) process.kill(ProcessSignal.sigkill);
  await _signalIdentities(cleanup.survivors, ProcessSignal.sigkill, identityLookup, signaler);
  final finalCleanup = await _observePosixCleanup(
    process,
    cleanup.survivors,
    rootExitAlreadyObserved: cleanup.rootExited,
    timeout: gracePeriod,
    identityLookup: identityLookup,
  );
  onOwnedDescendantsChanged?.call(finalCleanup.survivors);
  return _reportPosixCleanup(process.pid, finalCleanup);
}

Future<Map<int, String>> _ownedDescendants(
  Process process, {
  required String? rootProcessIdentity,
  required bool rootExitAlreadyObserved,
  required Map<int, String> knownDescendantIdentities,
  required PosixProcessSnapshotLookup snapshotLookup,
  required PosixChildPidLookup childPidLookup,
}) async {
  final descendants = <int, String>{...knownDescendantIdentities};
  if (!rootExitAlreadyObserved && rootProcessIdentity != null) {
    descendants.addAll(await _descendantIdentities(process.pid, rootProcessIdentity, snapshotLookup, childPidLookup));
  }
  return descendants;
}

Future<({bool rootExited, Map<int, String> survivors})> _observePosixCleanup(
  Process process,
  Map<int, String> descendants, {
  required bool rootExitAlreadyObserved,
  required Duration timeout,
  required PosixProcessIdentityLookup identityLookup,
}) async {
  final rootExited = rootExitAlreadyObserved || await _waitForRootExit(process, timeout);
  final survivors = await _waitForIdentityExit(descendants, timeout, identityLookup);
  return (rootExited: rootExited, survivors: survivors);
}

bool _reportPosixCleanup(int rootPid, ({bool rootExited, Map<int, String> survivors}) cleanup) {
  if (cleanup.rootExited && cleanup.survivors.isEmpty) return true;
  _log.warning(
    'Workflow Bash process $rootPid cleanup remains unconfirmed'
    "${cleanup.survivors.isEmpty ? '' : ' for descendants ${cleanup.survivors.keys.join(', ')}'}",
  );
  return false;
}

/// Retries cleanup for every Bash process whose exit remains unconfirmed.
Future<void> retryOwnedBashProcesses(
  BashProcessOwner owner,
  PlatformCapabilities capabilities, {
  Duration gracePeriod = const Duration(seconds: 2),
  WindowsProcessTreeTerminator? windowsTreeTerminator,
  PosixProcessIdentityLookup? posixProcessIdentityLookup,
  PosixProcessSnapshotLookup? posixProcessSnapshotLookup,
  PosixChildPidLookup? posixChildPidLookup,
  PosixProcessSignaler? posixProcessSignaler,
}) async {
  for (final process in owner.cleanupPendingProcesses) {
    if (owner.unidentifiedDescendantCleanup(process)) continue;
    final rootExited = await _rootExitObservedForRetry(process);
    final exitConfirmed = await owner.runCleanupAttempt(
      process,
      () => terminateBashProcessTree(
        process,
        capabilities,
        rootProcessIdentity: owner.rootIdentityOf(process),
        gracePeriod: gracePeriod,
        windowsTreeTerminator: windowsTreeTerminator,
        knownDescendantIdentities: owner.descendantIdentitiesOf(process),
        onOwnedDescendantsChanged: (identities) => owner.replaceDescendants(process, identities),
        posixProcessIdentityLookup: posixProcessIdentityLookup,
        posixProcessSnapshotLookup: posixProcessSnapshotLookup,
        posixChildPidLookup: posixChildPidLookup,
        posixProcessSignaler: posixProcessSignaler,
        windowsTreeCleanupPreviouslyUnconfirmed: owner.windowsTreeCleanupUnconfirmed(process),
        onWindowsTreeCleanupStateChanged: (unconfirmed) =>
            owner.setWindowsTreeCleanupUnconfirmed(process, unconfirmed: unconfirmed),
        rootExitAlreadyObserved: rootExited,
      ),
    );
    if (exitConfirmed) owner.confirmExit(process);
  }
}

Future<Map<int, String>> trackOwnedBashDescendants(
  BashProcessOwner owner,
  Process process,
  PlatformCapabilities capabilities, {
  Duration interval = const Duration(milliseconds: 20),
  PosixProcessSnapshotLookup? posixProcessSnapshotLookup,
  PosixChildPidLookup? posixChildPidLookup,
}) async {
  if (!capabilities.posixSignalsAvailable) return const <int, String>{};
  final rootIdentity = owner.rootIdentityOf(process);
  if (rootIdentity == null) return const <int, String>{};
  final snapshotLookup = posixProcessSnapshotLookup ?? _posixProcessSnapshot;
  final childPidLookup = posixChildPidLookup ?? _childPids;
  final captured = <int, String>{};
  while (owner.owns(process)) {
    final Map<int, String> descendants;
    try {
      descendants = await _descendantIdentities(process.pid, rootIdentity, snapshotLookup, childPidLookup);
    } on PosixProcessInspectionException {
      owner.markUnidentifiedDescendantCleanup(process);
      return captured;
    }
    if (descendants.isNotEmpty) {
      captured.addAll(descendants);
      owner.replaceDescendants(process, {...owner.descendantIdentitiesOf(process), ...captured});
    }
    try {
      await process.exitCode.timeout(interval);
      return captured;
    } on TimeoutException {
      // Rescan until the root exits or ownership is released.
    }
  }
  return captured;
}

Future<bool> _rootExitObservedForRetry(Process process) async {
  try {
    await process.exitCode.timeout(const Duration(milliseconds: 1));
    return true;
  } on TimeoutException {
    return false;
  } catch (error, stackTrace) {
    _log.warning('Failed to observe owned workflow Bash process exit before retry', error, stackTrace);
    return false;
  }
}

Future<void> _signalIdentities(
  Map<int, String> identities,
  ProcessSignal signal,
  PosixProcessIdentityLookup identityLookup,
  PosixProcessSignaler signaler,
) async {
  for (final entry in identities.entries) {
    if (await identityLookup(entry.key) != entry.value) continue;
    try {
      signaler(entry.key, signal);
    } on ProcessException {
      // The process may have exited between discovery and signaling.
    }
  }
}

Future<bool> _waitForRootExit(Process process, Duration timeout) async {
  try {
    await process.exitCode.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<Map<int, String>> _waitForIdentityExit(
  Map<int, String> identities,
  Duration timeout,
  PosixProcessIdentityLookup identityLookup,
) async {
  var survivors = await _matchingProcessIdentities(identities, identityLookup);
  if (survivors.isEmpty || timeout <= Duration.zero) return survivors;
  final deadline = DateTime.now().add(timeout);
  while (survivors.isNotEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    survivors = await _matchingProcessIdentities(survivors, identityLookup);
  }
  return survivors;
}

Future<Map<int, String>> _matchingProcessIdentities(
  Map<int, String> identities,
  PosixProcessIdentityLookup identityLookup,
) async => <int, String>{
  for (final entry in identities.entries)
    if (await identityLookup(entry.key) == entry.value) entry.key: entry.value,
};

Future<Map<int, String>> _descendantIdentities(
  int rootPid,
  String rootIdentity,
  PosixProcessSnapshotLookup snapshotLookup,
  PosixChildPidLookup childPidLookup,
) async {
  final identities = <int, String>{};
  final seen = <int>{};
  var frontier = <({int pid, String identity})>[(pid: rootPid, identity: rootIdentity)];
  while (frontier.isNotEmpty) {
    final next = <({int pid, String identity})>[];
    for (final parent in frontier) {
      if (!await _processIdentityMatches(parent, snapshotLookup)) continue;
      final children = await childPidLookup(parent.pid);
      if (!await _processIdentityMatches(parent, snapshotLookup)) continue;
      for (final child in children) {
        if (!seen.add(child)) continue;
        final snapshot = await snapshotLookup(child);
        if (snapshot == null || snapshot.parentPid != parent.pid) continue;
        if (!await _processIdentityMatches(parent, snapshotLookup)) continue;
        identities[child] = snapshot.identity;
        next.add((pid: child, identity: snapshot.identity));
      }
    }
    frontier = next;
  }
  return identities;
}

Future<bool> _processIdentityMatches(
  ({int pid, String identity}) process,
  PosixProcessSnapshotLookup snapshotLookup,
) async => (await snapshotLookup(process.pid))?.identity == process.identity;

Future<String?> _posixProcessIdentity(int pid) async {
  return (await _posixProcessSnapshot(pid))?.identity;
}

Future<void> _captureOwnedRootIdentity(
  BashProcessOwner owner,
  Process process,
  PlatformCapabilities capabilities,
) async {
  if (!capabilities.posixSignalsAvailable) return;
  try {
    owner.setRootIdentity(process, await _posixProcessIdentity(process.pid));
  } on PosixProcessInspectionException {
    owner.markUnidentifiedDescendantCleanup(process);
  }
}

Future<PosixProcessSnapshot?> _posixProcessSnapshot(int pid) async {
  if (Platform.isLinux) return _linuxProcessSnapshot(pid);
  if (Platform.isMacOS) return _macProcessSnapshot(pid);
  return null;
}

Future<PosixProcessSnapshot?> _linuxProcessSnapshot(int pid) async {
  try {
    final stat = await File('/proc/$pid/stat').readAsString().timeout(const Duration(seconds: 1));
    final commandEnd = stat.lastIndexOf(')');
    if (commandEnd < 0 || commandEnd + 2 >= stat.length) {
      throw PosixProcessInspectionException('Malformed /proc stat for PID $pid');
    }
    final fieldsAfterCommand = stat.substring(commandEnd + 2).trim().split(RegExp(r'\s+'));
    if (fieldsAfterCommand.length <= 19) {
      throw PosixProcessInspectionException('Incomplete /proc stat for PID $pid');
    }
    final parentPid = int.tryParse(fieldsAfterCommand[1]);
    if (parentPid == null) throw PosixProcessInspectionException('Invalid parent PID in /proc stat for PID $pid');
    return (identity: fieldsAfterCommand[19], parentPid: parentPid);
  } on FileSystemException catch (error) {
    if (_linuxProcessDisappeared(error)) return null;
    throw PosixProcessInspectionException('Cannot inspect /proc stat for PID $pid', error);
  } on TimeoutException catch (error) {
    throw PosixProcessInspectionException('Timed out inspecting /proc stat for PID $pid', error);
  }
}

Future<PosixProcessSnapshot?> _macProcessSnapshot(int pid) async {
  try {
    final result = await Process.run('ps', [
      '-p',
      '$pid',
      '-o',
      'ppid=',
      '-o',
      'lstart=',
    ]).timeout(const Duration(seconds: 1));
    final fields = '${result.stdout}'.trim().split(RegExp(r'\s+'));
    if (result.exitCode == 1) return null;
    if (result.exitCode != 0) {
      throw PosixProcessInspectionException('ps failed for PID $pid with exit code ${result.exitCode}');
    }
    if (fields.length < 2) throw PosixProcessInspectionException('ps returned malformed data for PID $pid');
    final parentPid = int.tryParse(fields.first);
    if (parentPid == null) throw PosixProcessInspectionException('ps returned an invalid parent PID for PID $pid');
    return (identity: fields.skip(1).join(' '), parentPid: parentPid);
  } on ProcessException catch (error) {
    throw PosixProcessInspectionException('Cannot run ps for PID $pid', error);
  } on TimeoutException catch (error) {
    throw PosixProcessInspectionException('Timed out running ps for PID $pid', error);
  }
}

Future<List<int>> _childPids(int pid) {
  if (Platform.isLinux) return _linuxChildPids(pid);
  return _pgrepChildPids(pid);
}

Future<List<int>> _linuxChildPids(int pid) async {
  try {
    final children = await File('/proc/$pid/task/$pid/children').readAsString().timeout(const Duration(seconds: 1));
    final fields = children.trim().isEmpty ? const <String>[] : children.trim().split(RegExp(r'\s+'));
    final parsed = fields.map(int.tryParse).toList(growable: false);
    if (parsed.any((child) => child == null)) {
      throw PosixProcessInspectionException('Malformed child PID list for PID $pid');
    }
    return parsed.cast<int>();
  } on FileSystemException catch (error) {
    if (_linuxProcessDisappeared(error)) return const [];
    throw PosixProcessInspectionException('Cannot enumerate children for PID $pid', error);
  } on TimeoutException catch (error) {
    throw PosixProcessInspectionException('Timed out enumerating children for PID $pid', error);
  }
}

// /proc reports either ENOENT or ESRCH when a process exits during inspection.
bool _linuxProcessDisappeared(FileSystemException error) => const {2, 3}.contains(error.osError?.errorCode);

Future<List<int>> _pgrepChildPids(int pid) async {
  try {
    final result = await Process.run('pgrep', ['-P', '$pid']).timeout(const Duration(seconds: 1));
    if (result.exitCode == 1) return const [];
    if (result.exitCode != 0) {
      throw PosixProcessInspectionException('pgrep failed for PID $pid with exit code ${result.exitCode}');
    }
    final parsed = LineSplitter.split(
      '${result.stdout}',
    ).map((line) => int.tryParse(line.trim())).toList(growable: false);
    if (parsed.any((child) => child == null)) {
      throw PosixProcessInspectionException('pgrep returned malformed child data for PID $pid');
    }
    return parsed.cast<int>();
  } on ProcessException catch (error) {
    throw PosixProcessInspectionException('Cannot run pgrep for PID $pid', error);
  } on TimeoutException catch (error) {
    throw PosixProcessInspectionException('Timed out running pgrep for PID $pid', error);
  }
}
