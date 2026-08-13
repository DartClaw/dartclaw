import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late Directory sourceTree;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('bridge_binary_data_');
    sourceTree = Directory.systemTemp.createTempSync('bridge_binary_src_');
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    if (sourceTree.existsSync()) sourceTree.deleteSync(recursive: true);
  });

  group('architectureFor', () {
    test('maps the docker engine architectures a release ships for', () {
      expect(BridgeBinaryProvisioner.architectureFor('amd64'), 'x64');
      expect(BridgeBinaryProvisioner.architectureFor('x86_64'), 'x64');
      expect(BridgeBinaryProvisioner.architectureFor('arm64'), 'arm64');
      expect(BridgeBinaryProvisioner.architectureFor(' AARCH64 \n'), 'arm64');
    });

    test('returns null for an architecture with no shipped bridge', () {
      expect(BridgeBinaryProvisioner.architectureFor('riscv64'), isNull);
      expect(BridgeBinaryProvisioner.architectureFor(''), isNull);
    });
  });

  group('ensureAvailable', () {
    test('unpacks the embedded gzipped binary and makes it executable', () async {
      final payload = utf8.encode('#!/bin/sh\necho bridge\n');
      final provisioner = BridgeBinaryProvisioner(
        dataDir: dataDir.path,
        embeddedAssets: {'bridge/dartclaw-bridge-linux-x64.gz': gzip.encode(payload)},
        sourceTreeDir: sourceTree,
      );

      final path = await provisioner.ensureAvailable('x64');

      expect(p.basename(path), 'dartclaw-bridge-linux-x64');
      expect(File(path).readAsBytesSync(), payload);
      expect(File(path).statSync().modeString(), contains('x'));
    });

    test('prefers what the release shipped over anything under the working directory', () async {
      File(p.join(sourceTree.path, 'dartclaw-bridge-linux-arm64')).writeAsStringSync('planted build');
      final provisioner = BridgeBinaryProvisioner(
        dataDir: dataDir.path,
        embeddedAssets: {'bridge/dartclaw-bridge-linux-arm64.gz': gzip.encode(utf8.encode('shipped build'))},
        sourceTreeDir: sourceTree,
      );

      final path = await provisioner.ensureAvailable('arm64');

      expect(File(path).readAsStringSync(), 'shipped build');
    });

    test('falls back to a source checkout only when the release embedded nothing', () async {
      File(p.join(sourceTree.path, 'dartclaw-bridge-linux-arm64')).writeAsStringSync('local build');
      final provisioner = BridgeBinaryProvisioner(
        dataDir: dataDir.path,
        embeddedAssets: const {},
        sourceTreeDir: sourceTree,
      );

      expect(File(await provisioner.ensureAvailable('arm64')).readAsStringSync(), 'local build');
    });

    test('fails closed when no bridge exists for the architecture', () async {
      final provisioner = BridgeBinaryProvisioner(
        dataDir: dataDir.path,
        embeddedAssets: const {},
        sourceTreeDir: sourceTree,
      );

      await expectLater(
        provisioner.ensureAvailable('x64'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('build_bridge.sh'))),
      );
    });

    test('rewrites a materialized binary even when the length matches', () async {
      final target = File(p.join(dataDir.path, 'bridge', 'dartclaw-bridge-linux-x64'))
        ..parent.createSync(recursive: true)
        // Same length as the shipped bytes: length alone is not evidence.
        ..writeAsStringSync('a substituted binary!!');
      final provisioner = BridgeBinaryProvisioner(
        dataDir: dataDir.path,
        embeddedAssets: {'bridge/dartclaw-bridge-linux-x64.gz': gzip.encode(utf8.encode('the current release!'))},
        sourceTreeDir: sourceTree,
      );

      await provisioner.ensureAvailable('x64');

      expect(target.readAsStringSync(), 'the current release!');
    });
  });
}
