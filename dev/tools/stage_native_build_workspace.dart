import 'dart:convert';
import 'dart:io';

import '../../apps/dartclaw_cli/tool/native_artifact_preparation.dart';

Future<void> main(List<String> arguments) async {
  String requiredValue(String name) {
    final index = arguments.indexOf(name);
    if (index < 0 || index + 1 >= arguments.length) throw ArgumentError('Missing $name');
    return arguments[index + 1];
  }

  final source = Directory(requiredValue('--source'));
  final destination = Directory(requiredValue('--destination'));
  final hookRoot = requiredValue('--hook-root');
  final manifest = await NativeArtifactManifest.load(requiredValue('--manifest'));
  if (!await source.exists()) throw ArgumentError('Source workspace does not exist');
  if (await destination.exists()) throw StateError('Destination workspace already exists');
  await destination.create(recursive: true);

  final rootPubspec = await File(_join(source.path, 'pubspec.yaml')).readAsString();
  final stagedPubspec =
      '$rootPubspec\n'
      'hooks:\n'
      '  user_defines:\n'
      '    llamadart:\n'
      '      llamadart_native_path: ${jsonEncode(hookRoot)}\n'
      '      llamadart_native_tag: ${jsonEncode(manifest.release)}\n'
      '      llamadart_native_repository: ${jsonEncode(manifest.repository.toString())}\n'
      '      llamadart_native_runtimes:\n'
      '        - llama_cpp\n';
  await File(_join(destination.path, 'pubspec.yaml')).writeAsString(stagedPubspec);
  await File(_join(source.path, 'pubspec.lock')).copy(_join(destination.path, 'pubspec.lock'));

  final workspaceMembers = _workspaceMembers(rootPubspec);
  for (final member in workspaceMembers) {
    final sourceMember = Directory(_join(source.path, member));
    final destinationMember = Directory(_join(destination.path, member));
    await destinationMember.create(recursive: true);
    await File(_join(sourceMember.path, 'pubspec.yaml')).copy(_join(destinationMember.path, 'pubspec.yaml'));
    for (final directoryName in switch (member) {
      'apps/dartclaw_cli' => const ['bin', 'lib', 'tool'],
      _ => const ['lib'],
    }) {
      final child = Directory(_join(sourceMember.path, directoryName));
      if (await child.exists()) await _copyDirectory(child, Directory(_join(destinationMember.path, directoryName)));
    }
  }
}

List<String> _workspaceMembers(String pubspec) {
  final result = <String>[];
  var inWorkspace = false;
  for (final line in const LineSplitter().convert(pubspec)) {
    if (line == 'workspace:') {
      inWorkspace = true;
      continue;
    }
    if (!inWorkspace) continue;
    final match = RegExp(r'^  - (\S+)$').firstMatch(line);
    if (match != null) {
      result.add(match[1]!);
      continue;
    }
    if (line.isNotEmpty && !line.startsWith(' ')) break;
  }
  if (result.isEmpty) throw const FormatException('Workspace pubspec has no members');
  return result;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final target = _join(destination.path, name);
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    } else if (entity is Link) {
      await File(entity.path).copy(target);
    }
  }
}

String _join(String first, String second) => '$first${Platform.pathSeparator}$second';
