---
layout: default
title: Contributing
nav_order: 10
---

# Contributing to litesoup

Welcome! litesoup is a small, opinionated bash installer for a LAMP-ish
stack on Ubuntu. The codebase is intentionally boring — POSIX-ish bash,
shellcheck-clean, fail-fast, idempotent. This guide shows you the loop
we use day to day so your first PR feels familiar.

## 1. Quick start for contributors

```bash
# Clone with submodules — bats-core lives in test/bats/bats-core
git clone --recurse-submodules https://github.com/codetot-web/litesoup.git
cd litesoup

# Branch off main, naming it after the issue you're closing
git checkout -b feat/42-add-thing

# Edit code. Keep changes small. Read before you write.

# Run the local test loop (see below) before pushing
shellcheck -x -e SC1091 install/install-stack.sh install/lib/*.sh \
                        site/*.sh harden/*.sh audit/*.sh
./test/bats/bats-core/bin/bats test/bats/

# Push and open a PR
git push -u origin feat/42-add-thing
gh pr create --fill
```

CI will re-run shellcheck, bats, and a Docker integration job. All three
must be green before merge.

## 2. Local test loop

Three commands cover ~95% of regressions. Run them in order — fastest
first, slowest last:

```bash
# (a) shellcheck — instant. Same flags CI uses.
shellcheck -x -e SC1091 install/install-stack.sh install/lib/*.sh \
                        site/*.sh harden/*.sh audit/*.sh

# (b) bats unit tests — a few seconds. Pure helpers, no system mutation.
./test/bats/bats-core/bin/bats test/bats/

# (c) Docker integration — minutes. Spins a real systemd container and
#     runs install-stack + site create/delete end-to-end.
./test/docker/run-integration.sh 01_install_stack.sh 02_site_create.sh 03_site_delete.sh
```

The integration test needs Docker running (Docker Desktop or OrbStack on
macOS; Docker Engine on Linux). If you don't have it locally, push and
let CI run it — but expect a slower feedback loop.

## 3. Conventions

Every script in this repo follows the same shape. New scripts should too.

- **Shebang:** `#!/usr/bin/env bash` — never `/bin/sh`, never `/bin/bash`.
- **Header:** 2-line comment explaining what the script does and what it
  touches, followed by a `usage()` function with a `cat <<'EOF'` Usage block.
- **Source common.sh:** `source "$(dirname "$0")/../install/lib/common.sh"`
  (or the right relative path). This gives you:
  - `set -Eeuo pipefail` — fail fast on errors, undefined vars, pipe failures.
  - `log_info` / `log_warn` / `log_error` — timestamped stderr logging.
  - `run_or_dryrun` — runs the command, or prints it under `DRY_RUN=1`.
  - `require_root` — exit 1 if not running as root.
  - An `ERR` trap that prints the failing line number.
- **Flags:** support `--dry-run` and `--help` at minimum. Many scripts also
  take feature-specific flags (`--no-password-auth`, `--skip-hardening`).
- **Idempotent writes:** never blindly overwrite a managed config file.
  Use the cmp-then-install pattern — write to a tmp file, `cmp -s` against
  the live file, only `install -m 0644` if they differ. See
  `install/lib/redis.sh` (and the `harden/*.sh` scripts) for canonical
  examples. This means re-running install-stack is safe and cheap.
- **Reload, not restart:** prefer `systemctl reload` over `restart`. Reload
  preserves live connections and SSH sessions. Reload only the services
  whose managed config actually changed.
- **shellcheck-clean:** `shellcheck -x -e SC1091` must pass. `-x` follows
  sourced files via `# shellcheck source=` annotations. `-e SC1091` ignores
  runtime-resolved sources that `-x` already covers.

## 4. Test layers

| Layer       | Tool   | Where                       | When to add a test                                     |
|-------------|--------|-----------------------------|--------------------------------------------------------|
| Unit        | bats   | `test/bats/`                | New helper function or pure logic                      |
| Integration | docker | `test/integration/`         | New install-stack stage or `site-*` script             |
| Acceptance  | shell  | `test/acceptance-*-run.sh`  | New plan or release; run on real Ubuntu (sg10.codetot.org) |

