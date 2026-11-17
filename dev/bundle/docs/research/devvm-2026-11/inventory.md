# devvm – Sourced Inventory

**Accessed**: 2026-11-07 · Companion to [research.md](research.md), which cites this file as `inv §N`.

Sources: https://devvm.dev and its docs pages (cited `D <path>`), https://github.com/devvmhq/devvm (`GH`), the Syntax
video https://www.youtube.com/watch?v=rMvj3HAlTvg (`V mm:ss`, from the transcript), the HN thread
https://news.ycombinator.com/item?id=50395450 (`HN`). Items marked *(inferred)* are not stated by a source.

Not read: docs pages for images, vms, devcontainer, from, space, upgrading, troubleshooting, the CLI reference, the
`/docs/safety/` habits section, `/docs/backends/`, most `/docs/internals/*` subpages, GitHub issues.

## §1 Product and maturity

- "One VM for every project": run `devvm` in a project folder; it creates an isolated Lima VM with the project's
  toolchain, where you or a coding agent work (devvm.dev, GH).
- Author CJ (`w3cj`, Coding Garden); 603 of 604 commits (GitHub API). MIT, free, Go. Org `devvmhq`.
- Repo created 2026-11-06; one CHANGELOG entry, 0.1.0 (GH). 243 stars on 2026-11-07. Tested on Apple-silicon Macs and
  Linux arm64/x86_64; Intel Macs untested (GH, D using/limits).
- Reception: Syntax video published 2026-11-06 (21 min); HN 148 points / 58 comments, no author replies (HN).

## §2 VM and file model

- Lima only: Apple Virtualization (vz) on macOS 13+, QEMU/KVM on Linux; Lima 2.2+ (GH, D backends/lima).
- Default mode mounts the project folder read-write at the same path (virtiofs on macOS, 9p on Linux); no sync engine
  (D internals/overview).
- `--clone` mounts nothing: copies the repo into the VM, pushes local branches over SSH with pinned host keys, adds a
  `devvm` remote on the host; `git fetch devvm` brings back `devvm/*` branches. Uncommitted and untracked files, tags
  are not copied (D using/clone, V 11:45, 16:04).
- Base Ubuntu image built once (up to ~10 min, V 05:16); later VMs are copies that start in ~5 s (V 09:24).
- Images = base + ordered layers (`docker`, `nix`, `desktop`, custom shell-script layers). Toolchains (node, python,
  rust, go, …) are shared read-only images detected from project files (`package.json` → node), extra via `--tools`
  (devvm.dev, D internals/design). Layer change remakes the VM, keeping only home (D using/limits).
- `devcontainer.json` read as data only; `initializeCommand`, `${localEnv:…}`, extra mounts refused (D internals/design).
- Rejected designs: EROFS overlay layers (10–50 ms slower cold start), SQLite/bbolt state (plain files instead)
  (D internals/design, "Failed attempts").

## §3 Egress

- Every VM's traffic goes through a per-VM host proxy; DNS resolves via the proxy; confined VMs make no direct
  connections (D safety/network).
- Tiers: `open`, `internet`, `allowlist` (default), `none` (only agent hosts, secret hosts, links).
- Every launch runs a confinement self-check; a failing VM shows as `unenforced` (D safety/network).
- Rule sources in order: built-in, layer policies, global `~/.config/devvm/policy`, per-VM policy. **Rules never come
  from the project folder** (D safety/network).
- A blocked request gets HTTP 403 naming the host and the rule that would allow it; in-VM `devvm-why` and
  `http://devvm.proxy/blocked` explain blocks (D safety/network, V 02:50, 07:52). Host: `devvm network allow|deny|rm`,
  `devvm network log [--blocked|--follow|--json]`.
- Not built yet: approve-on-hit, method/path rules on decrypted hosts (D internals/design).
- CJ on the allowlist: you "gradually build up" the list (Prisma, Playwright downloads); "growing pains of using a
  network block" (V 10:08, 12:32).
