# DartClaw – Product Summary

## Vision

**DartClaw** is an experimental, security-conscious AI agent runtime built with Dart. It brings a personal assistant, persistent knowledge, and automated work together in a self-hosted system under one owner's control.

## Core Philosophy

**Pragmatic, efficient, lean, lightweight, adaptable, and approachable.** These product requirements guide features, architecture, dependencies, and user experience.

- **Solve the real problem simply.** Choose the smallest solution that meets the need. Avoid over-engineering, speculative features, and unnecessary layers or configuration knobs. Cut scope before adding complexity; fix root causes instead of adding workarounds.
- **Keep it lean and efficient.** Use few, justified dependencies. Minimize runtime overhead and unnecessary model calls; bound concurrency and model spending. Measure before adding performance machinery.
- **Make setup and daily use straightforward.** Require little initial configuration, provide sensible defaults and actionable errors, and make permissions and operating state understandable. Keep the code easy to extend.
- **Build security into the system.** Prefer OS-enforced isolation where supported, least privilege, scoped credentials, and auditable actions. Guards add enforcement where the provider permits it. Make weaker execution modes explicit: isolation and guard coverage depend on the provider, environment, and configuration.
- **Build on each harness's strengths.** Use each harness's native protocols, tools, and skill conventions. Reuse their capabilities instead of rebuilding them in DartClaw.
- **Delegate judgment; keep enforcement deterministic.** Models interpret content through declared schema or tool contracts. The host validates once and fails closed on invalid output, without repairing or inventing answers. Security decisions, resource limits, persistence invariants, protocols, channel formatting, and stop controls remain deterministic.
- **Keep one authority per concern.** Extend the existing owner of a concern instead of adding competing parsers, validators, schemas, or policies. Keep ownership explicit and the codebase small enough to inspect.

[ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) defines the model/host boundary and validation exemption. Keep the architecture auditable through dependency checks, prompt-surface tracking, and per-package size ceilings. Justified ceiling increases follow [ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md).

## Product Scope

- **Personal assistant:** conversations through the web UI and messaging channels, web research, memory across sessions, and scheduled jobs.
- **Automated work:** background tasks, code changes, and validated workflows. Runtime composition of declarative, schema-validated workflow definitions by agents is planned.
- **Inspectable knowledge:** memory, a wiki, and a temporal knowledge graph, with read-only access for trusted clients over MCP. A broader knowledge steward loop is planned.

**Single-owner, multi-client.** One person administers the assistant through the main conversation, which has access to everything. Channel-bound agents connect to workspaces of their own, with narrower tools, and reach the owner's knowledge through the context engine. Other people use the assistant through those agents, or as read clients of the knowledge surface in a context-engine deployment; such a deployment serves many clients plus automated work such as repository maintenance rather than doubling as a personal assistant. Nobody but the administrator owns configuration or writes. Multi-tenant deployment, per-sender chat arbitration, and team/crowd features are out of scope; trusted group-chat use remains a recipe.

## Architecture

An AOT-compiled Dart host owns state, APIs, security enforcement, and execution coordination. It drives Claude Code, Codex, and ACP agents through provider-specific adapters. DartClaw itself requires no npm or Node.js runtime; external harnesses and optional integrations have their own prerequisites.

## Development Stage

DartClaw remains early, experimental software. Breaking changes to APIs, configuration, protocols, and storage are acceptable. Correctness, security, and simple design take priority over backward compatibility.

## Proportionality

- **Stage:** prototype. Experimental, soft-published; breaking changes to APIs, configuration, protocols and storage are acceptable.
- **Scale:** one owner per instance and a handful of instances in use (personal deployments plus development); one process on one host; SQLite per instance with data in the megabytes; one maintainer.
- **Standing technical non-goals:** multi-tenant or multi-user administration; horizontal scaling or a distributed runtime; isolates or worker pools without a profiled bottleneck; an ORM or a second storage authority beside the existing backends; a plugin or extension system beyond harness providers, skills and workflow definitions; backward-compatibility layers.
