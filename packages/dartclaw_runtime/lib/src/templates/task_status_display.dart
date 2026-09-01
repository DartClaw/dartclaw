/// How one task lifecycle status presents: the label the operator reads, the
/// canon `.status-pill--*` variant and the canon `.status-dot--*` variant.
typedef TaskStatusPresentation = ({String label, String pill, String dot});

/// The one presentation table for task lifecycle status.
///
/// Every consumer — task list and task detail — resolves through
/// [taskStatusPresentation], so a status cannot read one way in the table and
/// another on the detail page. `unknown` is a real entry, not a fallback branch:
/// an unrecognised, null, absent or empty status is reported as unknown rather
/// than silently presented as a draft.
const taskStatusPresentations = <String, TaskStatusPresentation>{
  'draft': (label: 'Draft', pill: 'info', dot: 'idle'),
  'queued': (label: 'Queued', pill: 'info', dot: 'attention'),
  'running': (label: 'Running', pill: 'live', dot: 'live'),
  'interrupted': (label: 'Interrupted', pill: 'warning', dot: 'warning'),
  'review': (label: 'Review', pill: 'warning', dot: 'attention'),
  'accepted': (label: 'Accepted', pill: 'live', dot: 'success'),
  'rejected': (label: 'Rejected', pill: 'error', dot: 'error'),
  'cancelled': (label: 'Cancelled', pill: 'error', dot: 'error'),
  'failed': (label: 'Failed', pill: 'error', dot: 'error'),
  'unknown': (label: 'Unknown', pill: 'info', dot: 'idle'),
};

/// Normalises any raw status value to a key of [taskStatusPresentations].
///
/// Null, an absent key, an empty string and an unrecognised name all resolve to
/// `unknown`, which is what keeps grouping and rendering agreeing on one bucket.
String taskStatusKey(Object? status) {
  final name = status?.toString();
  if (name == null || name.isEmpty) return 'unknown';
  return taskStatusPresentations.containsKey(name) ? name : 'unknown';
}

/// The presentation for any raw status value. Never null.
TaskStatusPresentation taskStatusPresentation(Object? status) => taskStatusPresentations[taskStatusKey(status)]!;
