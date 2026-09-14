import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const qualificationCaseIds = {'integrated-qualification', 'workspace-chat-integration'};
const qualificationCandidateScope = [
  'packages',
  'apps',
  'dev',
  'docs',
  'CHANGELOG.md',
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
];
const qualificationResultExclusions = [
  '.agent_temp/exec-plan-0.27/S09/results/**',
  '.agent_temp/testing/conversation-loop/**',
];
const qualificationProducerAssertions = <String, Map<String, List<String>>>{
  'integrated-qualification': {
    'Q9': ['q9-temporary-destruction-boundaries', 'q9-temporary-supported-provider', 'q9-temporary-browser-memory'],
    'Q10': ['q9-temporary-export-e11'],
  },
  'workspace-chat-integration': {
    'W2': ['workspace-principal-provider-container-isolation'],
    'W3': ['workspace-memory-sqlite-isolation', 'workspace-memory-postgres-isolation'],
    'W4': ['workspace-maintenance-runtime-isolation'],
    'W5': ['context-research-runtime-isolation'],
  },
};
const qualificationProducerEvidenceKinds = <String, Map<String, String>>{
  'integrated-qualification': {'Q9': 'real-provider', 'Q10': 'real-browser'},
  'workspace-chat-integration': {
    'W2': 'real-provider',
    'W3': 'real-database',
    'W4': 'integration',
    'W5': 'integration',
  },
};
const qualificationSupportClaims = {'integrated-qualification:Q9', 'workspace-chat-integration:W2'};

final class ValidatedQualificationEvidence {
  new fromValidated({required this.caseId, required this.candidate, required this.rows, required this.holds});

  final String caseId;
  final Map<String, Object?> candidate;
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> holds;

  Map<String, Object?> toJson() => {
    'case': caseId,
    'candidate': candidate,
    'producerRows': rows,
    'externalHolds': holds,
  };
}

