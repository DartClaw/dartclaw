/// Environment variable names injected by S60 plumbing into agent processes
/// that execute the `dartclaw-merge-resolve` skill.
///
/// These names are the locked contract between S60 (plumbing) and S59 (skill).
/// All values are decimal strings or branch names. Optional vars default to
/// empty string when unset (POSIX expansion); skills MUST NOT assume presence.
const mergeResolveIntegrationBranchEnvVar = 'MERGE_RESOLVE_INTEGRATION_BRANCH';
const mergeResolveStoryBranchEnvVar = 'MERGE_RESOLVE_STORY_BRANCH';
const mergeResolveTokenCeilingEnvVar = 'MERGE_RESOLVE_TOKEN_CEILING';
const mergeResolveVerifyFormatEnvVar = 'MERGE_RESOLVE_VERIFY_FORMAT';
const mergeResolveVerifyAnalyzeEnvVar = 'MERGE_RESOLVE_VERIFY_ANALYZE';
const mergeResolveVerifyTestEnvVar = 'MERGE_RESOLVE_VERIFY_TEST';

/// All six locked env-var names as a set — useful for presence checks / docs.
const mergeResolveEnvVarNames = {
  mergeResolveIntegrationBranchEnvVar,
  mergeResolveStoryBranchEnvVar,
  mergeResolveTokenCeilingEnvVar,
  mergeResolveVerifyFormatEnvVar,
  mergeResolveVerifyAnalyzeEnvVar,
  mergeResolveVerifyTestEnvVar,
};
