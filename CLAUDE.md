# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                 # debug build → .build/debug/skiller
swift build -c release      # release binary → .build/release/skiller
swift test                  # whole suite (swift-testing, not XCTest)
```

Run a single suite or test — the `--filter` argument is a regex matched against
`<target>.<suite>/<test>`, and both suite and test names here are prose strings:

```sh
swift test --filter 'SkillerKitTests.SkillRef parsing'
swift test --filter 'SkillerKitTests.Registry parsing and fusion/an exact name match outranks a partial one'
```

Manual runs need a workspace. Point at a throwaway one rather than a real workspace, since
`add`/`sync --update` clone and hard-reset directories:

```sh
swift run skiller init /tmp/ws
swift run skiller --workspace /tmp/ws search swiftui
```

## Architecture

A CLI that finds agent skills in registries, clones them, and makes one checkout appear in
many groups via relative symlinks.

`SkillerKit` holds all logic; `SkillerCLI` is only ArgumentParser wiring plus printing. New
behaviour belongs in the kit — the CLI target has no tests.

### The three-tier workspace

Everything follows from this layout (see `Workspace/Layout.swift`, which is the single source
of truth for paths — never hard-code a path elsewhere):

```
<root>/.skiller/{config.json,lock.json,last-search.json}
<root>/downloads/<host>/<owner>/<repo>/   git clone, tool-owned cache
<root>/installs/<name>                    symlink → downloads/…/<skill path>, or a real dir
<root>/skills/<group…>/<name>             symlink → installs/<name>
```

- **downloads/** is a cache the tool owns. `sync --update` does `git reset --hard` on it.
- **installs/** is a *flat* namespace, which is the source of the name-collision rule: two
  repos with the same skill directory name make `add` fail rather than overwrite (`--as`).
- **skills/** belongs to the user: arbitrarily nested groups, each entry a symlink. A skill
  can be in any number of groups without being copied.

All symlinks are relative (`LinkManager.relativePath` is purely lexical, never resolving
symlinks) so a workspace can be moved or synced to another machine intact. `LinkManager`
refuses to delete or overwrite a real file or directory — only symlinks.

A skill's `origin` decides whether content can be re-fetched: `.git` skills are a link into a
clone, `.local` skills (from `adopt`) *are* their content in `installs/`, which is why
removing one requires `--prune`.

### Where state changes

`SkillInstaller` is the only type that mutates a workspace — install, link/unlink, remove,
sync, adopt. Everything routes through it so the lock file cannot drift from the filesystem.
`WorkspaceDoctor` is strictly read-only and never repairs; `sync` is what repairs.

`lock.json` (`Model/LockFile.swift`) records enough to rebuild from scratch: repo, skill path,
resolved commit, groups, licence. `LockedSkill.init(from:)` decodes every field optionally so
older lock files keep loading; `WorkspaceConfig.migrate()` version-bumps a config and adopts
sources added since it was written.

Workspace resolution order (`Workspace.resolveRoot`): `--workspace` → `$AGENTIC_WORKSPACE` →
nearest ancestor containing `.skiller/`.

### Registries and search

`MergedRegistry` fans out over three `SkillRegistry` implementations concurrently; a failing
registry contributes a warning, never an aborted search (GitHub code search is unusable
without a token). Two ranking rules exist for concrete reasons documented at their call sites:

- **Reciprocal Rank Fusion** — the sources score on incompatible scales (skills.sh reports
  five-digit install counts, GitHub code search reports no popularity at all). Only position
  within each source's own list counts.
- **Per-repo cap of 3** — aggregator repos mirror hundreds of skills and otherwise take over
  the result list. Held-back rows backfill so the row count still matches `limit`.

Deduplication keys on `owner/repo/<directory name>`, not the full path, because sources spell
the same skill differently (`swift-concurrency` vs `skills/swift-concurrency`).

`RegistryShardIndex` searches a locally cached ~43 MB TSV of ~160k records built by
`skiller index --refresh` into `$XDG_CACHE_HOME/skiller` (workspace-independent). Two
performance decisions there are load-bearing and easy to undo by accident: the index is
tab-separated because JSON-decoding 160k records takes seconds, and `scan` byte-filters each
line against the *longest* query term before decoding it to a String — sound because a record
must match every term to place at all.

`search` writes its results to `.skiller/last-search.json` so `add <number>` can refer back to
them (`SkillReferenceResolver`).

### Git

`GitClient` shells out to `git` rather than linking libgit2, so the user's credential helpers,
proxies and SSH config apply unchanged. `clone` retries a shallow `--branch` failure as a full
clone plus checkout, which is how commit SHAs work. `sync` skips a repo with uncommitted
changes instead of resetting over them.

## Conventions

- Swift 6 language mode, macOS 14+. Public kit types are `Sendable`.
- Error types are `CustomStringConvertible`, and the message carries the fix — e.g. the
  name-collision error names the conflicting source and suggests `--as <name>@<owner>`. Keep
  new errors in that style rather than adding a separate hint-printing layer in the CLI.
- Code, comments, CLI output and error messages are **English**; the README is German.
- Comments explain *why* a non-obvious decision was made (the ranking rules, the TSV format,
  the hard reset). Don't restate what the code says.
- Tests are swift-testing with prose `@Suite`/`@Test` names describing the behaviour, not the
  method under test.