Bats tests should source `install/lib/common.sh` in a subshell and assert
on observable behavior — see `test/bats/unit_common.bats` for the style.
Integration tests run inside a systemd-enabled container and exercise the
real apt + systemctl path. Acceptance tests run on a real Ubuntu VPS and
catch things Docker can't (PPA reachability, real systemd-resolved, real
TLS cert issuance) — required for any change that touches `install-stack.sh`.

## 5. Multi-agent dispatch pattern

This repo's release workflow leans on parallel Claude subagents. It's
worth knowing why, because future contributors will want to reuse it.

**Wave 1 (v0.6.0)** — 4 audit ports + 3 harden scripts, written by 7
parallel Claude subagents in a single dispatch. ~30 minutes of
wall-clock time produced 2367 LOC of shellcheck-clean bash across 7 new
files. The adversarial review pass caught one real bug (harden-fail2ban
watched the wrong port when sshd ran on a non-default port — fixed by
sharing the `detect_ssh_port` parser with harden-firewall).

**Wave 2 (v0.7.0)** — 3 hardening scripts (sshd, Apache, PHP). Per the
routing table in `~/.claude/CLAUDE.md`, we tried local Ollama
qwen2.5-coder:14b first as the daily-driver codegen model. Output was
shellcheck-clean but contained 3 semantic bugs:

1. Literal `\n` inside heredoc content → produced an invalid sshd_config.
2. Validation step ran against the wrong file (validated source, not
   the installed copy).
3. Unset variable crashed under `set -u` because a counter wasn't
   initialized.

We fell back to 3 parallel Claude subagents. All 3 delivered correct
working scripts in ~2 minutes. The per-script briefs explicitly named
each qwen failure mode ("don't write `\n` strings — use a heredoc";
"validate AFTER install, not before"; "initialize CHANGED=0 — set -u
crashes otherwise") and each subagent reported avoiding them.

**Lesson:** shellcheck-clean does not equal semantically correct. Local
models are useful for drafts, but Claude subagents remain the safer
default for bash codegen with critical correctness requirements.

**Subagent brief checklist** — every dispatch brief should be self-contained:

- Scope-locked target file (one file per agent, no scope creep).
- No `/tmp` output (write directly to the target path so the parent can review).
- No commits (parent integrates everything in one commit per file or per wave).
- Max 2 retries on errors (if the model fails twice, escalate — don't loop).
- Explicit reference files for conventions (e.g., "match the shape of
  `install/lib/redis.sh`").

## 6. Pull request checklist

Before opening a PR:

- [ ] Branch off `main`, named `feat/N-…`, `fix/N-…`, or `chore/N-…`.
- [ ] Commit message references the issue: `fix: short description (closes #42)`.
- [ ] CI is green (shellcheck + bats + integration).
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]` (or the new version
      heading if you're cutting a release).
- [ ] `VERSION` is bumped per semver if this is a release PR.
- [ ] For any change that affects `install-stack.sh` or anything it sources:
      run `test/acceptance-*-run.sh` on `sg10.codetot.org` (or another real
      Ubuntu host) and paste the result in the PR. Docker can't see
      everything — see [Real-Ubuntu acceptance findings](../notes/) for why.

## 7. Code review

Three review passes catch different things. Use them in order:

- **CI** — shellcheck (style + a handful of pattern bugs) + bats (unit
  behavior) + integration (real apt/systemctl path). Mechanical, runs on
  every push. Required.
- **Pre-landing review** — `/ship` skill walks the diff against `main` and
  flags structural issues, security gotchas (SQL safety, trust-boundary
  violations, conditional side effects), and missing test coverage. Run
  before merging anything non-trivial.
- **Adversarial review** — a second Claude pass (or codex CLI) hunting
  specifically for edge cases the implementer missed. Worth the few
  minutes for any state-changing script — it's how we caught the
  harden-fail2ban port bug in v0.6.0.

Small fixes (typo, comment, single-line change) can skip the latter two.
Anything that touches state on a real host should not.

---

Questions? Open an issue, or look at the existing `install/lib/*.sh` and
`harden/*.sh` scripts — they're the canonical examples for almost every
pattern this guide describes.
