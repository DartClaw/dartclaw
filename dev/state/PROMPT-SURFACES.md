# Prompt Surfaces

Every **host-authored, model-facing prompt surface** in DartClaw: text this repository authors and sends to a model. One row per surface, naming where the text is authored, what the model is asked to produce, the output contract it must satisfy, and the host component that validates or consumes the result.

Read this before adding a prompt, a schema over model output, or a parser of a model reply. The inventory is what makes a surface checkable: a surface that is not here is either new (add it) or ungoverned (fix it). A new surface whose output contract duplicates an existing one is the *second implementation of an existing seam* defect class – extend the existing contract instead.

**Scope**: Dart authoring sites under `packages/*/lib` and `apps/*/lib`, the bundled workflow definitions, and the bundled skill payloads. Excluded: test fakes, externally supplied MCP tool descriptions (not host-authored), and strings that never reach a model.

**Granularity** – one row per **turn-authoring site**: the code that composes the body of a turn sent to a model, or the payload a step dispatches. Values interpolated into another surface's prompt at composition time (goal blocks, review-scoring fragments, schema-preset descriptions) get no row of their own; they are named in the row of the surface that carries them. That makes turn coverage mechanically testable: every turn dispatched to a model traces to exactly one turn-authoring row.

A file whose sole export is model-facing instruction text, read verbatim by a composer – the seed behaviour files, the conversation-history frame – also gets a row, because folding it into the composing row would hide the file that actually holds the words. Such a row's contract column reads `free text` and its consuming component names the composer. Turn coverage does not prove this second class complete; adding a file of that shape without a row here is a gap the turn sweep will not catch.

**Contract vocabulary**: `tool call` (the model invokes a registered tool), `declared schema` (a JSON shape the host validates), `enum` (a closed value set the host enforces), `structured envelope` (provider-enforced structured output or a marker-delimited payload), `free text` (no host-enforced machine contract – including a contract stated only in prose).

Binding rules for these surfaces: [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) (model-first delegation; one authority per concern) and [ADR-031](../adrs/031-native-first-structured-outputs.md) (native-first structured outputs).

<!-- Maintenance: keep this current in the same change that adds, removes or
     re-contracts a prompt surface – the same currency discipline as the
     per-package AGENTS.md files. A surface with an unnamed output contract or
     an unnamed validating component is a defect, not a blank cell. -->

## `dartclaw_core`

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_core/lib/src/harness/conversation_history.dart` | Nothing directly – frames prior turns as `<conversation_history>` context with two instruction sentences, prepended to the turn by `claude_code_harness.dart` and `acp_harness.dart` | `free text` (context framing; input only, no return contract) | `claude_code_harness.dart` and `acp_harness.dart` compose it into the turn; the budget and truncation rules in the same file are host-owned |
| `packages/dartclaw_kernel/lib/src/output_schema.dart#renderOutputSchemaContract` (appended to the persona by `packages/dartclaw_kernel/lib/src/agent_definition.dart#AgentDefinition.personaPrompt`, dispatched from `packages/dartclaw_runtime/lib/src/runtime/harness_wiring.dart`) | For a logical agent declaring `agent.agents.<id>.output_schema`: exactly one JSON value conforming to the rendered, deep-closed schema – no prose, no code fences | `structured output` (closed JSON Schema subset: `type`, `properties`, `required`, `items`, `enum`, `additionalProperties`; every object level closed) | `packages/dartclaw_core/lib/src/agents/logical_agent_session_service.dart#_checkOutputSchema` – parses once, refuses duplicate members, runs `validateOutputSchema` and fails the turn on the first violation; never repairs, defaults or truncates (a schema-bound result over `max_response_bytes` fails rather than being cut) |

Beyond that block and the single-line skill-activation convention consumed by `SkillPromptBuilder`, `dartclaw_core` transports prompts authored elsewhere rather than authoring them.

