import 'dart:io';

import 'package:args/command_runner.dart';

import '../../asset_downloader.dart';
import '../serve_command.dart' show WriteLine;

/// Downloads and extracts the asset archive without starting the server.
class AssetsDownloadCommand extends Command<void> {
  final AssetDownloader _downloader;
  final WriteLine _stdoutLine;
  final WriteLine _stderrLine;

  AssetsDownloadCommand({AssetDownloader? downloader, WriteLine? stdoutLine, WriteLine? stderrLine})
    : _downloader = downloader ?? AssetDownloader(stderrLine: stderr.writeln),
      _stdoutLine = stdoutLine ?? stdout.writeln,
      _stderrLine = stderrLine ?? stderr.writeln;

  @override
  String get name => 'download';

  @override
  String get description => 'Download and extract the DartClaw release assets';

  @override
  Future<void> run() async {
    try {
      final installPath = await _downloader.download();
      _stdoutLine(installPath);
    } on AssetDownloadException catch (error) {
      _stderrLine(error.message);
      exitCode = 1;
    }
  }
}
