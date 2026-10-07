import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ChannelNotificationAction,
        runActionNonceKey,
        runActionRunIdKey,
        runActionStepIdKey,
        runApproveActionId,
        runRequestChangesActionId,
        runRequestChangesSubmitActionId;

/// Maximum task description length before a card body is truncated.
const cardDescriptionMaxLength = 2000;

/// Name of the request-changes dialog's feedback input; the submission carries the text under this key.
const requestChangesFeedbackInputName = 'feedback';

/// Parameter key under which the dialog's submit button echoes the post the dialog was opened from.
const requestChangesPostParameter = 'postMessageId';

const _approveColor = {'red': 0.13, 'green': 0.59, 'blue': 0.33, 'alpha': 1.0};
const _rejectColor = {'red': 0.84, 'green': 0.18, 'blue': 0.18, 'alpha': 1.0};
const _changesColor = {'red': 0.98, 'green': 0.66, 'blue': 0.0, 'alpha': 1.0};

/// Purpose-built Google Chat Cards v2 builder for DartClaw notifications.
class ChatCardBuilder {
  const new();

  /// Builds a task notification card.
  Map<String, dynamic> taskNotification({
    required String taskId,
    required String title,
    required String status,
    String? description,
    String? errorSummary,
    String? requestedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool includeReviewButtons = false,
  }) {
    final sections = <Map<String, dynamic>>[_statusBadgeSection(status)];

    final trimmedDescription = description?.trim();
    if (trimmedDescription != null && trimmedDescription.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeAndTruncateDescription(trimmedDescription)},
          },
        ],
      });
    }

    final trimmedErrorSummary = errorSummary?.trim();
    if ((status == 'failed' || status == 'error') && trimmedErrorSummary != null && trimmedErrorSummary.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(trimmedErrorSummary)},
          },
        ],
      });
    }

    final timestampWidgets = <Map<String, dynamic>>[];
    final trimmedRequestedBy = requestedBy?.trim();
    if (trimmedRequestedBy != null && trimmedRequestedBy.isNotEmpty) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Requested by', 'text': _escapeText(trimmedRequestedBy)},
      });
    }
    if (createdAt != null) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Created', 'text': _formatTimestamp(createdAt)},
      });
    }
    if (updatedAt != null) {
      timestampWidgets.add({
        'decoratedText': {'topLabel': 'Updated', 'text': _formatTimestamp(updatedAt)},
      });
    }
    if (timestampWidgets.isNotEmpty) {
      sections.add({'widgets': timestampWidgets});
    }

    if (includeReviewButtons) {
      sections.add(_reviewButtonsSection(taskId));
    }

    return _wrapCard(
      cardId: 'task_$taskId',
      header: {'title': title, 'subtitle': _statusLabel(status)},
      sections: sections,
    );
  }

  /// Builds a workflow run lifecycle card: the workflow name as the title, the
  /// run [status], [facts] in order, then [body] and, for a failed run,
  /// [errorSummary]. It carries a button per entry of [actions], each reporting
  /// its action ID as the invoked function and [actionData] as its parameters;
  /// with no [actions] it carries none.
  Map<String, dynamic> runNotification({
    required String runId,
    required String title,
    required String status,
    Map<String, String> facts = const {},
    String? body,
    String? errorSummary,
    List<ChannelNotificationAction> actions = const [],
    Map<String, String> actionData = const {},
  }) {
    final sections = <Map<String, dynamic>>[_statusBadgeSection(status)];

    if (facts.isNotEmpty) {
      sections.add({
        'widgets': [
          for (final entry in facts.entries)
            {
              'decoratedText': {'topLabel': entry.key, 'text': _escapeText(entry.value), 'wrapText': true},
            },
        ],
      });
    }

    final trimmedBody = body?.trim();
    if (trimmedBody != null && trimmedBody.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeAndTruncateDescription(trimmedBody)},
          },
        ],
      });
    }

    final trimmedErrorSummary = errorSummary?.trim();
    if (status == 'failed' && trimmedErrorSummary != null && trimmedErrorSummary.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(trimmedErrorSummary)},
          },
        ],
      });
    }

    if (actions.isNotEmpty) {
      sections.add({
        'widgets': [
          {
            'buttonList': {
              'buttons': [
                for (final action in actions)
                  _actionButton(
                    text: action.label,
                    function: action.id,
                    parameters: actionData,
                    color: switch (action.id) {
                      runApproveActionId => _approveColor,
                      runRequestChangesActionId => _changesColor,
                      _ => _rejectColor,
                    },
                    opensDialog: action.id == runRequestChangesActionId,
                  ),
              ],
            },
          },
        ],
      });
    }

    return _wrapCard(
      cardId: 'run_$runId',
      header: {'title': title, 'subtitle': _statusLabel(status)},
      sections: sections,
    );
  }

  /// Builds an error notification card.
  Map<String, dynamic> errorNotification({
    required String title,
    required String errorSummary,
    String? taskId,
    String? sessionId,
  }) {
    final sections = <Map<String, dynamic>>[
      {
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(errorSummary.trim())},
          },
        ],
      },
    ];

    final referenceWidgets = <Map<String, dynamic>>[];
    if (taskId != null && taskId.isNotEmpty) {
      referenceWidgets.add({
        'decoratedText': {'topLabel': 'Task ID', 'text': _escapeText(taskId)},
      });
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      referenceWidgets.add({
        'decoratedText': {'topLabel': 'Session ID', 'text': _escapeText(sessionId)},
      });
    }
    if (referenceWidgets.isNotEmpty) {
      sections.add({'widgets': referenceWidgets});
    }

    return _wrapCard(
      cardId: 'error_${taskId ?? 'notification'}',
      header: {'title': title, 'subtitle': 'Error'},
      sections: sections,
    );
  }

  /// Builds a severity-colored alert notification card.
  ///
  /// [severity] must be `'info'`, `'warning'`, or `'critical'`. Unrecognized
  /// values fall back to no color (plain bold label).
  ///
  /// Severity colors: critical → `#d93025` (red), warning → `#f9ab00` (amber),
  /// info → `#1a73e8` (blue). These match existing [_statusColor] values.
  Map<String, dynamic> alertNotification({
    required String title,
    required String severity,
    required String body,
    Map<String, String>? details,
  }) {
    final color = _alertSeverityColor(severity);
    final severityLabel = _escapeText(_alertSeverityLabel(severity));
    final sections = <Map<String, dynamic>>[
      {
        'widgets': [
          {
            'decoratedText': {
              'topLabel': 'Severity',
              'text': color == null ? '<b>$severityLabel</b>' : '<font color="$color"><b>$severityLabel</b></font>',
              'wrapText': true,
            },
          },
        ],
      },
      {
        'widgets': [
          {
            'textParagraph': {'text': _escapeText(body.trim())},
          },
        ],
      },
    ];

    if (details != null && details.isNotEmpty) {
      sections.add({
        'widgets': [
          for (final entry in details.entries)
            {
              'decoratedText': {'topLabel': _escapeText(entry.key), 'text': _escapeText(entry.value)},
            },
        ],
      });
    }

    return _wrapCard(
      cardId: 'alert_${severity}_${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}',
      header: {'title': _escapeText(title), 'subtitle': _escapeText(_alertSeverityLabel(severity))},
      sections: sections,
    );
  }

  /// Builds a simple confirmation card.
  Map<String, dynamic> confirmationCard({required String title, required String message}) {
    return _wrapCard(
      cardId: 'confirmation',
      header: {'title': title, 'subtitle': 'Confirmation'},
      sections: [
        {
          'widgets': [
            {
              'textParagraph': {'text': _escapeText(message.trim())},
            },
          ],
        },
      ],
    );
  }

  /// Builds the body of the request-changes dialog: a multiline feedback input and a submit button that
  /// carries [runId], [stepId], [nonce] and the [postMessageId] it was opened from back under the submit action ID.
  ///
  /// A dialog submission is not documented to carry the message, so the post identity travels in the button.
  Map<String, dynamic> requestChangesDialog({
    required String runId,
    required String stepId,
    required String nonce,
    required String postMessageId,
  }) {
    return {
      'header': {'title': 'Request changes'},
      'sections': [
        {
          'widgets': [
            {
              'textInput': {
                'name': requestChangesFeedbackInputName,
                'label': 'What should change?',
                'type': 'MULTIPLE_LINE',
              },
            },
            {
              'buttonList': {
                'buttons': [
                  _actionButton(
                    text: 'Request changes',
                    function: runRequestChangesSubmitActionId,
                    parameters: {
                      runActionRunIdKey: runId,
                      runActionStepIdKey: stepId,
                      runActionNonceKey: nonce,
                      requestChangesPostParameter: postMessageId,
                    },
                    color: _changesColor,
                  ),
                ],
              },
            },
          ],
        },
      ],
    };
  }

  /// Builds the body of a dialog that shows only [message].
  Map<String, dynamic> messageDialog(String message) {
    return {
      'header': {'title': 'Request changes'},
      'sections': [
        {
          'widgets': [
            {
              'textParagraph': {'text': _escapeText(message.trim())},
            },
          ],
        },
      ],
    };
  }

  Map<String, dynamic> _wrapCard({
    required String cardId,
    required Map<String, dynamic> header,
    required List<Map<String, dynamic>> sections,
  }) {
    return {
      'cardsV2': [
        {
          'cardId': cardId,
          'card': {'header': header, 'sections': sections},
        },
      ],
    };
  }

  Map<String, dynamic> _reviewButtonsSection(String taskId) {
    return {
      'widgets': [
        {
          'buttonList': {
            'buttons': [
              _actionButton(
                text: 'Accept',
                function: 'task_accept',
                parameters: {'taskId': taskId},
                color: _approveColor,
              ),
              _actionButton(
                text: 'Reject',
                function: 'task_reject',
                parameters: {'taskId': taskId},
                color: _rejectColor,
              ),
            ],
          },
        },
      ],
    };
  }

  Map<String, dynamic> _statusBadgeSection(String status) {
    final color = _statusColor(status);
    final label = _escapeText(_statusLabel(status));
    return {
      'widgets': [
        {
          'decoratedText': {
            'topLabel': 'Status',
            'text': color == null ? '<b>$label</b>' : '<font color="$color"><b>$label</b></font>',
            'wrapText': true,
          },
        },
      ],
    };
  }

  Map<String, dynamic> _actionButton({
    required String text,
    required String function,
    required Map<String, String> parameters,
    required Map<String, double> color,
    bool opensDialog = false,
  }) {
    return {
      'text': text,
      'onClick': {
        'action': {
          'function': function,
          'parameters': [
            for (final entry in parameters.entries) {'key': entry.key, 'value': entry.value},
          ],
          if (opensDialog) 'interaction': 'OPEN_DIALOG',
        },
      },
      'color': color,
    };
  }

  String _escapeAndTruncateDescription(String description) {
    final escapedSegments = <String>[for (final rune in description.runes) _escapeText(String.fromCharCode(rune))];
    final escapedLength = escapedSegments.fold<int>(0, (total, segment) => total + segment.length);
    if (escapedLength <= cardDescriptionMaxLength) {
      return escapedSegments.join();
    }

    final maxContentLength = cardDescriptionMaxLength - 3;
    final buffer = StringBuffer();
    var truncatedLength = 0;
    for (final escapedSegment in escapedSegments) {
      if (truncatedLength + escapedSegment.length > maxContentLength) {
        break;
      }
      buffer.write(escapedSegment);
      truncatedLength += escapedSegment.length;
    }
    return '${buffer.toString()}...';
  }

  String _statusLabel(String status) => switch (status) {
    'running' => 'Running',
    'review' => 'Needs Review',
    'accepted' => 'Accepted',
    'rejected' => 'Rejected',
    'failed' => 'Failed',
    'error' => 'Error',
    'started' => 'Started',
    'awaiting_approval' => 'Awaiting Approval',
    'finished' => 'Finished',
    'step_completed' => 'Step Completed',
    _ => status,
  };

  String? _statusColor(String status) => switch (status) {
    'running' || 'started' || 'step_completed' => '#1a73e8',
    'awaiting_approval' => '#f9ab00',
    'finished' => '#1e8e3e',
    'review' => '#f9ab00',
    'accepted' => '#1e8e3e',
    'rejected' => '#d93025',
    'failed' => '#d93025',
    'error' => '#d93025',
    _ => null,
  };

  String _alertSeverityLabel(String severity) => switch (severity) {
    'critical' => 'Critical',
    'warning' => 'Warning',
    'info' => 'Info',
    _ => severity,
  };

  String? _alertSeverityColor(String severity) => switch (severity) {
    'critical' => '#d93025',
    'warning' => '#f9ab00',
    'info' => '#1a73e8',
    _ => null,
  };

  String _formatTimestamp(DateTime timestamp) {
    final utc = timestamp.toUtc();
    return '${utc.year}-${_pad(utc.month)}-${_pad(utc.day)} '
        '${_pad(utc.hour)}:${_pad(utc.minute)} UTC';
  }

  String _pad(int value) => value.toString().padLeft(2, '0');

  String _escapeText(String value) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(value).replaceAll('\n', '<br>');
  }
}
