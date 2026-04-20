String? missingWorkflowE2eGitHubTokenMessage(Map<String, String> env) {
  final githubToken = env['GITHUB_TOKEN']?.trim();
  if (githubToken == null || githubToken.isEmpty) {
    return 'GITHUB_TOKEN must be set for workflow e2e (try: export GITHUB_TOKEN=\$(gh auth token))';
  }
  return null;
}
