import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/api_helpers.dart';
import '../../behavior/heartbeat_job.dart';
import '../../runtime_config.dart';
import '../../scheduling/schedule_mutation.dart';
import '../../scheduling/schedule_service.dart';
import '../../scheduling/scheduled_job.dart';
import '../../templates/restart_banner.dart';
import '../../templates/scheduling.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

const _maxSchedulingFormBytes = 32 * 1024;

class SchedulingPage extends DashboardPage {
  new({this.runtimeConfigGetter, this.configWriter, this.scheduleServiceGetter});

  final RuntimeConfig? Function()? runtimeConfigGetter;
  final ConfigWriter? configWriter;
  final ScheduleService? Function()? scheduleServiceGetter;

  @override
  String get route => '/scheduling';
  @override
  String get title => 'Scheduling';
  @override
  String? get icon => 'scheduling';
  @override
  String get navGroup => 'system';

  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'GET', path: '/scheduling/jobs/form'),
    (method: 'GET', path: '/scheduling/jobs/form/close'),
    (method: 'GET', path: '/scheduling/jobs/<name>/form'),
    (method: 'POST', path: '/scheduling/jobs/create'),
    (method: 'POST', path: '/scheduling/jobs/<name>/update'),
    (method: 'POST', path: '/scheduling/jobs/<name>/delete'),
    (method: 'POST', path: '/scheduling/jobs/<name>/run'),
    (method: 'GET', path: '/scheduling/tasks/form'),
    (method: 'GET', path: '/scheduling/tasks/form/close'),
    (method: 'GET', path: '/scheduling/tasks/<id>/form'),
    (method: 'POST', path: '/scheduling/tasks/create'),
    (method: 'POST', path: '/scheduling/tasks/<id>/update'),
    (method: 'POST', path: '/scheduling/tasks/<id>/delete'),
    (method: 'POST', path: '/scheduling/tasks/<id>/toggle'),
  ];

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final segments = request.requestedUri.pathSegments;
    final action = segments.last;
    final id =
        request.params['name'] ?? request.params['id'] ?? (segments.length >= 4 ? segments[segments.length - 2] : null);
    if (request.method == 'GET' && action == 'form') return _form(id, task: segments.contains('tasks'));
    if (request.method == 'GET' && action == 'close') return _closedForm(segments.contains('tasks'));
    if (request.method == 'POST' && action == 'create') {
      return _save(request, context, task: segments.contains('tasks'));
    }
    if (request.method == 'POST' && action == 'update') {
      return _save(request, context, task: segments.contains('tasks'), id: id);
    }
    if (request.method == 'POST' && action == 'delete') {
      return _delete(context, task: segments.contains('tasks'), id: id!);
    }
    if (request.method == 'POST' && action == 'toggle') return _toggle(context, id!);
    if (request.method == 'POST' && action == 'run') return _run(context, id!);
    return _page(context);
  }

  Future<Response> _page(PageContext context) async {
    final config = context.config;
    final scheduleService = scheduleServiceGetter?.call();
    final heartbeatLoaded = scheduleService?.hasJob(heartbeatJobId) ?? false;
    final heartbeat = heartbeatLoaded
        ? !scheduleService!.isJobPaused(heartbeatJobId)
        : runtimeConfigGetter?.call()?.heartbeatEnabled ?? config?.scheduling.heartbeatEnabled ?? false;
    final data = await _liveData(context);
    final sidebar = await context.sidebar.build();
    return Response.ok(
      schedulingTemplate(
        sidebarData: sidebar,
        navItems: context.navItems(activePage: title),
        heartbeatEnabled: heartbeat,
        heartbeatIntervalMinutes: config?.scheduling.heartbeatIntervalMinutes ?? 30,
        jobs: data.jobs,
        systemJobNames: context.systemJobNames,
        scheduledTasks: data.tasks,
        loadedJobIds: _loadedIds(),
        restartBannerHtml: context.restartBannerHtml(),
        appName: context.appName,
      ),
      headers: htmlHeaders,
    );
  }

  Future<Response> _form(String? rawId, {required bool task}) async {
    if (rawId == null) {
      return Response.ok(
        task
            ? schedulingTaskFormFragment(values: emptyTaskFormValues)
            : schedulingJobFormFragment(values: emptyJobFormValues),
        headers: htmlHeaders,
      );
    }
    final id = decodePathSegment(rawId);
    final jobs = await configWriter?.readSchedulingJobs() ?? const <Map<String, dynamic>>[];
    final index = ScheduleMutationService.indexOfJob(jobs, id, taskScoped: task);
    if (index == -1) return _closedForm(task, toast: '${task ? 'Scheduled task' : 'Job'} not found');
    try {
      final job = ScheduledJob.fromConfig(jobs[index]);
      if (task) {
        final def = job.taskDefinition;
        if (def == null) return _closedForm(true, toast: 'Scheduled task not found');
        return Response.ok(
          schedulingTaskFormFragment(
            values: (
              id: def.id,
              schedule: def.cronExpression,
              title: def.title,
              description: def.description,
              acceptanceCriteria: def.acceptanceCriteria ?? '',
              enabled: def.enabled,
            ),
            editId: id,
          ),
          headers: htmlHeaders,
        );
      }
      if (job.jobType != ScheduledJobType.prompt) return _closedForm(false, toast: 'Job not found');
      return Response.ok(
        schedulingJobFormFragment(
          values: (
            name: job.id,
            schedule: job.cronExpression?.expression ?? '',
            prompt: job.prompt,
            delivery: job.deliveryMode.name,
          ),
          editName: id,
        ),
        headers: htmlHeaders,
      );
    } catch (_) {
      return _closedForm(task, toast: '${task ? 'Scheduled task' : 'Job'} not found');
    }
  }

  Response _closedForm(bool task, {String? toast}) => Response.ok(
    task ? schedulingTaskFormFragment() : schedulingJobFormFragment(),
    headers: {...htmlHeaders, if (toast != null) ...toastTriggerHeader('error', toast)},
  );
  Future<Response> _save(Request request, PageContext context, {required bool task, String? id}) async {
    final mutation = _mutations(context);
    if (mutation == null) return Response(503, body: 'Scheduling editing is not available');
    final form = await _readForm(request);
    if (form.error != null) return form.error!;
    final values = form.value!;
    final editId = id == null ? null : decodePathSegment(id);
    final ScheduleMutationResult result;
    if (task) {
      final payload = <String, dynamic>{
        'id': editId ?? values['id']?.trim() ?? '',
        'schedule': values['schedule']?.trim() ?? '',
        'title': values['title']?.trim() ?? '',
        'description': values['description']?.trim() ?? '',
        'acceptanceCriteria': values['acceptanceCriteria']?.trim() ?? '',
        'enabled': values.containsKey('enabled'),
      };
      result = editId == null ? await mutation.createTask(payload) : await mutation.updateTask(editId, payload);
      if (result case ScheduleMutationRefused(:final refusal)) {
        return Response.ok(
          schedulingTaskFormFragment(
            values: (
              id: payload['id'] as String,
              schedule: payload['schedule'] as String,
              title: payload['title'] as String,
              description: payload['description'] as String,
              acceptanceCriteria: payload['acceptanceCriteria'] as String,
              enabled: payload['enabled'] as bool,
            ),
            editId: editId,
            error: refusal.message,
            errorField: refusal.field,
          ),
          headers: htmlHeaders,
        );
      }
    } else {
      final payload = <String, dynamic>{
        'name': editId ?? values['name']?.trim() ?? '',
        'schedule': values['schedule']?.trim() ?? '',
        'delivery': values['delivery'] ?? 'none',
        if (editId == null || (values['prompt']?.trim().isNotEmpty ?? false)) 'prompt': values['prompt']?.trim() ?? '',
      };
      result = editId == null ? await mutation.createJob(payload) : await mutation.updateJob(editId, payload);
      if (result case ScheduleMutationRefused(:final refusal)) {
        return Response.ok(
          schedulingJobFormFragment(
            values: (
              name: payload['name'] as String,
              schedule: payload['schedule'] as String,
              prompt: values['prompt']?.trim() ?? '',
              delivery: payload['delivery'] as String,
            ),
            editName: editId,
            error: refusal.message,
            errorField: refusal.field,
          ),
          headers: htmlHeaders,
        );
      }
    }
    return _saved(
      context,
      task: task,
      message: task
          ? (editId == null ? 'Task created' : 'Task updated')
          : (editId == null ? 'Job added' : 'Job updated'),
    );
  }

  Future<Response> _delete(PageContext context, {required bool task, required String id}) async {
    final mutation = _mutations(context);
    if (mutation == null) return Response(503);
    final decoded = decodePathSegment(id);
    final result = task ? await mutation.deleteTask(decoded) : await mutation.deleteJob(decoded);
    return _tableResult(context, task: task, result: result, success: task ? 'Scheduled task deleted' : 'Job deleted');
  }

  Future<Response> _toggle(PageContext context, String rawId) async {
    final mutation = _mutations(context);
    if (mutation == null) return Response(503);
    final id = decodePathSegment(rawId);
    final jobs = await mutation.readJobs();
    final index = ScheduleMutationService.indexOfJob(jobs, id, taskScoped: true);
    final job = index == -1 ? null : jobs[index];
    final result = job == null
        ? const ScheduleMutationRefused(
            ScheduleMutationRefusal(status: 404, code: 'NOT_FOUND', message: 'Scheduled task not found'),
          )
        : await mutation.updateTask(id, {'enabled': job['enabled'] == false});
    return _tableResult(
      context,
      task: true,
      result: result,
      success: job?['enabled'] == false ? 'Task enabled' : 'Task disabled',
    );
  }

  Future<Response> _run(PageContext context, String rawName) async {
    final name = decodePathSegment(rawName);
    final service = scheduleServiceGetter?.call();
    final result = service?.runJobNow(name) ?? RunScheduledJobResult.notFound;
    final message = switch (result) {
      RunScheduledJobResult.started => "Job '$name' started",
      RunScheduledJobResult.alreadyRunning => 'Job "$name" is already running',
      RunScheduledJobResult.notFound =>
        'Job "$name" is not present in the running scheduler or is not runnable on demand. Newly created or edited jobs require a restart; otherwise check server logs for configuration errors.',
    };
    final data = await _liveData(context);
    return Response.ok(
      schedulingJobsFragment(jobs: data.jobs, systemJobNames: context.systemJobNames, loadedJobIds: _loadedIds()),
      headers: {
        ...htmlHeaders,
        ...toastTriggerHeader(result == RunScheduledJobResult.started ? 'success' : 'error', message),
      },
    );
  }

  Future<Response> _saved(PageContext context, {required bool task, required String message}) async {
    final data = await _liveData(context);
    final table = task
        ? schedulingTasksFragment(tasks: data.tasks, loadedJobIds: _loadedIds(), outOfBand: true)
        : schedulingJobsFragment(
            jobs: data.jobs,
            systemJobNames: context.systemJobNames,
            loadedJobIds: _loadedIds(),
            outOfBand: true,
          );
    final closed = task ? schedulingTaskFormFragment() : schedulingJobFormFragment();
    return Response.ok(
      '$closed$table${restartBannerTemplate(pendingFields: const ['scheduling.jobs'], outOfBand: true)}',
      headers: {...htmlHeaders, ...toastTriggerHeader('success', '$message - restart required')},
    );
  }

  Future<Response> _tableResult(
    PageContext context, {
    required bool task,
    required ScheduleMutationResult result,
    required String success,
  }) async {
    final data = await _liveData(context);
    final table = task
        ? schedulingTasksFragment(tasks: data.tasks, loadedJobIds: _loadedIds())
        : schedulingJobsFragment(jobs: data.jobs, systemJobNames: context.systemJobNames, loadedJobIds: _loadedIds());
    final (type, message) = switch (result) {
      ScheduleMutationApplied() => ('success', '$success - restart required'),
      ScheduleMutationRefused(:final refusal) => ('error', refusal.message),
    };
    final banner = result is ScheduleMutationApplied
        ? restartBannerTemplate(pendingFields: const ['scheduling.jobs'], outOfBand: true)
        : '';
    return Response.ok('$table$banner', headers: {...htmlHeaders, ...toastTriggerHeader(type, message)});
  }

  ScheduleMutationService? _mutations(PageContext context) {
    final writer = configWriter;
    final dataDir = context.dataDir;
    return writer == null || dataDir == null ? null : ScheduleMutationService(writer: writer, dataDir: dataDir);
  }

  Future<({Map<String, String>? value, Response? error})> _readForm(Request request) async {
    final body = await readRequestBody(request, maxBytes: _maxSchedulingFormBytes);
    if (body.error != null) return (value: null, error: body.error);
    try {
      return (value: Uri.splitQueryString(body.body!), error: null);
    } on FormatException {
      return (value: null, error: Response(400, body: 'Request body must be form-encoded'));
    } on ArgumentError {
      return (value: null, error: Response(400, body: 'Request body must be form-encoded'));
    }
  }

  Future<({List<Map<String, dynamic>> jobs, List<ScheduledTaskDefinition> tasks})> _liveData(
    PageContext context,
  ) async {
    final readsContextConfig = configWriter == null;
    final configured = readsContextConfig
        ? context.config?.scheduling.jobs ?? const <Map<String, dynamic>>[]
        : await configWriter!.readSchedulingJobs();
    final jobs = <Map<String, dynamic>>[];
    final tasks = readsContextConfig ? [...?context.config?.scheduling.taskDefinitions] : <ScheduledTaskDefinition>[];
    for (final entry in configured) {
      try {
        final job = ScheduledJob.fromConfig(entry);
        if (job.jobType == ScheduledJobType.task) {
          if (!readsContextConfig) {
            if (job.taskDefinition case final definition?) tasks.add(definition);
          }
        } else if (!context.systemJobNames.contains(job.id)) {
          jobs.add({
            ...entry,
            'name': job.id,
            'schedule': job.cronExpression?.expression ?? entry['schedule'],
            'delivery': job.deliveryMode.name,
          });
        }
      } catch (_) {}
    }
    jobs.addAll(context.schedulingJobs.where((job) => context.systemJobNames.contains(job['id'] ?? job['name'])));
    return (jobs: jobs, tasks: tasks);
  }

  Set<String> _loadedIds() => scheduleServiceGetter?.call()?.entries.map((entry) => entry.id).toSet() ?? const {};
}
