# ADR-021 Research Appendix: AgentExecution Primitive

> Frozen synthesis supporting [ADR-021](../021-agent-execution-primitive.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
What runtime primitive should represent executing an agent task?

## Options considered
- Keep execution embedded in workflow code — less structure, but poor reuse and observability.
- Introduce AgentExecution — centralizes lifecycle, policy, logs, and result handling.
- Push execution to harness implementations — hides cross-harness policy and audit behavior.

## Trade-off summary
A first-class execution primitive increases runtime structure, but makes task policy, status, and evidence reusable across workflows.

## Deciding evidence
The decomposition research found repeated execution responsibilities spread across harness, task, and workflow code.

## Sources (private)
- `docs/research/agent-execution-decomposition/research.md`
