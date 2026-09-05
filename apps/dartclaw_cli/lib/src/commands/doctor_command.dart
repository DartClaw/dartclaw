import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn, WriteLine, dartclawVersion;

import 'cli_global_options.dart';
import 'config_loader.dart';
import 'connected_command_support.dart';
import 'init/setup_checks.dart';

/// Diagnoses an existing instance and optionally creates its missing directories.
class DoctorCommand extends Command<void> {
  final SetupChecks _checks;
  final WriteLine _writeLine;
  final ExitFn _exitFn;
  final PlatformCapabilities _capabilities;
  final Map<String, String> _environment;

  new({
    SetupChecks? setupChecks,
    WriteLine? writeLine,
    ExitFn? exitFn,
    PlatformCapabilities? platformCapabilities,
    Map<String, String>? environment,
  }) : _checks = setupChecks ?? SetupChecks(),
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit,
       _capabilities = platformCapabilities ?? PlatformCapabilities(environment: environment),
       _environment = environment ?? Platform.environment {
    argParser.addFlag('json', negatable: false, help: 'Print one JSON diagnostic report.');
    argParser.addFlag('fix', negatable: false, help: 'Create missing workspace, sessions and logs directories.');
  }

  @override
  String get name => 'doctor';

  @override
  String get description => 'Check instance setup and report repairs';

  @override
  Future<void> run() async {
    final configPath = resolveCliConfigPath(configPath: globalOptionString(globalResults, 'config'), env: _environment);
    Future<DiagnosticReport> diagnose() => _checks.diagnose(
      configPath: configPath,
      serverOverride: serverOverride(globalResults),
      platformCapabilities: _capabilities,
      environment: _environment,
    );
    var report = await diagnose();
    final repaired = <String>[];
    if (argResults!.flag('fix') && report.missingDirectories.isNotEmpty) {
      for (final path in report.missingDirectories) {
        try {
          Directory(path).createSync(recursive: true);
          repaired.add(path);
        } on FileSystemException {
          // The fresh layout check retains failures, including non-directory collisions.
        }
      }
      report = await diagnose();
    }
    final fixed =
        repaired.isNotEmpty &&
        report.rows.any((row) => row.id == 'data_dir.layout' && row.status == DiagnosticStatus.pass);
    if (argResults!.flag('json')) {
      writePrettyJson(_writeLine, {
        'version': dartclawVersion,
        'config_path': configPath,
        'server': report.server,
        'checks': [
          for (final row in report.rows)
            {
              ...row.toJson(fixed: fixed && row.id == 'data_dir.layout'),
              if (fixed && row.id == 'data_dir.layout') 'detail': repaired,
            },
        ],
        'summary': report.summary,
      });
    } else {
      _writeLine('DartClaw Doctor: $configPath');
      for (final row in report.rows) {
        final rowFixed = fixed && row.id == 'data_dir.layout';
        _writeLine('[${rowFixed ? 'fixed' : row.status.name}] ${row.id}  ${_oneLine(row.summary)}');
        if (rowFixed) {
          for (final path in repaired) {
            _writeLine('    fixed: ${_oneLine(path)}');
          }
        } else if (row.status == DiagnosticStatus.warn || row.status == DiagnosticStatus.fail) {
          for (final detail in row.detail ?? const <String>[]) {
            _writeLine('    ${_oneLine(detail)}');
          }
          if (row.remediation case final remediation?) _writeLine('    → ${_oneLine(remediation)}');
        }
      }
      if (report.rows.any((row) => row.fixable)) _writeLine('For directory repairs, run dartclaw doctor --fix.');
      _writeLine(report.summary.entries.map((entry) => '${entry.value} ${entry.key}').join(', '));
    }
    if (report.failed) _exitFn(1);
  }

  static String _oneLine(String value) => value.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
}
