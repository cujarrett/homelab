# APP_NAME

Go HTTP API. Single binary, stdlib only. Commands are in the README and the `justfile`.

## Rules

- **Never run `git add`, `git commit`, `git push`, or any git command that writes to or modifies the index, repository history, or remotes.** Output the commands for the user to run. Staging is part of their review.
- **Never add a `Co-Authored-By` trailer or a "Generated with Claude Code" line** to commit messages or PR descriptions, including in suggested commit messages. Commits are authored by the user alone.
- **Whenever a task requires a commit, always give a suggested commit message.** Give `git add` and the commit as two separate steps, listing every file explicitly. Never output a `git push` command.
- **Cheapest rung that works.** Before writing code go down the ladder and stop at the first rung that solves it: skip the feature, reuse code already here, standard library, native platform feature, a dependency already installed, one line, then build the minimum.

### Pre-commit safety check

Before telling the user to commit, always run `/security-review`. Once it confirms the changes are safe, offer a suggested commit message.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." - [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.**
- **80/20 solutions.** Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so.

## Conventions

- stdlib `net/http` only, `slog` for logging
- Graceful shutdown via `signal.NotifyContext`
- `/healthz` is the readiness probe
- Errors returned as `{"error":"..."}` JSON
- Binary name matches repo name
