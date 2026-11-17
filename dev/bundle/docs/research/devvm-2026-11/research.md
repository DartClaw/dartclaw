# devvm – Ideas for DartClaw (2026-11)

**Date**: 2026-11-07 · **Status**: Reference
**Purpose**: Decide which devvm mechanisms DartClaw should adopt, adapt or skip.
**Evidence**: [inventory.md](inventory.md) – sourced inventory of devvm.dev, its GitHub repo, the Syntax video and the
HN thread (accessed 2026-11-07), cited as `inv §N`. devvm is one day old (0.1.0, 2026-11-06), so its docs are design
statements, not field-tested behavior. DartClaw facts were checked against public HEAD `51a4af131` (0.28.0).
**Feeds**: V1–V5 promoted to 0.28.1 on 2026-11-10 with defaults D1–D4 ([ROADMAP § Active Milestone](../../ROADMAP.md#active-milestone));
V1 as public [ADR-062](../../../../dartclaw-public/dev/adrs/062-read-only-package-registry-egress-for-containers.md)
(Proposed). §5 assesses Docker Sandboxes (`sbx`).

---

## 1. What devvm is

A free, MIT-licensed Go CLI by CJ (Coding Garden): `devvm` in a project folder starts a Lima VM (Apple Virtualization
on macOS, QEMU/KVM on Linux) with the project's toolchain detected from its files, and the developer or a coding agent
(Claude Code, Codex, opencode) works inside it (inv §1, §2). The pitch, from the Syntax video, is that developer
machines are prime targets for credential theft, existing sandboxes are clunky, and this one is a single command
(V 00:00–00:22). Its three mechanisms:

1. **Egress through a host proxy, allowlist by default.** Blocked requests get a 403 that names the host and the rule
   that would allow it; the VM can ask `devvm-why` (inv §3).
2. **Credentials stay on the host.** The VM holds placeholders; the proxy swaps in real values per secret host via a
   per-VM CA. Agent logins happen in the VM but are stored on the host (inv §4).
3. **Fast, toolchain-ready VMs.** Base image once, ~5 s per VM after, shared read-only toolchain images, optional
   clone mode that keeps the host checkout untouched until `git fetch devvm` (inv §2).

devvm is a developer-workstation sandbox: one VM per folder, a human at the shell. DartClaw is a runtime that drives
agents unattended. The overlap is the containment of a coding agent, not the product.

## 2. DartClaw already has the stronger form of devvm's core

| devvm mechanism | DartClaw today | Gap? |
|---|---|---|
| Credentials on host, placeholder in the VM, MITM proxy injects per host (inv §4) | Host-owned provider mediation: no credential, CA or network in the container; the bridge pipe fixes principal, upstream and paths (public `dev/architecture/security-architecture.md` § Host-Owned Provider Mediation) | No – DartClaw is stricter: no CA to trust, no SNI to front (devvm's own residual, inv §5), no undocumented login capture |
| Git credentials never in the VM; proxy blocks key-minting GitHub calls (inv §4) | Clone, fetch and push run on the host with per-command credential plans (§ Git Credentials) | No |
| Allowlist egress by default (inv §3) | `network:none`; web only through host-side `web_search`/`web_fetch` under NetworkGuard (public `docs/guide/security.md:744-749`) | **Different – V1**: DartClaw has no egress for package installs |
| Toolchain detected and mounted per project (inv §2) | One image, `debian:bookworm-slim` + `curl`, `git`, `claude`, `codex` (public `docker/Dockerfile`); `container.image` swaps it | **Yes – V2** |
| Lists `.claude/settings.json`, `.mcp.json`, `CLAUDE.md`, husky hooks, `.envrc` as host-exploitable writes (inv §5) | Nothing in `packages/*/lib` names these paths; `auto-accept` and `tasks.completion_action: accept` merge without a human (public `dev/architecture/task-execution-architecture.md` § 6.4) | **Yes – V3** |
| 403 names the rule that would allow the host (inv §3) | NetworkGuard says `domain not in allowlist ($host)` and stops (public `packages/dartclaw_kernel/lib/src/network_guard.dart:214`) | Small – V4 |
| `rm` offers to save unfetched commits as `saved/devvm/<branch>` (inv §6) | Task `cancel` removes the worktree; `cleanup` deletes worktree and branch, best-effort (§ 5.1, § 3) | Small – V5 |
| Rules never read from the project folder; strict config parsing (inv §3, §6) | Admin-owned `dartclaw.yaml`, fail-closed config load (ADR-059) | No – independent convergence |
| Per-launch confinement self-check, `unenforced` status (inv §3) | Startup posture probe (ADR-055); Docker flags are deterministic | Not taken (§4) |

## 3. Ideas

### V1 – Package-registry egress over the host gateway (P1, owner decision)

**Problem.** A containerized coding task cannot `npm install`, `dart pub get` or `pip install`: `network:none` is the
only network posture and the bridge pipe carries provider traffic and the canonical web tools only. Every workflow that
verifies with "the project's documented format, analyze and test commands" (merge-resolve, public
`dev/architecture/workflow-architecture.md:544`) therefore depends on dependencies already being present in the mounted
checkout *(inferred: not reproduced in a run)*. devvm's whole value proposition is that a sandboxed agent can still
install and test; its author concedes the allowlist costs friction (V 12:32) and HN's sharpest criticism is "the more
you restrict the agents, the less useful they become" (inv §7). DartClaw's container mode has that problem in its
strongest form.

**Proposal.** A third bridge surface, `registry`, beside `provider` and `mcp`: an HTTP(S) forward proxy inside the
container that tunnels over the existing per-authority pipe to a host-side handler. The host admits only `GET`/`HEAD`
to hosts on NetworkGuard's package-registry subset (already in the default allowlist: `registry.npmjs.org`, `pypi.org`,
`pub.dev`, `crates.io`, `rubygems.org`), carries no credential, and logs each request as an audit event. Container keeps
`network:none`; no network attachment or published port is added.

**Where DartClaw can beat devvm.** devvm's documented holes are upload-capable allowed hosts (GitHub push, npm
publish) and SNI-only host checks (inv §5). A pipe surface that terminates on the host can refuse non-read methods and
check the actual request host, because the handler, not a TLS-transparent proxy, makes the upstream call. Whether
that means a host-side CA (TLS termination) or CONNECT-only with SNI checks is the main design question; the latter
inherits devvm's fronting weakness.

**Cost.** Amends ADR-015/055's "sole egress" statement and the security guide; needs an ADR. Moderate code in
`container/gateway/` (new adapter) and the bridge binary. Off by default or per-profile (`workspace` only, never
`restricted`) is an owner call.

### V2 – Project toolchain in the agent image (P1, pairs with V1)

**Problem.** The image ships no language toolchain (public `docker/Dockerfile`), so even with dependencies vendored a
containerized agent cannot run `dart test` or `npm test`. `container.image` exists, but the guide gives no recipe for
extending `dartclaw-agent` *(inferred from a grep of `docs/guide/` for `FROM dartclaw-agent`, toolchain and install
terms: no hits)*.

**Proposal, leanest first.** (a) Document a `FROM dartclaw-agent:latest` extension recipe with a Dart and a Node
example, and note that `container.image` takes it. (b) `dartclaw doctor` (or the task executor) reports when a
project's documented test command's binary is missing in the configured image, naming the fix. devvm's
detect-from-project-files plus shared read-only toolchain images (inv §2) is the full version; it is more machinery
than DartClaw's scale justifies and is not proposed.

### V3 – Flag agent-written execution-surface files before accept (P1, security)

**Problem.** devvm's attack-vectors page lists files that turn a sandboxed write into host code execution later:
`.claude/settings.json` (hooks), `.mcp.json` (server commands), `CLAUDE.md`/`AGENTS.md` (instructions), `.husky/`,
`.envrc`, `.vscode` tasks, `mise.toml`, symlinks (inv §5). The same path exists in DartClaw: a containerized agent
writes `.claude/settings.json` with a hook into its worktree; `auto-accept`, `tasks.completion_action: accept` or
workflow promotion merges it with no human in the loop; the next **host-mode** Claude spawn in that project loads
project settings (`--setting-sources project`, or all sources when user settings are inherited; public
`packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:64,682`) and runs the hook outside any container. The
operator's own editor and CLI in that repo are exposed the same way. The container boundary is intact; the merge is
the escape.

**Proposal.** A fixed path list in one place (the diff classifier), checked against every accept and promotion diff:
`.claude/**`, `.mcp.json`, `.codex/**`, `CLAUDE.md`, `AGENTS.md`, `.husky/**`, `.githooks/**`, `.github/workflows/**`,
`.envrc`, `.vscode/tasks.json`, `.vscode/settings.json`, `mise.toml`, plus any added symlink. A hit turns an automatic
accept or promotion into `review` with the paths named, and the review UI badges them. Deterministic (ADR-054 keeps
security decisions in the host), no config knob in the first cut. The `.github/workflows` entry also covers the
push-to-remote route.

**Open question.** Whether `CLAUDE.md`/`AGENTS.md` belong on the list: they are instructions, not code, and agents
legitimately update them. Including them makes auto-accept rarer in repos where agents maintain docs.

### V4 – Blocked-host message names the fix (P2, small)

NetworkGuard's block reason is `Network blocked: domain not in allowlist ($host)`. devvm's 403 also says which rule
would allow the host, and the agent can relay it (inv §3, V 02:50). Append the config key
(`guards.network.extra_allowed_domains`, or `agent_overrides.<id>.extra_domains` when the context has an agent id) so
the model's reply to the operator carries the fix. One string in `network_guard.dart` plus its test; a Boy Scout-sized
public-repo change.

### V5 – Keep unmerged task commits on cancel (P3, verify first)

devvm's `rm` refuses to silently drop unfetched clone commits and offers `saved/devvm/<branch>` (inv §6). DartClaw's
task `cancel` removes the worktree, and `cleanup` deletes the branch best-effort. If a cancelled or failed task's branch
has commits not on its base, rename it to `dartclaw/saved/<taskId>` instead of deleting it. Verify first that no
existing path already preserves such commits (the diff artifact covers only completed worktree tasks).

## 4. Not taken

- **A VM backend (Lima, Apple Virtualization).** ADR-015 settled hardening Docker over hypervisor isolation, and devvm's
  own residuals (inv §5) show a VM does not close the threats that matter here: project-folder writes and exfiltration
  through allowed hosts. A VM boundary adds a ~10-minute first build and hypervisor dependencies for no gain on those.
  The [Pluggable Sandbox Backends](../../INSPIRATION-BACKLOG.md#pluggable-sandbox-backends) entry stays P3.
- **MITM CA with placeholder secrets.** DartClaw's pipe mediation already keeps credentials out without a CA or a
  network path. Only relevant if V1 chooses TLS termination.
- **Agent-config import (`devvm agent import`).** DartClaw deliberately generates auth-clean provider homes; importing
  the operator's hooks and MCP servers into every container is the propagation devvm itself warns about (inv §6).
- **Per-launch confinement self-check.** Worth it for devvm because its confinement rides on deprecated `sandbox-exec`
  and Lima argument shapes (inv §3). Docker's `--network none` has no such fragility.
- **SSH alias / IDE attach, VNC desktop, one VM per folder, `link`/`group`.** Developer-workstation features; DartClaw's
  operator inspects work through diffs, traces and the web UI.

## 5. Docker Sandboxes (`sbx`) as an alternative (added 2026-11-10)

Checked because HN names "Docker sbx" as a devvm alternative and our only prior note (2026-03,
[container-isolation-tradeoff](../container-isolation-tradeoff/research.md)) assumed Docker Desktop. Facts in inv §8.

**As DartClaw's container backend: no.** Four blockers, each against a PRODUCT.md requirement:

1. **Unattended service.** A Docker account login is mandatory, and users report re-login every few days. A
   `dartclaw serve` systemd service cannot depend on a browser OAuth session to Docker Inc.
2. **Headless Linux reach.** Ubuntu 24.04 is the only supported distro, KVM is required, and nested virtualization on
   VM hosts is unsupported, which excludes most cloud VPS hosts, the place a self-hosted server runs.
3. **No local API, proprietary, 0.x.** Control is CLI-only with weekly releases; one release had a hung `exec` wedge
   every sandbox (#385). DartClaw's boundary depends on exact `docker exec -i` pipe behavior that `sbx` documents as
   "matching" but does not specify. A closed binary in the trusted path cuts against "auditable" and "minimal attack
   surface".
4. **Weaker defaults than ours.** Claude runs with `--dangerously-skip-permissions`, SSH-agent forwarding is on, and the
   credential proxy is header substitution behind a TLS-intercepting CA. DartClaw's pipe mediation needs none of that.

**As design input for V1: useful, and it strengthens D1's default.** `sbx` independently ships the policy shape V1
proposes: deny by default, host-side proxy, rules by host *and* HTTP method/path, a log naming the matching rule, and a
`policy check host:port` dry run. Its issue list is also the best evidence against the TLS-termination option for V1:
a CA compromise that forced image rebuilds (0.49.2), broken nested `docker build` trust (#322), whole-body buffering
that breaks SSE (#480), HTTPS failures (#652). The registry-mirror option avoids all of it because the container
speaks plain HTTP to loopback and the host makes the real HTTPS call. One concrete lesson: its `balanced` preset
admits `*.googleapis.com`, and so does NetworkGuard's default allowlist; V1 should pin exact registry origins rather
than reuse that list.

**Later, maybe.** An optional `sbx` backend for macOS developer machines fits the P3
[Pluggable Sandbox Backends](../../INSPIRATION-BACKLOG.md#pluggable-sandbox-backends) entry once it has a local API
and a login model that survives unattended use. Not for 0.28.1.

## 6. Recommendation

V3 is the one to act on now: it closes a present-day path from container to host that needs no new design, only a
path list and a status downgrade. V1 and V2 together decide whether container mode is usable for coding work beyond
editing; they need an owner decision and an ADR, and V2(a) is cheap enough to do regardless. V4 is a one-string fix.
Add V1–V3 to the inspiration backlog once the owner confirms priorities.
