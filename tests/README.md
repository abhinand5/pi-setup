# tests

Run these from the repo root. The full list with one line of scope each is under
[Manual tests](../README.md#manual-tests) — this page adds only what that list cannot say:
how to test a script that writes outside the repo.

Nothing here is gated automatically today. `prek.toml` runs its hooks on commit, and
everything else is manual: `bash -n` on `bin/*` and `*.sh`, `node --test tests/*.test.mjs`,
the shell tests, `tests/docker-e2e.sh`. No CI job exists yet; a workflow that runs the fast
checks is in open PR #19. Until it merges, "the tests pass" means someone ran them.

`docker-e2e.sh` is the only test that leaves the machine: it clones this repo from its git
remote inside a container. `browser-uat-login-proxy.sh` stubs Playwright and fails on
`goto`, so it reaches no network at all.

## Testing a script that writes to `$HOME`

`install.sh`, `sync.sh`, and `uninstall.sh` all write outside the repo, so a test points
`HOME` and `BIN_DIR` at a throwaway directory and runs the real script against it. Two
rules, both learned the hard way:

**Never `cp -a` a worktree into `/tmp` to get a disposable copy.** A worktree's `.git` is a
*file* holding an absolute path to the real gitdir, so a commit made in the copy lands on
the branch in the worktree — author and all. On 2026-11-19 a `git commit -m wip` in
`/tmp/sync-test` did exactly that. Use `git clone`, and because a clone carries the
*committed* scripts rather than the ones under review, copy them over:

```bash
clone="$(mktemp -d)/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"   # a real .git directory, isolated branch
cp "$ROOT/sync.sh" "$ROOT/install.sh" "$clone/" # test the working tree, not the last commit
```

**Seed a fake Pi home with the installer itself** instead of hand-writing `settings.json`:
`sync.sh` validates the JSON and themes it finds, and dies on a home that only half
exists (`FileNotFoundError: … ~/.pi/agent/settings.json`).

```bash
home="$(mktemp -d)"
env HOME="$home" BIN_DIR="$home/.local/bin" ./install.sh --restore --copy-config
env HOME="$home" ./sync.sh --no-skills --no-push "test capture"
```

Assert on files and `git` state, not on log text: `cmp -s`, `git show --name-only`,
`test -f`. `tests/home-dotfiles.sh` is the worked example.
