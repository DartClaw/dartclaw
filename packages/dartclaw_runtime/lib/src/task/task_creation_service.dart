import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:uuid/uuid.dart';

import 'task_config_view.dart';
import 'task_service.dart';

sealed class TaskCreationResult {
  const new();
}

final class TaskCreated extends TaskCreationResult {
  const new(this.task);
  final Task task;
}

final class TaskCreationRefused extends TaskCreationResult {
  const new(this.message, {this.field, this.key});
  final String message;
  final String? field;
  final String? key;
}

/// Creates tasks for both the JSON API and the server-rendered web surface.
final class TaskCreationService {
  const new({required this.tasks, this.projects});

  final TaskService tasks;
  final ProjectService? projects;

  Future<TaskCreationResult> create(Map<String, dynamic> body) async {
    for (final field in const ['title', 'description']) {
      final refusal = _validateStringField(body, field);
      if (refusal != null) return refusal;
    }
    final retiredCategory = _retiredCategoryRefusal(body);
    if (retiredCategory != null) return retiredCategory;
    for (final field in const [
      ('goalId', false),
      ('acceptanceCriteria', false),
      ('provider', true),
      ('model', false),
      ('securityProfile', true),
      ('sessionId', false),
      ('projectId', false),
    ]) {
      final refusal = _validateStringField(body, field.$1, rejectBlank: field.$2);
      if (refusal != null) return refusal;
    }
    final maxTokensRefusal = _validateMaxTokens(body);
    if (maxTokensRefusal != null) return maxTokensRefusal;

    final title = _trimmedStringOrNull(body['title']);
    final description = _trimmedStringOrNull(body['description']);
    final projectId = _trimmedStringOrNull(body['projectId']);
    if (projectId != null && projects != null && await projects!.get(projectId) == null) {
      return const TaskCreationRefused('projectId must reference an existing project', field: 'projectId');
    }
    if (title == null) return const TaskCreationRefused('title must not be empty', field: 'title');
    if (description == null) {
      return const TaskCreationRefused('description must not be empty', field: 'description');
    }

    final securityProfile = _trimmedStringOrNull(body['securityProfile']);
    if (securityProfile != null && !containerSecurityProfiles.contains(securityProfile)) {
      return TaskCreationRefused(
        'securityProfile must be one of: ${containerSecurityProfiles.join(', ')}',
        field: 'securityProfile',
      );
    }
    final autoStart = body['autoStart'] == true;
    if (body.containsKey('autoStart') && body['autoStart'] is! bool) {
      return const TaskCreationRefused('autoStart must be a boolean', field: 'autoStart');
    }

    if (body.containsKey('configJson') && body['configJson'] != null && body['configJson'] is! Map) {
      return const TaskCreationRefused('configJson must be a JSON object', field: 'configJson');
    }
    final configJson = body['configJson'] == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(body['configJson'] as Map);
    final provider = configJson['provider'];
    if (provider != null && (provider is! String || provider.trim().isEmpty)) {
      return const TaskCreationRefused('configJson.provider must be a non-blank string', field: 'configJson.provider');
    }
    if (configJson.containsKey(TaskConfigView.needsWorktreeKey) &&
        configJson[TaskConfigView.needsWorktreeKey] is! bool) {
      return const TaskCreationRefused(
        'configJson.needsWorktree must be a boolean',
        field: 'configJson',
        key: TaskConfigView.needsWorktreeKey,
      );
    }
    if (configJson.containsKey('securityProfile')) {
      return const TaskCreationRefused(
        'configJson.securityProfile is reserved; use the top-level securityProfile field',
        field: 'configJson',
        key: 'securityProfile',
      );
    }
    final internalKey = configJson.keys.firstWhere((key) => key.startsWith('_'), orElse: () => '');
    if (internalKey.isNotEmpty) {
      return TaskCreationRefused(
        'configJson keys starting with "_" are reserved for internal system use',
        field: 'configJson',
        key: internalKey,
      );
    }

    final createdByRaw = body['createdBy'] is String ? body['createdBy'] as String : null;
    final task = await tasks.create(
      id: const Uuid().v4(),
      title: title,
      description: description,
      autoStart: autoStart,
      goalId: body['goalId'] as String?,
      acceptanceCriteria: body['acceptanceCriteria'] as String?,
      createdBy: createdByRaw?.trim().isNotEmpty == true ? createdByRaw!.trim() : 'operator',
      provider: _trimmedStringOrNull(body['provider']),
      model: _trimmedStringOrNull(body['model']),
      securityProfile: securityProfile,
      sessionId: _trimmedStringOrNull(body['sessionId']),
      maxTokens: (body['maxTokens'] as num?)?.toInt(),
      projectId: projectId,
      configJson: configJson,
      trigger: 'user',
    );
    return TaskCreated(task);
  }
}

String? _trimmedStringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

TaskCreationRefused? _validateStringField(Map<String, dynamic> body, String field, {bool rejectBlank = false}) {
  if (!body.containsKey(field)) return null;
  final value = body[field];
  if (value == null || value is String && (!rejectBlank || value.trim().isNotEmpty)) return null;
  return TaskCreationRefused(value is String ? '$field must not be blank' : '$field must be a string', field: field);
}

TaskCreationRefused? _retiredCategoryRefusal(Map<String, dynamic> body) {
  final refusal = retiredTaskCategoryRefusal([body['type'], body['task_type']]);
  if (refusal != null) {
    final retiredValue = refusal is RetiredTaskTypeException ? retiredResearchTaskType : retiredCodingTaskType;
    final field = body['type'] == retiredValue ? 'type' : 'task_type';
    return TaskCreationRefused(refusal.toString(), field: field);
  }
  final field = body.containsKey('type')
      ? 'type'
      : body.containsKey('task_type')
      ? 'task_type'
      : null;
  return field == null ? null : TaskCreationRefused('Task category is retired; remove the $field field.', field: field);
}

TaskCreationRefused? _validateMaxTokens(Map<String, dynamic> body) {
  if (!body.containsKey('maxTokens') || body['maxTokens'] == null) return null;
  final raw = body['maxTokens'];
  if (raw is! num) return const TaskCreationRefused('maxTokens must be a number', field: 'maxTokens');
  if (raw is double && raw != raw.truncateToDouble()) {
    return const TaskCreationRefused('maxTokens must be a whole number', field: 'maxTokens');
  }
  if (raw.toInt() <= 0) {
    return const TaskCreationRefused('maxTokens must be a positive integer', field: 'maxTokens');
  }
  return null;
}
