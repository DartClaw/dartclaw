import 'package:test/test.dart';

import 'workflow_e2e_preconditions.dart';

void main() {
  test('reports a human-readable recovery message when GITHUB_TOKEN is missing', () {
    expect(
      missingWorkflowE2eGitHubTokenMessage(const {}),
      'GITHUB_TOKEN must be set for workflow e2e (try: export GITHUB_TOKEN=\$(gh auth token))',
    );
  });

  test('allows the e2e suite to proceed when GITHUB_TOKEN is present', () {
    expect(missingWorkflowE2eGitHubTokenMessage(const {'GITHUB_TOKEN': 'token'}), isNull);
  });
}