- macOS confinement uses deprecated `sandbox-exec`; Linux confinement depends on the shape of Lima's `-netdev`
  argument and refuses to start QEMU if it changes (D internals/design, "Open work and risks").

## §4 Credentials

- Secrets on the host (macOS Keychain or `~/.local/share/devvm/secrets/`); the VM holds placeholders; the proxy swaps in
  real values only for each secret's own hosts, via a per-VM CA valid 30 days (D safety/network).
- Agent login (`devvm agent login claude|codex|opencode`) runs in the VM, the credential is stored on the host and
  injected by the proxy, shared across VMs (D using/coding-agents, V 08:03–08:44). The Claude login capture uses an
  undocumented path; `claude setup-token` is the fallback (D internals/design).
- Never mounted: SSH keys, `~/.aws`, cloud/k8s/Docker/npm credentials, browser profiles, Keychain (D safety/attack-vectors).
- Proxy blocks GitHub REST calls that mint SSH keys, deploy keys, runners, webhooks; not GraphQL or OAuth grants
  (D safety/attack-vectors).
- `secret unuse`/`rm` revoke VM access but not credentials the VM already minted (D safety/network).

## §5 Git and project-file protection

- macOS: `.git` hooks and config locked with `chflags uchg` (VM root can't clear); Linux has no equivalent, use
  `--clone` (D safety/git-protection). Side effect: `git config`, husky and pre-commit installs fail.
- Documented gaps: the VM can rename `.git`; `.husky/` in the tree is unprotected.
- **Threats not closed** (D safety/attack-vectors): the project folder is VM-writable, so `.claude/settings.json`,
  `.mcp.json`, `CLAUDE.md`, `AGENTS.md`, `.vscode`, `.envrc`, `mise.toml`, husky hooks and symlinks remain
  host-exploitable; `--clone` keeps them away until reviewed. Allowed upload hosts (GitHub push, npm publish) carry data
  out. Domain fronting works because the proxy checks SNI, not the inner Host header. The injected GitHub token can be
  abused within its scope (Shai-Hulud-style worm). Hypervisor bugs could allow escape.
- "Agents run with permission checks disabled" is listed under "kept inside the VM", with the advice "use commits or
  `--clone`" (D safety/attack-vectors).

## §6 Agents and lifecycle

- Supported: Claude Code, Codex, opencode. Agents run inside the VM; nothing installed on the host
  (D using/coding-agents, V 01:48).
- `devvm agent import` copies settings and skills from the host home, never history or `.credentials.json`; settings
  folders mounted read-only; settings files copied each launch with secrets as placeholders; MCP env values replaced
  by `devvm-redacted`. `devvm agent save` copies changes back after a diff and confirmation (D using/coding-agents).
- Parallel work: worktrees in `.worktrees/NAME` inside a clone VM share the VM's tier, secrets and resources; for
  isolation use one VM per agent (D using/clone). Demo: one Claude with sub-agents and worktrees adds five endpoints
  in the background (V 08:44, 10:49).
- VMs keep running after the shell exits (V 06:41). `devvm rm` exports agent history first (`.tar.gz`, 2 GiB cap,
  re-imported for the same folder) and, for clone VMs, checks for unfetched commits and uncommitted work and offers to
  save them as `saved/devvm/<branch>` (D using/clone, V 11:09, 19:25). Retention is off by default; devvm never deletes
  VMs automatically (D using/settings).
- Each VM is an SSH alias (`devvm-<folder>`); `devvm code` opens VS Code Remote-SSH; herdr and T3 Code auto-discover
  the aliases (V 07:01, 16:51–18:55). Ports ≥1024 auto-forwarded (TCP). `devvm link`/`group` connect VMs.
- Config `~/.config/devvm/config.toml`, strict parsing (unknown keys stop the command); precedence flag → config →
  setup values → default (D using/settings).

## §7 Outside criticism (HN)

"A fun toy for single project development"; one VM per directory blocks multi-repo setups; "the more you restrict the
agents, the less useful they become"; distrust of curl-to-shell install and stored logins; does it warn about git hooks
in a cloned malicious repo; alternatives named: libvirt, podman, incus, smolvm, Docker sbx, Canonical workshop, exe.dev.

## §8 Docker Sandboxes (`sbx`) – accessed 2026-11-10

Compared as an alternative backend (research.md §6). `sbx` was not run; sources are docs, the docs-repo CLI YAML
(`github.com/docker/docs/tree/main/data/sbx_cli`), `github.com/docker/sbx-releases` issues and write-ups.

- **Status and license.** Standalone CLI, 0.x, latest 0.51.0 of 2026-11-03, roughly weekly releases
  (docs.docker.com/ai/sandboxes/release-notes/). Proprietary: `docker/sbx-releases` ships binaries only, README
  "Proprietary, Docker Inc.". No Docker Desktop or Engine needed (…/install/). Local use free, commercial included
  (…/faq/). **Docker account and `sbx login` required**; HN users report re-login every few days breaking scripted use
  (news.ycombinator.com/item?id=49239751); headless login needed a manual dbus/keyring setup in v0.31.1 (issue #186),
  file fallback now documented. Telemetry on by default (`SBX_NO_TELEMETRY=1`).
- **Isolation.** One microVM per sandbox with its own kernel and Docker daemon (…/security/isolation). Hypervisor per
  HN Docker staff: Hypervisor.framework, WHP, KVM, via a new VMM. Start time undocumented; one open report of 30–70 min
  on Rocky 8 / Ubuntu 24.04 (issue #621).
- **Platforms.** macOS 14+ Apple silicon only; Windows 11 with WHP; **Linux: Ubuntu 24.04+ only supported distro**,
  KVM required, nested virtualization on VM hosts not supported for local sandboxes (…/install/).
- **Egress.** Deny-by-default TCP, UDP/ICMP blocked, DNS via a policy-enforcing resolver (…/security/defaults);
  host-side forward proxy for HTTP(S) (…/architecture/). Presets `allow-all`, `deny-all`, `balanced` (~194 rules incl.
  `registry.npmjs.org`, `pub.dev`, and broad `*.googleapis.com`; andrewlock.net, v0.47.0). Rules support host
  wildcards, ports, CIDR, **HTTP method/path/query** (docs.docker.com/ai/governance/local/network-rules/).
  `sbx policy log --json` shows allowed/blocked hosts with the matching rule; `sbx policy check network host:port`.
- **TLS interception** *(inferred from method/path rules; not in official docs)*: secondary sources report a
  per-session proxy CA wired via `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`. Reported side effects:
  nested `docker build` fails verification (#322), proxy buffers whole bodies and breaks SSE (#480), "Empty reply from
  server" on HTTPS (#652). Release 0.49.2 rebuilt images after a CA compromise; existing sandboxes needed
  `--pull always` (release notes).
- **Credentials.** Host proxy overwrites auth headers for matching hosts; VM sees a sentinel (…/configuration/credentials/).
  SSH-agent forwarding on by default; OAuth `passthrough: true` kits send the real token into the VM.
- **Workspace.** Direct read-write mount at the same path by default; `--clone` mounts the repo read-only and returns
  commits via a `sandbox-<name>` remote; `.git` hooks can run implicitly (…/architecture/, andrewlock.net).
- **Programmatic control.** `sbx create`, `sbx exec [-i] [-t] [-e] [-w]` ("match the behavior of `docker exec`",
  except `-d`), `sbx rm`, JSON output on `ls`/`inspect`/`policy log` (CLI YAML). Binary-clean `exec -i` pipes not
  documented *(inferred to work: stdio MCP servers use it, issue #800)*. A hung exec wedged all sandbox operations in
  v0.37.0 (#385). **No local API**; the REST API and TS SDK are cloud-only and paid (docs.docker.com/ai/sandboxes-api/).
  Custom images via `sbx create -t IMAGE`, kits, templates.
- **Agents.** claude, codex, copilot, cursor, gemini, opencode and others; Claude runs with
  `--dangerously-skip-permissions` by default (…/agents/claude-code).
- **Open issues**: 265 on `sbx-releases` at time of check.
