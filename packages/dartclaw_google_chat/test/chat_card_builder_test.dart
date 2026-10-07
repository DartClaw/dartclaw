import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelNotificationAction;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  const builder = ChatCardBuilder();

  group('ChatCardBuilder.taskNotification', () {
    test('builds a Cards v2 task notification with review buttons', () {
      final card = builder.taskNotification(
        taskId: 'task-123',
        title: 'Fix login',
        status: 'review',
        description: 'Review the final patch.',
        createdAt: DateTime.parse('2026-03-13T10:00:00Z'),
        updatedAt: DateTime.parse('2026-03-13T11:30:00Z'),
        includeReviewButtons: true,
      );

      expect(card['cardsV2'], hasLength(1));
      final cardEntry = (card['cardsV2'] as List).single as Map<String, dynamic>;
      expect(cardEntry['cardId'], 'task_task-123');

      final innerCard = cardEntry['card'] as Map<String, dynamic>;
      expect(innerCard['header'], {'title': 'Fix login', 'subtitle': 'Needs Review'});

      final sections = innerCard['sections'] as List;
      expect(sections, hasLength(4));
      final statusWidget =
          (((sections.first as Map<String, dynamic>)['widgets'] as List).single
                  as Map<String, dynamic>)['decoratedText']
              as Map<String, dynamic>;
      expect(statusWidget['topLabel'], 'Status');
      expect(statusWidget['text'], '<font color="#f9ab00"><b>Needs Review</b></font>');
      final buttonList =
          (((sections.last as Map<String, dynamic>)['widgets'] as List).single as Map<String, dynamic>)['buttonList']
              as Map<String, dynamic>;
      final buttons = buttonList['buttons'] as List;
      expect(buttons, hasLength(2));
      expect((buttons.first as Map<String, dynamic>)['text'], 'Accept');
      expect(
        (((buttons.first as Map<String, dynamic>)['onClick'] as Map<String, dynamic>)['action']
            as Map<String, dynamic>)['function'],
        'task_accept',
      );
      expect(
        (((buttons.first as Map<String, dynamic>)['onClick'] as Map<String, dynamic>)['action']
            as Map<String, dynamic>)['parameters'],
        [
          {'key': 'taskId', 'value': 'task-123'},
        ],
      );
      expect((buttons.first as Map<String, dynamic>)['color'], const {
        'red': 0.13,
        'green': 0.59,
        'blue': 0.33,
        'alpha': 1.0,
      });
      expect((buttons.last as Map<String, dynamic>)['text'], 'Reject');
      expect(
        (((buttons.last as Map<String, dynamic>)['onClick'] as Map<String, dynamic>)['action']
            as Map<String, dynamic>)['function'],
        'task_reject',
      );
      expect(
        (((buttons.last as Map<String, dynamic>)['onClick'] as Map<String, dynamic>)['action']
            as Map<String, dynamic>)['parameters'],
        [
          {'key': 'taskId', 'value': 'task-123'},
        ],
      );
      expect((buttons.last as Map<String, dynamic>)['color'], const {
        'red': 0.84,
        'green': 0.18,
        'blue': 0.18,
        'alpha': 1.0,
      });
    });

    test('truncates descriptions based on escaped output length', () {
      final description = '<>&' * 500;
      final card = builder.taskNotification(
        taskId: 'task-123',
        title: 'Fix login',
        status: 'running',
        description: description,
      );

      final cardEntry = ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      final sections = cardEntry['sections'] as List;
      final descriptionSection = sections[1] as Map<String, dynamic>;
      final descriptionText =
          ((((descriptionSection['widgets'] as List).single as Map<String, dynamic>)['textParagraph']
                  as Map<String, dynamic>)['text'])
              as String;

      expect(descriptionText, hasLength(cardDescriptionMaxLength));
      expect(descriptionText, endsWith('...'));
      expect(descriptionText.substring(0, descriptionText.length - 3), endsWith(';'));
      expect(descriptionText, contains('&lt;'));
      expect(descriptionText, contains('&gt;'));
      expect(descriptionText, contains('&amp;'));
    });

    test('omits description, timestamps, and buttons when absent', () {
      final card = builder.taskNotification(taskId: 'task-123', title: 'Fix login', status: 'running');

      final cardEntry = ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      final sections = cardEntry['sections'] as List;

      expect(sections, hasLength(1));
    });

    test('includes error summary for failed task notifications', () {
      final card = builder.taskNotification(
        taskId: 'task-123',
        title: 'Fix login',
        status: 'failed',
        description: 'Review the failure details.',
        errorSummary: 'Token budget exceeded.',
      );

      final cardEntry = ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      final sections = cardEntry['sections'] as List;
      expect(sections, hasLength(3));
      final errorSection = sections[2] as Map<String, dynamic>;
      final errorText =
          ((((errorSection['widgets'] as List).single as Map<String, dynamic>)['textParagraph']
                  as Map<String, dynamic>)['text'])
              as String;

      expect(errorText, 'Token budget exceeded.');
    });
  });

  group('ChatCardBuilder.errorNotification', () {
    test('builds an error card with references', () {
      final card = builder.errorNotification(
        title: 'Merge Conflict',
        errorSummary: 'Conflicts detected.',
        taskId: 'task-123',
        sessionId: 'session-456',
      );

      final cardEntry = ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      expect(cardEntry['header'], {'title': 'Merge Conflict', 'subtitle': 'Error'});
      final sections = cardEntry['sections'] as List;
      expect(sections, hasLength(2));
      final referenceWidgets = ((sections[1] as Map<String, dynamic>)['widgets'] as List).cast<Map<String, dynamic>>();
      expect(referenceWidgets, hasLength(2));
    });
  });

  group('ChatCardBuilder.runNotification', () {
    Map<String, dynamic> innerCard(Map<String, dynamic> card) =>
        ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;

    List<Map<String, dynamic>> widgetsOf(Object? section) =>
        ((section as Map<String, dynamic>)['widgets'] as List).cast<Map<String, dynamic>>();

    test('builds a button-free card with the workflow as title and facts in order', () {
      final card = builder.runNotification(
        runId: 'run-9',
        title: 'Release <check>',
        status: 'awaiting_approval',
        facts: const {'Workflow': 'release', 'Run': 'run-9', 'Step': 'approve & ship'},
        body: 'Gates the <deploy>.',
      );

      expect(((card['cardsV2'] as List).single as Map<String, dynamic>)['cardId'], 'run_run-9');
      final inner = innerCard(card);
      expect(inner['header'], {'title': 'Release <check>', 'subtitle': 'Awaiting Approval'});

      final sections = inner['sections'] as List;
      expect(sections, hasLength(3));
      final badge = widgetsOf(sections[0]).single['decoratedText'] as Map<String, dynamic>;
      expect(badge['topLabel'], 'Status');
      expect(badge['text'], '<font color="#f9ab00"><b>Awaiting Approval</b></font>');

      final facts = [for (final w in widgetsOf(sections[1])) w['decoratedText'] as Map<String, dynamic>];
      expect([for (final f in facts) f['topLabel']], ['Workflow', 'Run', 'Step']);
      expect(facts.last['text'], 'approve &amp; ship');

      expect(
        (widgetsOf(sections[2]).single['textParagraph'] as Map<String, dynamic>)['text'],
        'Gates the &lt;deploy&gt;.',
      );
      expect(jsonEncode(card), isNot(contains('buttonList')));
    });

    test('renders a button per action, invoking the action ID with the action data as parameters', () {
      final card = builder.runNotification(
        runId: 'run-9',
        title: 'Release',
        status: 'awaiting_approval',
        actions: const [
          ChannelNotificationAction(id: 'run_approve', label: 'Approve'),
          ChannelNotificationAction(id: 'run_reject', label: 'Reject'),
        ],
        actionData: const {'runId': 'run-9', 'stepId': 'gate', 'nonce': 'abc123'},
      );

      final sections = innerCard(card)['sections'] as List;
      final buttons = ((widgetsOf(sections.last).single['buttonList'] as Map<String, dynamic>)['buttons'] as List)
          .cast<Map<String, dynamic>>();
      expect([for (final b in buttons) b['text']], ['Approve', 'Reject']);
      final actions = [
        for (final b in buttons) (b['onClick'] as Map<String, dynamic>)['action'] as Map<String, dynamic>,
      ];
      expect([for (final a in actions) a['function']], ['run_approve', 'run_reject']);
      for (final action in actions) {
        expect(action['parameters'], [
          {'key': 'runId', 'value': 'run-9'},
          {'key': 'stepId', 'value': 'gate'},
          {'key': 'nonce', 'value': 'abc123'},
        ]);
      }
      expect(buttons.first['color'], isNot(buttons.last['color']));
    });

    test('shows the error only for a failed run', () {
      final failed = innerCard(
        builder.runNotification(runId: 'r', title: 'W', status: 'failed', errorSummary: 'a < b'),
      );
      final failedSections = failed['sections'] as List;
      expect(failedSections, hasLength(2));
      expect((widgetsOf(failedSections.last).single['textParagraph'] as Map<String, dynamic>)['text'], 'a &lt; b');

      final finished = innerCard(
        builder.runNotification(runId: 'r', title: 'W', status: 'finished', errorSummary: 'x'),
      );
      expect(finished['sections'], hasLength(1));
    });

    test('labels every run status', () {
      String subtitle(String status) =>
          innerCard(builder.runNotification(runId: 'r', title: 'W', status: status))['header']['subtitle'] as String;

      expect(
        [
          for (final s in ['started', 'awaiting_approval', 'finished', 'failed', 'step_completed']) subtitle(s),
        ],
        ['Started', 'Awaiting Approval', 'Finished', 'Failed', 'Step Completed'],
      );
    });
  });

  group('ChatCardBuilder.confirmationCard', () {
    test('builds a confirmation card', () {
      final card = builder.confirmationCard(title: 'Task accepted', message: "Task 'Fix login' has been accepted.");

      final cardEntry = ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      expect(cardEntry['header'], {'title': 'Task accepted', 'subtitle': 'Confirmation'});
      final bodyText =
          (((((cardEntry['sections'] as List).single as Map<String, dynamic>)['widgets'] as List).single
                  as Map<String, dynamic>)['textParagraph']
              as Map<String, dynamic>)['text'];
      expect(bodyText, "Task 'Fix login' has been accepted.");
    });
  });
}
