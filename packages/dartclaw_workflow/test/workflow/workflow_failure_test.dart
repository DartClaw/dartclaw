// The typed workflow failure vocabulary: its persisted discriminators and the
// exact-equality contract the step-retry early stop compares on.
//
// Imported through the package barrel on purpose — the vocabulary is the
// binding point downstream consumers extend, so its export is part of the
// contract this file pins.
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowEscalatedHardFailure,
        WorkflowFailure,
        WorkflowForeachControllerFailure,
        WorkflowIterationBlockedHold,
        WorkflowIterationCancelled,
        WorkflowIterationFailure,
        WorkflowLegacyIterationStateFailure,
        WorkflowModelDeclaredFailure,
        WorkflowOutputValidationFailure,
        WorkflowPromotionConflictFailure,
        WorkflowPromotionFailure,
        WorkflowSerializeRemainingSettleTimeout,
        WorkflowStepRetryFailure,
        WorkflowTaskTerminalStatusFailure,
        workflowFailureFromPersisted,
        workflowFailureKinds;
import 'package:test/test.dart';

void main() {
  group('persisted iteration vocabulary', () {
    // One entry per shipped producer group named in the story: promotion
    // conflict and failure, the foreach aggregate's controller / settle-timeout
    // / escalated / ordinary arms, the blocked and cancelled slots, and the
    // resume break. Asserted as an exact set rather than by a negative match,
    // so adding a variant without a producer — or dropping one — fails here.
    const expectedKinds = {
      'promotion-conflict',
      'promotion-failure',
      'foreach-controller-failure',
      'serialize-remaining-settle-timeout',
      'hard-failure-with-escalation',
      'iteration-failure',
      'iteration-blocked',
      'iteration-cancelled',
      'legacy-iteration-state',
    };

    final values = <WorkflowFailure>[
      const WorkflowPromotionConflictFailure('promotion-conflict: lib/a.dart'),
      const WorkflowPromotionFailure('promotion failed: remote rejected'),
      const WorkflowForeachControllerFailure('foreach-controller-failure: budget exhausted'),
      const WorkflowSerializeRemainingSettleTimeout('serialize-remaining settle-timeout: 1 in-flight'),
      const WorkflowEscalatedHardFailure('foreach-hard-failure-with-escalation: 1 failed'),
      const WorkflowIterationFailure("Foreach child step 'implement' failed"),
      const WorkflowIterationBlockedHold('needs a human'),
      const WorkflowIterationCancelled('Cancelled: dispatch stall'),
      const WorkflowLegacyIterationStateFailure('cannot resume'),
    ];

    test('every variant has a distinct discriminator and the set is exactly the shipped producers', () {
      expect(values.map((value) => value.kind).toSet(), hasLength(values.length));
      expect(values.map((value) => value.kind).toSet(), equals(expectedKinds));
      expect(workflowFailureKinds, equals(expectedKinds));
    });

    test('each value round-trips through its persisted form', () {
      for (final value in values) {
        final restored = workflowFailureFromPersisted(value.kind, value.message);
        expect(restored, equals(value), reason: '${value.kind} must rebuild to the same value');
        expect(restored.runtimeType, equals(value.runtimeType));
      }
    });

    test('an absent or unrecognised discriminator restores nothing, so the caller can fail the resume', () {
      expect(workflowFailureFromPersisted(null, 'message'), isNull);
      expect(workflowFailureFromPersisted('kind-from-a-later-release', 'message'), isNull);
      expect(workflowFailureFromPersisted(42, 'message'), isNull);
    });

    test('the message is payload, not identity: same kind with different text is a different value', () {
      expect(
        const WorkflowPromotionFailure('promotion failed: a'),
        isNot(equals(const WorkflowPromotionFailure('promotion failed: b'))),
      );
    });
  });

  group('step-retry vocabulary equality', () {
    // The rule is per-variant: the host chose the kind for a host-classified
    // failure, so the kind alone decides; only the model-declared variant's own
    // reason travels into the comparison.
    test('a host-classified variant compares on its kind alone', () {
      expect(
        const WorkflowOutputValidationFailure('missing lib/a.md'),
        equals(const WorkflowOutputValidationFailure('missing lib/b.md')),
        reason: 'two output-validation misses are a repeat however differently they read',
      );
      expect(
        const WorkflowTaskTerminalStatusFailure('failed'),
        equals(const WorkflowTaskTerminalStatusFailure('rejected')),
      );
    });

    test('a model-declared failure compares on kind and its verbatim reason', () {
      expect(const WorkflowModelDeclaredFailure('Boom'), equals(const WorkflowModelDeclaredFailure('Boom')));
      expect(
        const WorkflowModelDeclaredFailure('Boom'),
        isNot(equals(const WorkflowModelDeclaredFailure('Different'))),
        reason: 'collapsing two model reasons would cap onFailure: retry at two attempts',
      );
    });

    test('the three kinds are distinct from each other even on identical text', () {
      const failures = <WorkflowStepRetryFailure>[
        WorkflowModelDeclaredFailure('Boom'),
        WorkflowOutputValidationFailure('Boom'),
        WorkflowTaskTerminalStatusFailure('Boom'),
      ];
      for (var i = 0; i < failures.length; i++) {
        for (var j = i + 1; j < failures.length; j++) {
          expect(failures[i], isNot(equals(failures[j])), reason: '${failures[i]} vs ${failures[j]}');
        }
      }
    });

    test('the model-declared comparison is exact: no lowercasing, prefix strip, delimiter cut or clip', () {
      expect(
        const WorkflowModelDeclaredFailure('Boom'),
        isNot(equals(const WorkflowModelDeclaredFailure('boom'))),
        reason: 'case is part of the payload',
      );
      expect(
        const WorkflowModelDeclaredFailure('Deterministic error: same input'),
        isNot(equals(const WorkflowModelDeclaredFailure('Deterministic error: other input'))),
        reason: 'text after the first delimiter still distinguishes two reasons',
      );
      expect(
        const WorkflowModelDeclaredFailure('StateError: Boom'),
        isNot(equals(const WorkflowModelDeclaredFailure('Boom'))),
        reason: 'no exception prefix is stripped before comparing',
      );
      expect(
        WorkflowModelDeclaredFailure('x' * 100),
        isNot(equals(WorkflowModelDeclaredFailure('${'x' * 100}y'))),
        reason: 'nothing is clipped at 80 characters',
      );
    });
  });
}
