import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:meta/meta.dart';
import 'package:shelf/shelf.dart';

class ChatCommandHandler {
  final WorkflowService workflows;
  final WorkflowDefinitionSource definitions;
  final Duration duplicateCooldown;
  final DateTime Function() now;
  final Map<String, DateTime> _recentCommands = <String, DateTime>{};

  ChatCommandHandler({
    required this.workflows,
    required this.definitions,
    this.duplicateCooldown = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  Future<Response?> handle(Request request, Session session, String message) async {
    if (!message.startsWith('/workflow')) {
      return null;
    }

    final tokens = _tokenize(message);
    if (tokens.length < 2) {
      return _htmlResponse(
        _workflowCardHtml('Workflow command', 'Usage: /workflow list or /workflow run <name> KEY=value', error: true),
      );
    }

    return switch (tokens[1]) {
      'list' => _htmlResponse(_workflowCardHtml('Available workflows', _definitionsList(), error: false)),
      'run' => _handleRun(tokens, session),
      _ => _htmlResponse(_workflowCardHtml('Workflow command', 'Unknown subcommand: ${tokens[1]}', error: true)),
    };
  }

  Future<Response> _handleRun(List<String> tokens, Session session) async {
    if (tokens.length < 3) {
      return _htmlResponse(_workflowCardHtml('Workflow command', 'Usage: /workflow run <name> KEY=value', error: true));
    }
    final definitionName = tokens[2];
    final definition = definitions.getByName(definitionName);
    if (definition == null) {
      return _htmlResponse(
        _workflowCardHtml('Workflow command', 'Workflow definition not found: $definitionName', error: true),
      );
    }

    final variables = <String, String>{};
    for (final token in tokens.skip(3)) {
      final eq = token.indexOf('=');
      if (eq < 1) {
        continue;
      }
      variables[token.substring(0, eq)] = token.substring(eq + 1);
    }

    final dedupKey = '${session.id}|${tokens.join(' ')}';
    final previous = _recentCommands[dedupKey];
    final currentTime = now();
    if (previous != null && currentTime.difference(previous) < duplicateCooldown) {
      return _htmlResponse(
        _workflowCardHtml('Workflow command', 'This workflow command was already handled recently.', error: true),
      );
    }
    _recentCommands[dedupKey] = currentTime;

    final run = await workflows.start(definition, variables, projectId: variables['PROJECT']);
    return _htmlResponse(
      _workflowCardHtml(
        'Workflow started',
        'Started ${definition.name} as run ${run.id}.',
        linkHref: '/workflows/${run.id}',
        linkLabel: 'Open workflow run',
      ),
    );
  }

  String _definitionsList() {
    final summaries = definitions.listSummaries();
    if (summaries.isEmpty) {
      return 'No workflow definitions are available.';
    }
    return summaries.map((definition) => '${definition.name}: ${definition.description}').join('\n');
  }

  @visibleForTesting
  List<String> tokenize(String input) => _tokenize(input);
}

List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    if (char == '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (!inQuotes && char.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) {
    tokens.add(buffer.toString());
  }
  return tokens;
}

Response _htmlResponse(String html) {
  return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
}

String _workflowCardHtml(String title, String body, {String? linkHref, String? linkLabel, bool error = false}) {
  final safeTitle = htmlEscape.convert(title);
  final safeBody = htmlEscape.convert(body).replaceAll('\n', '<br>');
  final link = linkHref == null || linkLabel == null
      ? ''
      : '<p><a href="${htmlEscape.convert(linkHref)}" hx-get="${htmlEscape.convert(linkHref)}" '
            'hx-target="#main-content" hx-select="#main-content" hx-swap="outerHTML" hx-push-url="true">'
            '${htmlEscape.convert(linkLabel)}</a></p>';
  final cssClass = error ? 'msg msg-turn-failed workflow-command-card' : 'msg msg-assistant workflow-command-card';
  return '<div class="$cssClass"><div class="msg-role">Workflow</div><div class="msg-content"><p>$safeTitle</p><p>$safeBody</p>$link</div></div>';
}