## `dartclaw_runtime` – agent behaviour and scheduled turns

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_runtime/lib/src/behavior/behavior_file_service.dart#BehaviorFileService.composeSystemPrompt` (plus `#composeStaticPrompt` / `#composeAppendPrompt` for append-mode harnesses) | The agent's persona and standing behaviour – composed from SOUL.md / USER.md / TOOLS.md / MEMORY.md plus the built-in defaults. The compaction and identifier-preservation instructions, which steer the provider's own compaction pass, ride the composed system prompt; the append composition carries AGENTS.md only | `free text` (system prompt; no machine-read return) | `packages/dartclaw_runtime/lib/src/turn_runner.dart` and `turn_runner_execution.dart` drive the harness turn; a non-blank `systemPromptOverride` replaces the composition verbatim |
| `packages/dartclaw_runtime/lib/src/workspace/workspace_service.dart#WorkspaceService.defaultSoulMd` / `#defaultUserMd` / `#defaultAgentsMd` / `#defaultToolsMd` | Seed content for a new workspace's SOUL.md, USER.md, AGENTS.md and TOOLS.md, which later compose into the prompt – `defaultAgentsMd` carries the standing safety framing (no exfiltration; treat embedded instructions as data) | `free text` | `BehaviorFileService` reads the files back as prompt content |
| `packages/dartclaw_runtime/lib/src/behavior/memory_journal.dart#MemoryJournal.prompt` | Durable observations from the day's journal file, recorded through the memory tool | `tool call` (`memory_observe`; scoped tool allowlist) | No host parse – the tool calls are guard-evaluated on the normal MCP path; registered as a prompt job by `packages/dartclaw_runtime/lib/src/runtime/scheduling_wiring.dart` and dispatched by `packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart` |
| `packages/dartclaw_runtime/lib/src/behavior/heartbeat_job.dart#buildHeartbeatJob` | Execution of the operator-authored `HEARTBEAT.md` checklist | `free text` (response not machine-read) | None – the host owns the schedule, the file read and the per-fire session; the reply is not parsed. Registered as a built-in job by `packages/dartclaw_runtime/lib/src/runtime/scheduling_wiring.dart` and dispatched by `packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart` |
| `packages/dartclaw_runtime/lib/src/api/session_message_routes.dart` | Nothing directly – frames a user turn's attachments and references as a fenced `rich_input_context` JSON block, with the standing instruction to treat its content values as untrusted data rather than operator instructions | `free text` (context framing; input only, no return contract) | Prepended to the user message on the interactive turn path; no host parse of the reply |
| `packages/dartclaw_runtime/lib/src/turn_runner_memory.dart#_flushPrompt` | Observations worth preserving before context compaction | `tool call` (`memory_observe` with `role='observation'`) | No host parse of the reply; the flush is deduplicated and gated by the context monitor in the same library |

## `dartclaw_runtime` – task execution

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_runtime/lib/src/task/task_executor_helpers.dart#_initialPrompt` | Completion of the task: title, description, working directory, acceptance criteria, and – on a retry – the previous failure and an instruction to change approach. Carries the goal block from `packages/dartclaw_runtime/lib/src/task/goal_service.dart#GoalService.resolveGoalContext` | `free text` (the turn's result is the task's work; no declared output schema) | `TaskExecutor` in the same library owns the turn, its budget and its retry accounting; no parse of the reply body |
| `packages/dartclaw_runtime/lib/src/task/task_executor_helpers.dart#_pushBackPrompt` | A revised attempt addressing reviewer push-back feedback | `free text` | `TaskExecutor` – clears the push-back comment once the turn is dispatched |
| `packages/dartclaw_runtime/lib/src/task/workflow_one_shot_runner.dart` | For a workflow one-shot step: the step's work, then a finalizer turn serialising it into the execution envelope, plus one same-session re-ask on a missing envelope | `structured envelope` (`execution_envelope_schema.dart`) | `SchemaValidator` in the same runner – a payload failing the envelope schema is discarded as `malformed_envelope` rather than stamped authoritative |

