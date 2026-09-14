@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '_fixtures/conversation_qualification_evidence.dart';

void main() {
  late Directory root;
  late File input;

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversation_qualification_');
    input = File('${root.path}/input.json');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('valid receipts bind both cases and retain external holds and failed retries', () {
    final fixture = _Fixture(root)..write();
    final first = validateQualificationEvidence(input, 'integrated-qualification');
    final second = validateQualificationEvidence(input, 'workspace-chat-integration');

    expect(first.rows.map((row) => row['id']), contains('browser-proof'));
    expect(first.rows.map((row) => row['id']), contains('machine-accessibility-proof'));
    expect(second.rows.map((row) => row['id']), containsAll(['workspace-proof', 'workspace-memory-proof']));
    expect(first.holds.map((row) => row['id']), contains('device-hold'));
    expect(fixture.document['producerRows'], contains(fixture.failedAttempt));
    expect(fixture.document['producerRows'], contains(fixture.retry));
  });

  test('empty producer evidence is rejected', () {
    final fixture = _Fixture(root);
    fixture.document['producerRows'] = <Object?>[];
    fixture.writeDocument();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('staged-only candidate drift is rejected even when HEAD and unstaged bytes match', () {
    final fixture = _Fixture(root);
    final row = fixture.row('browser-proof');
    final candidate = Map<String, Object?>.from(row['candidate']! as Map);
    candidate['stagedDiffSha256'] = 'sha256:${List.filled(64, '9').join()}';
    row['candidate'] = candidate;
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('fixture-provider receipts cannot prove a supported-provider row', () {
    final fixture = _Fixture(root);
    fixture.row('browser-proof')
      ..['supportClaim'] = true
      ..['evidenceKind'] = 'fixture';
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('working-tree evidence cannot claim a committed-candidate pass', () {
    final fixture = _Fixture(root);
    fixture.row('browser-proof')['status'] = 'passed-committed';
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('passed evidence with a missing receipt artifact is rejected', () {
    _Fixture(root).write();
    File('${root.path}/browser-proof.json').deleteSync();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('a retry cannot erase or point past its failed attempt', () {
    final fixture = _Fixture(root);
    (fixture.document['producerRows']! as List<Object?>).remove(fixture.failedAttempt);
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('unknown status transitions fail closed', () {
    final fixture = _Fixture(root);
    fixture.row('browser-proof')['status'] = 'available';
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('workspace identifiers outside W1-W6 are rejected', () {
    final fixture = _Fixture(root);
    fixture.row('workspace-proof')['qOrW'] = ['W7'];
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'workspace-chat-integration'), throwsFormatException);
  });

  test('narrow, extra, or reordered candidate scope is rejected', () {
    for (final scope in [
      qualificationCandidateScope.sublist(1),
      [...qualificationCandidateScope, 'tool/'],
      [...qualificationCandidateScope.reversed],
    ]) {
      final fixture = _Fixture(root);
      fixture.candidate['scope'] = scope;
      fixture.write();
      expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
    }
  });

  test('missing or imprecise result exclusions are rejected', () {
    for (final exclusions in [
      qualificationResultExclusions.sublist(1),
      ['results/**', qualificationResultExclusions.last],
      [...qualificationResultExclusions, '.agent_temp/**'],
    ]) {
      final fixture = _Fixture(root);
      fixture.document['resultExclusions'] = exclusions;
      fixture.write();
      expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
    }
  });

  test('missing Q9 or Q10 producer coverage is rejected', () {
    for (final missing in ['browser-proof', 'machine-accessibility-proof']) {
      final fixture = _Fixture(root);
      final joined = fixture.document['joinedCases']! as Map<String, Object?>;
      final integrated = joined['integrated-qualification']! as Map<String, Object?>;
      (integrated['requiredAutomaticRows']! as List<String>).remove(missing);
      fixture.write();
      expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
    }
  });

  test('missing W3 producer coverage is rejected', () {
    final fixture = _Fixture(root);
    final joined = fixture.document['joinedCases']! as Map<String, Object?>;
    final workspace = joined['workspace-chat-integration']! as Map<String, Object?>;
    (workspace['requiredAutomaticRows']! as List<String>).remove('workspace-memory-proof');
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'workspace-chat-integration'), throwsFormatException);
  });

  test('self-declared mappings without expected direct assertions are rejected', () {
    final fixture = _Fixture(root);
    fixture.row('browser-proof')['assertionIds'] = ['q9-effective-context'];
    fixture.write();
    expect(() => validateQualificationEvidence(input, 'integrated-qualification'), throwsFormatException);
  });

  test('checkout verification rejects source drift after identity capture', () {
    final repository = Directory('${root.path}/repository')..createSync();
    _git(repository, ['init', '--quiet']);
    Directory('${repository.path}/packages').createSync();
    Directory('${repository.path}/dev').createSync();
    File('${repository.path}/packages/tracked.txt').writeAsStringSync('committed\n');
    _git(repository, ['add', 'packages/tracked.txt']);
    _git(repository, [
      '-c',
      'user.name=Qualification Fixture',
      '-c',
      'user.email=qualification@example.invalid',
      'commit',
      '--quiet',
      '-m',
      'fixture',
    ]);
    File('${repository.path}/packages/tracked.txt').writeAsStringSync('working tree\n');
    File('${repository.path}/dev/input.txt').writeAsStringSync('input\n');
    final candidate = captureCheckoutCandidate(repository, qualificationCandidateScope);

    expect(() => verifyCheckoutCandidate(repository, candidate), returnsNormally);
    File('${repository.path}/packages/tracked.txt').writeAsStringSync('drifted\n');
    expect(() => verifyCheckoutCandidate(repository, candidate), throwsFormatException);
  });
}

void _git(Directory repository, List<String> arguments) {
  final result = Process.runSync('git', arguments, workingDirectory: repository.path);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
}

final class _Fixture {
  new(this.root)
    : input = File('${root.path}/input.json'),
      candidate = {
        'kind': 'working-tree',
        'head': List.filled(40, '1').join(),
        'scope': qualificationCandidateScope,
        'stagedDiffSha256': 'sha256:${List.filled(64, '2').join()}',
        'unstagedDiffSha256': 'sha256:${List.filled(64, '3').join()}',
        'untrackedInputs': [
          {'path': 'dev/testing/0.27-qualification.md', 'sha256': 'sha256:${List.filled(64, '4').join()}'},
        ],
      } {
    browser = _passed(
      'browser-proof',
      ['Q9'],
      qualificationProducerAssertions['integrated-qualification']!['Q9']!,
      evidenceKind: 'real-provider',
      supportClaim: true,
    );
    machineAccessibility = _passed(
      'machine-accessibility-proof',
      ['Q10'],
      qualificationProducerAssertions['integrated-qualification']!['Q10']!,
      evidenceKind: 'real-browser',
    );
    workspace = _passed(
      'workspace-proof',
      ['W2'],
      qualificationProducerAssertions['workspace-chat-integration']!['W2']!,
      evidenceKind: 'real-provider',
      supportClaim: true,
    );
    workspaceMemory = _passed(
      'workspace-memory-proof',
      ['W3'],
      qualificationProducerAssertions['workspace-chat-integration']!['W3']!,
      evidenceKind: 'real-database',
    );
    workspaceMaintenance = _passed(
      'workspace-maintenance-proof',
      ['W4'],
      qualificationProducerAssertions['workspace-chat-integration']!['W4']!,
      evidenceKind: 'integration',
    );
    workspaceContext = _passed(
      'workspace-context-proof',
      ['W5'],
      qualificationProducerAssertions['workspace-chat-integration']!['W5']!,
      evidenceKind: 'integration',
    );
    failedAttempt = _base('browser-failed', 'failed', ['Q4'])
      ..['candidate'] = {'kind': 'committed', 'head': List.filled(40, 'f').join(), 'porcelainEmpty': true}
      ..['artifacts'] = ['browser-failed.log'];
    retry = _base('browser-retry', 'passed-working-tree', ['Q4'])
      ..['retryOf'] = 'browser-failed'
      ..['assertionIds'] = ['q4-retry']
      ..['artifacts'] = ['browser-retry.json']
      ..['receiptPaths'] = ['browser-retry.json'];
    deviceHold = _base('device-hold', 'pending', ['Q10'])
      ..['candidate'] = {'kind': 'pending', 'sourceCandidate': candidate}
      ..['environment'] = 'physical iOS Safari and Android Chrome'
      ..['invocation'] = 'perform the named keyboard, safe-area, paste, and screen-reader protocol';
    document = {
      'schemaVersion': 1,
      'candidate': candidate,
      'resultExclusions': qualificationResultExclusions,
      'producerRows': [
        browser,
        machineAccessibility,
        workspace,
        workspaceMemory,
        workspaceMaintenance,
        workspaceContext,
        failedAttempt,
        retry,
        deviceHold,
      ],
      'joinedCases': {
        'integrated-qualification': {
          'requiredAutomaticRows': ['browser-proof', 'machine-accessibility-proof'],
          'externalRows': ['device-hold'],
        },
        'workspace-chat-integration': {
          'requiredAutomaticRows': [
            'workspace-proof',
            'workspace-memory-proof',
            'workspace-maintenance-proof',
            'workspace-context-proof',
          ],
          'externalRows': ['device-hold'],
        },
      },
    };
  }

  final Directory root;
  final File input;
  final Map<String, Object?> candidate;
  late Map<String, Object?> document;
  late Map<String, Object?> browser;
  late Map<String, Object?> machineAccessibility;
  late Map<String, Object?> workspace;
  late Map<String, Object?> workspaceMemory;
  late Map<String, Object?> workspaceMaintenance;
  late Map<String, Object?> workspaceContext;
  late Map<String, Object?> failedAttempt;
  late Map<String, Object?> retry;
  late Map<String, Object?> deviceHold;

  Map<String, Object?> row(String id) =>
      (document['producerRows']! as List<Object?>).cast<Map<String, Object?>>().singleWhere((row) => row['id'] == id);

  void write() {
    for (final row in [
      browser,
      machineAccessibility,
      workspace,
      workspaceMemory,
      workspaceMaintenance,
      workspaceContext,
      retry,
    ]) {
      _writeReceipt(row);
    }
    File('${root.path}/browser-failed.log').writeAsStringSync('retained failing assertion\n');
    writeDocument();
  }

  void writeDocument() => input.writeAsStringSync(jsonEncode(document));

  Map<String, Object?> _passed(
    String id,
    List<String> mappings,
    List<String> assertions, {
    String evidenceKind = 'component',
    bool supportClaim = false,
  }) => _base(id, 'passed-working-tree', mappings)
    ..['assertionIds'] = assertions
    ..['artifacts'] = ['$id.json']
    ..['receiptPaths'] = ['$id.json']
    ..['evidenceKind'] = evidenceKind
    ..['supportClaim'] = supportClaim;

  Map<String, Object?> _base(String id, String status, List<String> mappings) => {
    'id': id,
    'gateId': 'gate-$id',
    'qOrW': mappings,
    'candidate': candidate,
    'environment': 'test fixture',
    'invocation': 'fixture invocation for $id',
    'status': status,
    'timestamp': '2026-09-14T12:00:00Z',
    'artifacts': <String>[],
    'assertionIds': <String>[],
    'receiptPaths': <String>[],
    'evidenceKind': 'component',
    'supportClaim': false,
    'retryOf': null,
  };

  void _writeReceipt(Map<String, Object?> row) {
    File('${root.path}/${row['id']}.json').writeAsStringSync(
      jsonEncode({
        'producerRowId': row['id'],
        'candidate': candidate,
        'result': 'passed',
        'assertions': [
          for (final id in row['assertionIds']! as List<Object?>) {'id': id, 'result': 'passed'},
        ],
      }),
    );
  }
}
