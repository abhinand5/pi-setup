# tests

Run these from the repo root. The full list with one line of scope each is under
[Manual tests](../README.md#manual-tests) — this page adds only what that list cannot say:
how to test a script that writes outside the repo.

`.github/workflows/ci.yml` runs the fast layer on every PR: `bash -n` over the helpers and
scripts, `py_compile` of `bin/ru-spellcheck`, `node --test tests/*.test.mjs`, and every
`tests/*.sh` in a loop — so a new shell test here is wired the moment it lands, with no edit
to the workflow. `prek.toml` covers the commit-time hooks. What stays manual is the slow and
the machine-touching part: `tests/docker-e2e.sh`, and the list under
[Manual tests](../README.md#manual-tests).

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