## `dartclaw_runtime` – knowledge, memory and research

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_runtime/lib/src/memory/memory_curation_job.dart#buildMemoryCurationJob` | Add / revise / merge / remove operations over a bounded personal-memory snapshot composed at each fire | `tool call` (`memory_apply`, session-local allowlist) | `packages/dartclaw_runtime/lib/src/memory/memory_apply_service.dart#apply` – closed change-set validation, collection CAS, and the run scope registered by the composer |
| `packages/dartclaw_runtime/lib/src/knowledge/knowledge_inbox_service.dart#KnowledgeInboxService` | Durable knowledge extracted from an inbox source: memory findings, a wiki page, and facts | `structured envelope` (marker-delimited JSON object) | `#KnowledgeExtraction.fromAssistantText` |
| `packages/dartclaw_runtime/lib/src/mcp/context_research_tool.dart#ContextResearchTool.logicalAgentSynthesizer` | A compact citation packet synthesised from retrieval candidates | `free text` with a JSON shape declared only in prose (`statements` / `sourceRefs` / `sourceList` / `degradedLayers` / `noSourcesFound`); no schema reaches the turn | `#_packetFromSynthesis` – on a decode failure it substitutes a host-built packet from the retrieval candidates rather than failing the call |

## `dartclaw_runtime` – internal MCP tool definitions

Each tool's `name`, `description` and `inputSchema` are model-facing prompt surface: they are what the model reads to decide whether and how to call the tool. One row per definition file.

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_runtime/lib/src/mcp/memory_tools.dart` | Memory observations, applies, searches and reads | `tool call` (per-tool `inputSchema`) | Each tool's `call()` plus the guard chain; `MemoryApplyService` / `MemoryCorpusService` own the invariants |
| `packages/dartclaw_runtime/lib/src/mcp/kg_tools.dart` | Knowledge-graph additions, queries, timelines, invalidations and contradiction checks | `tool call` (per-tool `inputSchema`) | Each tool's `call()` plus the guard chain; the temporal knowledge-graph service |
| `packages/dartclaw_runtime/lib/src/mcp/sessions_spawn_tool.dart` | A logical-agent spawn request naming a configured agent id | `tool call` (`inputSchema` with a configured-agent `enum`) | The logical-agent session service's spawn handler |
| `packages/dartclaw_runtime/lib/src/mcp/sessions_send_tool.dart` | A message to an existing logical-agent session | `tool call` (`inputSchema`) | The logical-agent session service's send handler |
| `packages/dartclaw_runtime/lib/src/mcp/task_tools.dart` | Task creation, listing, review decisions and thread bindings | `tool call` (per-tool closed `inputSchema`; `TaskStatus`/`ChannelType`/review-action `enum`s, full task IDs only) | Each tool's own schema-driven validation pass plus the guard chain; `TaskService` / `TaskReviewService` / `ThreadBindingStore` own the invariants |
| `packages/dartclaw_runtime/lib/src/mcp/web_fetch_tool.dart` | A URL fetch request | `tool call` (`inputSchema`) | The tool's own `call()`; fetched content is classified through `packages/dartclaw_kernel/lib/src/content_scan.dart`, and only the scanned span is returned |
| `packages/dartclaw_runtime/lib/src/mcp/search_mcp_tool.dart` (+ `brave_search_tool.dart`, `tavily_search_tool.dart`) | A web-search query | `tool call` (`inputSchema`) | The configured search provider; results classified by `content_guard.dart` over the shared `content_scan.dart` authority |
| `packages/dartclaw_runtime/lib/src/mcp/context_research_tool.dart` | A context-research request (query, scope, token budget) | `tool call` (`inputSchema`) | The tool's own `call()`; see its synthesis surface above |
| `packages/dartclaw_runtime/lib/src/mcp/onboarding_complete_tool.dart` | The signal that onboarding is finished | `tool call` (`inputSchema`) | `OnboardingCompleteTool` – removes the onboarding sentinel |

## `dartclaw_kernel` and `apps/dartclaw_cli`

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_kernel/lib/src/agent_definition.dart#AgentDefinition._defaultSearchPrompt` | The built-in `search` logical agent's standing behaviour (default agent prompt) | `free text` | The logical-agent session service, via the harness turn's system prompt |
| `apps/dartclaw_cli/lib/src/commands/init/setup_apply.dart#SetupApply` | The generated `ONBOARDING.md`: a conversational onboarding pass that populates SOUL.md and USER.md, then signals completion | `tool call` (`onboarding_complete`) plus `free text` conversation | `packages/dartclaw_runtime/lib/src/mcp/onboarding_complete_tool.dart#OnboardingCompleteTool` removes the sentinel; `SetupApply` itself string-matches the generated file to decide whether an existing onboarding document is its own and may be upgraded |