ValidatedQualificationEvidence validateQualificationEvidence(File input, String caseId) {
  if (!qualificationCaseIds.contains(caseId)) {
    throw FormatException('unsupported joined qualification case: $caseId');
  }
  final root = _object(jsonDecode(input.readAsStringSync()), 'qualification input');
  if (root['schemaVersion'] != 1) {
    throw const FormatException('qualification input schemaVersion must be 1');
  }
  final candidate = _candidate(root['candidate'], 'candidate');
  final exclusions = _strings(root['resultExclusions'], 'resultExclusions');
  if (!_sameStrings(exclusions, qualificationResultExclusions)) {
    throw const FormatException('resultExclusions must be the two exact generated-result paths');
  }
  final rows = _objects(root['producerRows'], 'producerRows');
  if (rows.isEmpty) throw const FormatException('producerRows must not be empty');
  final byId = <String, Map<String, Object?>>{};
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final id = _string(row['id'], 'producerRows[$index].id');
    if (byId.containsKey(id)) throw FormatException('duplicate producer row id: $id');
    _validateRow(row, input.parent, candidate, byId, index);
    byId[id] = row;
  }

  final cases = _object(root['joinedCases'], 'joinedCases');
  if (cases.keys.toSet().difference(qualificationCaseIds).isNotEmpty ||
      qualificationCaseIds.difference(cases.keys.toSet()).isNotEmpty) {
    throw const FormatException('joinedCases must expose exactly the two qualification cases');
  }
  final selected = _object(cases[caseId], 'joinedCases.$caseId');
  final required = _strings(selected['requiredAutomaticRows'], '$caseId.requiredAutomaticRows');
  if (required.isEmpty) throw FormatException('$caseId requires at least one automatic producer row');
  final producerContract = qualificationProducerAssertions[caseId]!;
  if (required.length != producerContract.length) {
    throw FormatException('$caseId must bind exactly one producer row for each required producer clause');
  }
  final external = _strings(selected['externalRows'], '$caseId.externalRows');
  final bound = <Map<String, Object?>>[];
  final covered = <String>{};
  for (final id in required) {
    final row = byId[id];
    if (row == null) throw FormatException('$caseId references missing producer row $id');
    if (row['status'] != 'passed-working-tree' && row['status'] != 'passed-committed') {
      throw FormatException('$caseId producer row $id is not passed');
    }
    final mappings = _strings(row['qOrW'], 'producer row $id qOrW');
    if (mappings.length != 1 || !producerContract.containsKey(mappings.single)) {
      throw FormatException('$caseId producer row $id has cross-case or surplus requirement mappings');
    }
    final requirement = mappings.single;
    if (!covered.add(requirement)) throw FormatException('$caseId repeats producer coverage for $requirement');
    final assertionIds = _strings(row['assertionIds'], 'producer row $id assertionIds');
    final missingAssertions = producerContract[requirement]!.toSet().difference(assertionIds.toSet());
    if (missingAssertions.isNotEmpty) {
      throw FormatException('$caseId producer row $id omits expected assertions: ${missingAssertions.join(', ')}');
    }
    final expectedKind = qualificationProducerEvidenceKinds[caseId]![requirement];
    if (row['evidenceKind'] != expectedKind) {
      throw FormatException('$caseId producer row $id must use $expectedKind evidence');
    }
    final expectedSupport = qualificationSupportClaims.contains('$caseId:$requirement');
    if (row['supportClaim'] != expectedSupport) {
      throw FormatException('$caseId producer row $id has the wrong support-claim classification');
    }
    bound.add(row);
  }
  final missingCoverage = producerContract.keys.toSet().difference(covered);
  if (missingCoverage.isNotEmpty) {
    throw FormatException('$caseId omits producer coverage: ${missingCoverage.join(', ')}');
  }
  final holds = <Map<String, Object?>>[];
  for (final id in external) {
    final row = byId[id];
    if (row == null) throw FormatException('$caseId references missing external row $id');
    if (row['status'] == 'passed-working-tree' || row['status'] == 'passed-committed') {
      bound.add(row);
    } else {
      holds.add(row);
    }
  }
  return ValidatedQualificationEvidence.fromValidated(caseId: caseId, candidate: candidate, rows: bound, holds: holds);
}

Map<String, Object?> captureCheckoutCandidate(Directory repository, List<String> scope) {
  if (!_sameStrings(scope, qualificationCandidateScope)) {
    throw ArgumentError.value(scope, 'scope', 'must be the exact canonical qualification scope');
  }
  final head = _gitText(repository, ['rev-parse', 'HEAD']).trim();
  final staged = _gitBytes(repository, ['diff', '--cached', '--binary', '--no-ext-diff', '--', ...scope]);
  final unstaged = _gitBytes(repository, ['diff', '--binary', '--no-ext-diff', '--', ...scope]);
  final untrackedOutput = _gitBytes(repository, ['ls-files', '--others', '--exclude-standard', '-z', '--', ...scope]);
  final untrackedPaths =
      utf8.decode(untrackedOutput).split('\u0000').where((path) => path.isNotEmpty).toList(growable: false)..sort();
  return {
    'kind': 'working-tree',
    'head': head,
    'scope': scope,
    'stagedDiffSha256': _sha256(staged),
    'unstagedDiffSha256': _sha256(unstaged),
    'untrackedInputs': [
      for (final path in untrackedPaths)
        {'path': path, 'sha256': _sha256(File.fromUri(repository.uri.resolve(path)).readAsBytesSync())},
    ],
  };
}

