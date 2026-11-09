# DartClaw – Product Summary

## Vision

**DartClaw** is an experimental, security-conscious AI agent runtime built with Dart. It brings a personal assistant, a team assistant, persistent knowledge, and automated work together in a self-hosted system under one administrator's control.

## Core Philosophy

**Pragmatic, efficient, lean, lightweight, adaptable, and approachable.** They guide features, architecture, dependencies, and user experience.

- **Solve the real problem simply.** Choose the smallest solution that meets the need. Avoid over-engineering, speculative features, and unnecessary layers or configuration knobs. Cut scope before adding complexity; fix root causes instead of adding workarounds.
- **Keep it lean and efficient.** Use few, justified dependencies. Minimize runtime overhead and unnecessary model calls; bound concurrency and model spending. Measure before adding performance machinery.
- **Make setup and daily use straightforward.** Require little initial configuration, provide sensible defaults and actionable errors, and make permissions and operating state understandable.
- **Build security into the system.** Prefer OS-enforced isolation where supported, least privilege, scoped credentials, and auditable actions. Guards add enforcement where the provider permits. Make weaker execution modes explicit, since coverage depends on provider, environment, and configuration.
- **Build on each harness's strengths.** Use each harness's native protocols, tools, and skill conventions. Reuse their capabilities instead of rebuilding them in DartClaw.
- **Delegate judgment; keep enforcement deterministic.** Models interpret content through declared schema or tool contracts. The host validates once and fails closed on invalid output, without repairing or inventing answers. Security decisions, resource limits, persistence invariants, protocols, channel formatting, and stop controls remain deterministic.
- **Keep one authority per concern.** Extend the existing owner of a concern instead of adding competing parsers, validators, schemas, or policies. Keep ownership explicit and the codebase small enough to inspect.

[ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) defines the model/host boundary and validation exemption. Dependency checks, prompt-surface tracking and per-package size ceilings ([ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md)) keep the architecture auditable.

## Product Scope

One runtime serves several use cases, alone or combined:

- **Personal assistant:** conversations through the web UI and messaging channels, web research, memory across sessions, and scheduled jobs.
- **Automated work:** background tasks, code changes, and validated workflows. Agent-composed, schema-validated workflow definitions are planned.
- **Inspectable knowledge:** memory, a wiki, and a temporal knowledge graph, with read-only access for trusted clients over MCP. A broader knowledge steward loop is planned.
- **Team assistant:** one shared session per thread in allowlisted Slack and Google Chat channels, chat-started workflow runs, and shared knowledge via the context engine. Knowledge visibility per channel or MCP client is planned.

**One administrator, many users.** One person administers the instance through the main conversation and alone owns configuration. Named agents are narrower execution identities of that assistant, not additional users or personas: each has a host-managed workspace and private personal-memory principal. Explicit publication puts accepted knowledge into the shared wiki or temporal graph; `context_research` combines a caller's own private memory with those shared sources and never another agent's memory or raw inbox inputs. Other people use it through channel-bound agents, team channels, or read-only access to the shared knowledge surface.

## Architecture

An AOT-compiled Dart host owns state, APIs, security enforcement, and execution coordination. It drives Claude Code, Codex, and ACP agents through provider-specific adapters. The server uses PostgreSQL; standalone workflows need only local files. DartClaw itself requires no npm or Node.js runtime; external harnesses and optional integrations have their own prerequisites.

## Non-Goals

<!-- Firmly rejected concepts, one bullet each: the concept, why, the date, where it was requested. Match a new request
     on the concept, not the wording. Built is not rejected: a request closed as already-implemented gets no bullet. -->

- **Splitting out or deleting the workflow engine** (an optional add-on, a second product, or removal): workflows are core, the substrate DartClaw's agents compose dynamic workflows on. A workflow-only distribution binary of the one runtime is not a split. 2026-08-16, 0.25 scoping (package-review proposal, withdrawn by the owner).
- **Deleting the ACP harness:** ACP stays the third harness family, isolated in `dartclaw_acp`; its fail-closed admission (2026-08-12) and credential isolation ([ADR-037](../adrs/037-universal-acp-harness.md) amendment, 2026-08-17) are deliberate. 2026-08-18, 0.25 scoping Q7.
- **Degrading the CLI surface:** the resource command families (`jobs`, `projects`, `runners`, `sessions`, `tasks`, `traces`, `config`), `service install` (with `--system`) and `init` stay. Internal simplification is fine, capability removal is not. 2026-08-18, 0.25 scoping Q5 and Q6.
- **A curated or read-only settings UI:** the web UI keeps full per-field configuration coverage from the generated schema. Reload breadth may be cut, coverage may not. 2026-08-16, 0.25 scoping Q4.
- **Multi-tenant deployment, multiple administrators, per-sender chat arbitration:** one administrator owns configuration and the chat identity, and crowd coding stays an opt-in, maintenance-mode capability. 2026-08-16, 0.25 scoping Q3. Narrowed 2026-10-04 by the owner: team use through shared thread sessions, chat-started workflow runs and shared knowledge is in scope.

## Proportionality

- **Stage:** prototype. Experimental, soft-published; breaking changes are acceptable, because correctness, security, and simple design come before backward compatibility.
- **Scale:** one administrator per instance, used alone or by a small team; a handful of instances in use (personal deployments plus development); one process on one host; server PostgreSQL or standalone execution files with data in the megabytes; one maintainer.
- **Standing technical non-goals:** multi-tenant or multi-user administration; horizontal scaling or a distributed runtime; isolates or worker pools without a profiled bottleneck; an ORM or a second storage authority beside the existing backends; a plugin or extension system beyond harness providers, skills and workflow definitions; backward-compatibility layers; full accessibility conformance — keyboard reach, focus order, labels and touch targets are held, but a gate is not blocked on an audit finding no measurement reproduces.