## `dartclaw_kernel`

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_kernel/lib/src/anthropic_api_classifier.dart#AnthropicApiClassifier.classificationPrompt` | A safety category for fetched or inbound content, over the Anthropic Messages API | `enum` (`validCategories`: `safe` / `prompt_injection` / `harmful_content` / `exfiltration_attempt`); an unrecognised label fails closed to `harmful_content` | `packages/dartclaw_kernel/lib/src/content_guard.dart#ContentGuard`, through the `ContentClassifier` contract in `content_classifier.dart` |
| `packages/dartclaw_kernel/lib/src/claude_binary_classifier.dart#ClaudeBinaryClassifier.classify` | The same safety category – this is the **default** classifier, re-sending `AnthropicApiClassifier.classificationPrompt` over `claude --print` | `enum` (`AnthropicApiClassifier.validCategories`), with its own fail-closed default to `harmful_content` | `ContentGuard`, through `ContentClassifier`. The enum is one authority (`validCategories`); the fail-closed default is implemented separately in each classifier |

## `dartclaw_workflow` – engine-composed prompts

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_workflow/lib/src/workflow/skill_prompt_builder.dart#SkillPromptBuilder` | The effective step prompt: skill activation, resolved step prompt, and framed inputs and variables | `free text` body whose contract tail is delegated to `PromptAugmenter` | `packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart` dispatches the built prompt; `map_iteration_runner.dart` builds and dispatches the per-iteration variant |
| `packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart#PromptAugmenter` | The step's declared outputs and step outcome, in the required output format. **Every declared output key is named with its authored `description:` in a `## Declared Outputs` section, finalizer-covered keys included — what a key means is the step turn's contract, while how the values leave the turn is the finalizer's, so the emission protocol and the envelope example are absent for a covered key.** Carries the severity taxonomy and gating-count rule from `review_scoring_fragment.dart` for review-scoring presets, and the per-key descriptions from `schema_presets.dart` | `structured envelope` (`execution_envelope_schema.dart`) plus a per-key `declared schema` from `schema_presets.dart` | `packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart` extracts; `output_normalization.dart` and `schema_validator.dart` validate |
| `packages/dartclaw_workflow/lib/src/workflow/execution_envelope_schema.dart#buildFinalizerPrompt` | The finalizer turn: serialise the completed step's work into the envelope, JSON only, no tools. Renders each declared output key with its description | `structured envelope` (the persisted envelope schema) | `schema_validator.dart`; the one-shot runner discards a non-conforming payload rather than accepting it |
| `packages/dartclaw_workflow/lib/src/workflow/step_dispatcher.dart#_withWorkflowRetryFeedback` | A corrected retry of the step, prefaced with the host's account of the previous attempt's failure | `free text` prefix; the step's own declared contract is unchanged | The step's normal extraction and validation path |
| `packages/dartclaw_workflow/lib/src/workflow/merge_resolve_coordinator.dart` | Semantic resolution of merge conflicts, plus the outcome, conflicted files, resolution summary and error message. Authors both the step prompt and the four output descriptions | `structured envelope` step outcome; the four outputs are `text`/`json` formatted with the outcome vocabulary declared in prose, not as a schema `enum` | The coordinator itself – it owns sha capture, cleanliness, locking, bounded attempts, audit and escalation, and treats an absent outcome as a failed attempt |
| `packages/dartclaw_workflow/lib/src/workflow/skill_introspector.dart#skillIntrospectionPrompt` | A list of the provider's available skill names, one per line | `free text` with a host-parsed line contract (no declared schema) | `packages/dartclaw_workflow/lib/src/skills/cli_skill_introspector.dart` parses the reply into a name set; `packages/dartclaw_workflow/lib/src/workflow/workflow_skill_preflight.dart` checks it against the definition's skill references and raises `WorkflowPreflightException` on a miss |
| `packages/dartclaw_workflow/lib/src/workflow/built_in_workflow_workspace.dart#builtInWorkflowAgentsMd` | Workspace-level behaviour for a built-in workflow run: do only the assigned step, follow its output contract | `free text` (behavioural framing; no output schema) | Written into the workflow workspace by `workflow_executor_helpers.dart`; read by the harness as project instructions |