void verifyCheckoutCandidate(Directory repository, Map<String, Object?> expected) {
  _candidate(expected, 'candidate');
  final kind = _string(expected['kind'], 'candidate.kind');
  if (kind == 'committed') {
    final actualHead = _gitText(repository, ['rev-parse', 'HEAD']).trim();
    final status = _gitBytes(repository, ['status', '--porcelain=v1', '--untracked-files=all', '-z']);
    if (actualHead != expected['head'] || status.isNotEmpty) {
      throw const FormatException('actual checkout does not match the clean committed candidate');
    }
    return;
  }
  final scope = _strings(expected['scope'], 'candidate.scope');
  final actual = captureCheckoutCandidate(repository, scope);
  if (!_sameJson(actual, expected)) {
    throw const FormatException('actual checkout does not match the declared working-tree candidate');
  }
}

List<int> _gitBytes(Directory repository, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repository.path,
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw FormatException('git ${arguments.join(' ')} failed: ${(result.stderr as String).trim()}');
  }
  return result.stdout! as List<int>;
}

String _gitText(Directory repository, List<String> arguments) => utf8.decode(_gitBytes(repository, arguments));

String _sha256(List<int> bytes) => 'sha256:${sha256.convert(bytes)}';

void _validateRow(
  Map<String, Object?> row,
  Directory inputDirectory,
  Map<String, Object?> candidate,
  Map<String, Map<String, Object?>> priorRows,
  int index,
) {
  final label = 'producerRows[$index]';
  for (final field in const ['gateId', 'environment', 'invocation', 'timestamp', 'evidenceKind']) {
    _string(row[field], '$label.$field');
  }
  final mappings = _strings(row['qOrW'], '$label.qOrW');
  if (mappings.isEmpty || mappings.any((value) => !RegExp(r'^(?:Q(?:10|[1-9])|W[1-6])$').hasMatch(value))) {
    throw FormatException('$label.qOrW must contain Q1-Q10 or W1-W6 identifiers');
  }
  final status = _string(row['status'], '$label.status');
  const statuses = {'pending', 'failed', 'passed-working-tree', 'passed-committed'};
  if (!statuses.contains(status)) throw FormatException('$label.status is unsupported: $status');
  final rowCandidate = _candidate(row['candidate'], '$label.candidate', allowPending: status == 'pending');
  final isPassed = status.startsWith('passed-');
  if (isPassed && !_sameJson(rowCandidate, candidate)) {
    throw FormatException('$label candidate does not match the bound candidate');
  }
  if (status == 'passed-working-tree' && candidate['kind'] != 'working-tree') {
    throw FormatException('$label cannot record a working-tree pass for a committed candidate');
  }
  if (status == 'passed-committed' && candidate['kind'] != 'committed') {
    throw FormatException('$label cannot record a committed pass for a working-tree candidate');
  }
  final supportClaim = row['supportClaim'];
  if (supportClaim is! bool) throw FormatException('$label.supportClaim must be a boolean');
  if (isPassed && supportClaim && row['evidenceKind'] != 'real-provider') {
    throw FormatException('$label cannot prove supported-provider behavior with ${row['evidenceKind']} evidence');
  }
  final artifacts = _strings(row['artifacts'], '$label.artifacts');
  final assertionIds = _strings(row['assertionIds'], '$label.assertionIds');
  if (isPassed && (artifacts.isEmpty || assertionIds.isEmpty)) {
    throw FormatException('$label passed without artifacts and direct assertion ids');
  }
  if (status == 'failed' && artifacts.isEmpty) throw FormatException('$label failed without a retained artifact');
  if (isPassed || status == 'failed') {
    for (final path in artifacts) {
      if (!_resolve(inputDirectory, path).existsSync()) throw FormatException('$label artifact is missing: $path');
    }
  }
  if (isPassed) _validateReceipts(row, inputDirectory, candidate, assertionIds, label);

  final retryOf = row['retryOf'];
  if (retryOf != null) {
    if (retryOf is! String || retryOf.isEmpty) throw FormatException('$label.retryOf must be null or a row id');
    final prior = priorRows[retryOf];
    if (prior == null) throw FormatException('$label retry does not retain the earlier row $retryOf');
    if (prior['status'] != 'failed') throw FormatException('$label retry target $retryOf is not a failed attempt');
  }
}

