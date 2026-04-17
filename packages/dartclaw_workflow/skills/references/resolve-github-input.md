# Resolve GitHub Input

Standard procedure for skills that accept `--issue <number>`, a GitHub issue URL, or a GitHub PR comment URL as input. Each calling skill declares its **compatible artifact types** and provides a **routing table** for incompatible types.

## Procedure

1. **Fetch**: use `gh issue view <number>` (or `gh api` for PR comments) to retrieve the body
2. **Inspect**: check for a typed envelope (`<!-- ANDTHEN_ARTIFACT:BEGIN -->`) per `github-artifact-roundtrip.md`
3. **If typed envelope found**:
   a. Validate `schema` and `artifact_type`
   b. If `artifact_type` is in the calling skill's compatible list: extract embedded files to `.agent_temp/github-artifacts/{github-id}-{artifact_type}/`, preserving repo-relative paths from `### File:` headings. Use `canonical_local_primary` to identify the primary file. Recover metadata (`plan_path`, `fis_path`, `story_ids`, `report_path`, `requirements_baseline`, `implementation_targets`, `source_issue_number`) for downstream use
   c. **Canonical-local fallback**: if the extracted primary file already exists locally at its declared canonical path, switch to the local file and treat the extraction as a read-only reference
   d. If `artifact_type` is NOT compatible: **stop** and redirect to the correct downstream skill per the calling skill's routing table
4. **If untyped**: apply the calling skill's untyped-input rule (some skills accept untyped issues as raw requirements; others require a typed artifact and must stop)

## Routing Table Template

Each skill using this procedure defines inline:

All names below name **skills** (invoke via slash commands like `/dartclaw-spec-plan`); none are valid `subagent_type` values.

```
Compatible types: [list]
Routing for incompatible types:
  plan-bundle     → dartclaw-spec-plan skill / dartclaw-exec-plan skill
  fis-bundle      → dartclaw-exec-spec skill / dartclaw-review skill
  *-review        → dartclaw-remediate-findings skill
  triage-plan     → dartclaw-exec-spec skill (triage)
  triage-completion → (informational, no action)
  other           → stop with redirect
Untyped input: [accept as requirements / stop and require typed artifact]
```

Skills customize this table to their contract -- only list the routes relevant to that skill.
