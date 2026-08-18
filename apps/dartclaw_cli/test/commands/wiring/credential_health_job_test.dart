import 'package:dartclaw_cli/src/commands/service_wiring.dart' show credentialedProviderFamilies;
import 'package:dartclaw_cli/src/commands/wiring/scheduling_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show EventBus;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

const _credentialsDir = '/srv/dartclaw-instance/credentials';

ProviderStatusService _providerStatus() => ProviderStatusService(
  providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude')}),
  registry: CredentialRegistry(credentials: const CredentialsConfig()),
  defaultProvider: 'claude',
);

void main() {
  late EventBus eventBus;
  late ProviderStatusService providerStatus;
  late CredentialHealthMonitor monitor;

  setUp(() {
    eventBus = EventBus();
    providerStatus = _providerStatus();
    monitor = CredentialHealthMonitor(
      eventBus: eventBus,
      providerStatus: providerStatus,
      resolveCredentials: () => {
        'claude': (
          family: 'claude',
          resolution: const CredentialResolution.unavailable(CredentialUnavailableReason.noneConfigured),
        ),
      },
      credentialsDir: _credentialsDir,
    );
  });

  tearDown(() async {
    await eventBus.dispose();
  });

  group('built-in credential-health job', () {
    test('is an hourly interval job named for the scheduling UI row', () {
      final built = buildCredentialHealthJob(monitor);

      expect(built.job.id, 'credential-health');
      expect(built.job.scheduleType, ScheduleType.interval);
      expect(built.job.intervalMinutes, 60);
      expect(built.job.deliveryMode, DeliveryMode.none);
      expect(built.job.onExecute, isNotNull);
      expect(built.displayJob, {
        'name': 'credential-health',
        'schedule': 'every 60 minutes',
        'delivery': 'none',
        'status': 'active',
      });
      // The UI row, the system-job name and the job itself must be one identity.
      expect(built.displayJob['name'], built.job.id);
    });

    test('passes the reserved system-action collision check', () {
      final built = buildCredentialHealthJob(monitor);

      expect(() => validateReservedSystemActionIds([built.job.id], const [memoryCurationActionId]), returnsNormally);
    });

    test('running the job probes the ProviderStatusService instance the API reads', () async {
      final built = buildCredentialHealthJob(monitor);
      expect(providerStatus.all.single.toJson()['credentialHealth'], isNull);

      final summary = await built.job.onExecute!();

      expect(summary, 'checked 1 provider, 1 degraded');
      expect(providerStatus.all.single.toJson()['credentialHealth'], 'reauth-required');
      expect(
        providerStatus.all.single.toJson()['credentialRemediation'],
        allOf(contains('dartclaw auth claude'), contains(_credentialsDir)),
      );
    });
  });

  group('credentialedProviderFamilies', () {
    test('omits a provider that presents no credential', () {
      // An ACP agent authenticates itself; probing it would raise a critical
      // re-authentication alert naming no command to run.
      final families = credentialedProviderFamilies(const {
        'claude': ProviderEntry(executable: 'claude'),
        'my-acp-agent': ProviderEntry(executable: 'acp-agent', options: {'credentials_required': false}),
      });

      expect(families, {'claude': 'claude'});
    });

    test('resolves an alias to the vendor family whose credential it presents', () {
      final families = credentialedProviderFamilies(const {
        'fast-claude': ProviderEntry(executable: 'claude'),
        'work-codex': ProviderEntry(executable: '/opt/bin/agent', options: {'family': 'codex'}),
      });

      // A bare id would leave both unwindowed and permanently reauth-required.
      expect(families, {'fast-claude': 'claude', 'work-codex': 'codex'});
    });
  });
}
