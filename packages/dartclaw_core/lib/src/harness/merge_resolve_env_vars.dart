/// Environment variable names injected into agent processes that execute the
/// `dartclaw-merge-resolve` skill.
///
/// All values are decimal strings or branch names.
const mergeResolveIntegrationBranchEnvVar = 'MERGE_RESOLVE_INTEGRATION_BRANCH';
const mergeResolveStoryBranchEnvVar = 'MERGE_RESOLVE_STORY_BRANCH';
const mergeResolveTokenCeilingEnvVar = 'MERGE_RESOLVE_TOKEN_CEILING';

/// All locked env-var names as a set — useful for presence checks / docs.
const mergeResolveEnvVarNames = {
  mergeResolveIntegrationBranchEnvVar,
  mergeResolveStoryBranchEnvVar,
  mergeResolveTokenCeilingEnvVar,
};