void _validateReceipts(
  Map<String, Object?> row,
  Directory inputDirectory,
  Map<String, Object?> candidate,
  List<String> assertionIds,
  String label,
) {
  final receipts = _strings(row['receiptPaths'], '$label.receiptPaths');
  if (receipts.isEmpty) throw FormatException('$label passed without producer receipts');
  final observed = <String>{};
  for (final path in receipts) {
    final receipt = _object(jsonDecode(_resolve(inputDirectory, path).readAsStringSync()), '$label receipt $path');
    if (receipt['producerRowId'] != row['id'] || receipt['result'] != 'passed') {
      throw FormatException('$label receipt $path does not record this row as passed');
    }
    if (!_sameJson(_object(receipt['candidate'], '$label receipt candidate'), candidate)) {
      throw FormatException('$label receipt $path belongs to a different candidate');
    }
    for (final assertion in _objects(receipt['assertions'], '$label receipt assertions')) {
      final id = _string(assertion['id'], '$label receipt assertion id');
      if (assertion['result'] != 'passed') throw FormatException('$label receipt assertion $id did not pass');
      observed.add(id);
    }
  }
  final missing = assertionIds.toSet().difference(observed);
  if (missing.isNotEmpty) throw FormatException('$label receipts omit direct assertions: ${missing.join(', ')}');
}

Map<String, Object?> _candidate(Object? value, String label, {bool allowPending = false}) {
  final candidate = _object(value, label);
  final kind = _string(candidate['kind'], '$label.kind');
  if (allowPending && kind == 'pending') {
    _candidate(candidate['sourceCandidate'], '$label.sourceCandidate');
    return candidate;
  }
  final head = _string(candidate['head'], '$label.head');
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(head)) throw FormatException('$label.head must be an exact Git SHA');
  if (kind == 'working-tree') {
    final scope = _strings(candidate['scope'], '$label.scope');
    if (!_sameStrings(scope, qualificationCandidateScope)) {
      throw FormatException('$label.scope must be the exact canonical qualification scope');
    }
    _digest(candidate['stagedDiffSha256'], '$label.stagedDiffSha256');
    _digest(candidate['unstagedDiffSha256'], '$label.unstagedDiffSha256');
    final inputs = _objects(candidate['untrackedInputs'], '$label.untrackedInputs');
    final paths = <String>{};
    for (var index = 0; index < inputs.length; index++) {
      final path = _string(inputs[index]['path'], '$label.untrackedInputs[$index].path');
      _digest(inputs[index]['sha256'], '$label.untrackedInputs[$index].sha256');
      if (!paths.add(path)) throw FormatException('$label repeats untracked input $path');
    }
  } else if (kind == 'committed') {
    if (candidate['porcelainEmpty'] != true) {
      throw FormatException('$label committed candidate requires empty porcelain');
    }
  } else {
    throw FormatException('$label.kind is unsupported: $kind');
  }
  return candidate;
}

void _digest(Object? value, String label) {
  final digest = _string(value, label);
  if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest)) throw FormatException('$label must be a SHA-256 digest');
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, Object?>> _objects(Object? value, String label) {
  if (value is! List) throw FormatException('$label must be an array');
  return [for (final (index, item) in value.indexed) _object(item, '$label[$index]')];
}

List<String> _strings(Object? value, String label) {
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    throw FormatException('$label must be an array of non-empty strings');
  }
  return value.cast<String>();
}

String _string(Object? value, String label) {
  if (value is! String || value.isEmpty) throw FormatException('$label must be a non-empty string');
  return value;
}

File _resolve(Directory base, String path) => File(path).isAbsolute ? File(path) : File.fromUri(base.uri.resolve(path));

bool _sameJson(Object? left, Object? right) => jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList(growable: false);
  return value;
}