## `dartclaw_workflow` – bundled workflow definitions

Each agent step's `prompt:` is host-authored text, augmented by `PromptAugmenter` with the step's declared `outputs:` before dispatch. Extraction and validation for all three definitions run through `context_extractor.dart`, `output_normalization.dart` and `schema_validator.dart`; path-shaped outputs additionally pass the generic `format: path` containment check (ADR-041).

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_workflow/lib/src/workflow/definitions/spec-and-implement.yaml` | Per step: spec-input classification, a spec, an implementation, a simplification pass, and a review | `declared schema` per step's `outputs:`, carried in the `structured envelope` | `context_extractor.dart` + `schema_validator.dart`; review artifacts are captured host-side by `review_artifact_policy.dart` |
| `packages/dartclaw_workflow/lib/src/workflow/definitions/plan-and-implement.yaml` | Per step: plan-state discovery, a plan, and per-story spec revision, implementation, simplification and review | `declared schema` per step's `outputs:`, carried in the `structured envelope` | `context_extractor.dart` + `schema_validator.dart`; `story_specs` additionally passes `story_spec_output_validator.dart` and `story_specs_contract_validator.dart`; review artifacts captured by `review_artifact_policy.dart` |
| `packages/dartclaw_workflow/lib/src/workflow/definitions/code-review.yaml` | A code review of the target, then bounded remediation and re-review | `declared schema`: `review_report_path` plus the step-id-prefixed `review-code.findings_count` / `review-code.gating_findings_count` and `re-review.findings_count` / `re-review.gating_findings_count` (the loop gates read those prefixed names literally), and `remediation_summary` on the remediation step | `context_extractor.dart` + `schema_validator.dart`; review artifacts captured by `review_artifact_policy.dart` |

## `dartclaw_workflow` – bundled skill payloads

| Surface | Model is asked to produce | Output contract | Validating / consuming component |
|---------|---------------------------|-----------------|----------------------------------|
| `packages/dartclaw_workflow/skills/dartclaw-discover-andthen-plan/SKILL.md` | Read-only discovery of the plan bundle's state, emitted as flat outputs | `structured envelope` | `context_extractor.dart`; declared `schema:` and `format: path` only – no framework-specific re-validation (ADR-041) |
| `packages/dartclaw_workflow/skills/dartclaw-discover-andthen-spec/SKILL.md` | A classification of the feature input as an existing spec path or text needing synthesis | `structured envelope` | `context_extractor.dart`; declared `schema:` and `format: path` only |
| `packages/dartclaw_workflow/skills/dartclaw-merge-resolve/SKILL.md` | The resolution procedure and its terminal outcome, committed all-or-nothing | `structured envelope` step outcome; the outcome vocabulary is declared in prose by the coordinator's output description, not enforced as a schema `enum` | `merge_resolve_coordinator.dart` – see its row above |
| `packages/dartclaw_workflow/skills/dartclaw-validate-workflow/SKILL.md` | Execution of the workflow-validate CLI command and a reading of its output | `free text` (operator-facing; no host parse) | None – the CLI's own exit code and diagnostics are the contract |

## Packages with no model-facing prompt surface

`dartclaw` (umbrella re-exports), `dartclaw_kernel`, `dartclaw_bridge`, `dartclaw_signal`, `dartclaw_google_chat`, `dartclaw_whatsapp`, `dartclaw_testing`.
