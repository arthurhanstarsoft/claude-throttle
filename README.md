# claude-throttle

**Stop Claude Code from freezing or restarting your Mac.**

When Claude Code spawns several parallel agents and each one kicks off a heavy
shell command at the same time — `pnpm install`, a webpack build, a full test
run — your machine can run out of RAM and CPU, lock up, and hard-restart. That's
not an API or rate-limit problem; it's your laptop being asked to do eight heavy
things at once.

`claude-throttle` caps the resource footprint of whatever Claude Code spawns so
it can never bring the whole machine down. It's a small tool written in plain
bash using utilities already on macOS — no daemons you have to babysit, no Node
service, no kernel extensions.

---

## How it protects you

Two independent layers. Either one alone helps; together they make a freeze
essentially impossible.

### Layer 1 — Throttle (proactive)

A Claude Code **`PreToolUse` hook** intercepts each heavy Bash command and
rewrites it to run through a wrapper. The wrapper grabs one of *N* "slots" and
holds it for the command's entire duration. Only *N* heavy commands (default
**2**) ever run at once — the rest wait in line and start as slots free up.

```
Claude runs:   pnpm install      tsc -b        vitest run     npm run build
                    │                │              │               │
hook rewrites each to:  claude-throttle run -- "<command>"
                    │                │              │               │
                 [slot 1]        [slot 2]      (waiting…)      (waiting…)
                    └──── at most 2 run at once; others queue ────┘
```

It is designed to **never get in your way**:
- If anything goes wrong (missing dependency, bad input), the original command
  runs unchanged — the throttle *fails open*.
- If all slots stay busy too long, the command runs anyway instead of blocking
  Claude forever.

### Layer 2 — Watchdog (safety net)

A tiny background agent (managed by macOS `launchd`) watches free memory every
couple of seconds. If memory gets critically low, it **pauses** the heaviest
processes Claude has spawned — freezing them in place rather than letting the
whole Mac freeze — and **resumes** them automatically once memory recovers.
Pausing is reversible (`SIGSTOP`/`SIGCONT`); no work is lost.

This layer doesn't depend on the hook at all, so it catches anything the hook
might miss (for example, commands run from inside a subagent).

Safeguards: it only ever pauses *your own* processes that are confirmed children
of Claude and large enough to matter. It will never touch `claude` itself, system
services, the window server, or your terminal.

---

## Requirements

- macOS (Apple Silicon or Intel)
- `bash` and `jq` (`jq` is needed for the hook; `brew install jq` if missing)
- `lockf` and `shlock` — already included with macOS
- *Optional:* `cpulimit` (`brew install cpulimit`) to also cap CPU percentage

---

## Install

```sh
git clone <this-repo>
cd <this-repo>
./install.sh
```

Then **restart Claude Code** so it loads the new hook.

The installer is safe and reversible. It:

1. creates your config at `~/.config/claude-throttle/config.sh`,
2. puts the `claude-throttle` command on your `PATH` (`~/.local/bin`),
3. adds the hook to `~/.claude/settings.json` (backing up the original to
   `settings.json.bak`),
4. starts the watchdog and sets it to run automatically at login.

Nothing happens to your system until you run `./install.sh` — you can clone and
read the code first.

> Installing on several machines? Just copy the folder (or clone the repo) and
> run `./install.sh` on each. All paths are derived from `$HOME`, so it works for
> any user.

---

## Everyday use

Once installed, **there's nothing to do** — Claude Code just stops overwhelming
your machine. The commands below are for checking on it or tuning it.

```sh
claude-throttle status      # quick live state: concurrency, memory, watchdog, paused procs
claude-throttle doctor      # full health check: dependencies, config, install status, metrics
```

Example `status`:

```
enabled=1 gate=heavy concurrency=2
free_mem=45% load1x100=364
watchdog: RUNNING (pid 5123)
currently paused: 0 process(es)
claude descendants: 6
```

### Turn it off / on

```sh
# instant kill switch — open the config and set CT_ENABLED=0 (or back to 1)
open ~/.config/claude-throttle/config.sh
```

`CT_ENABLED=0` disables all three components immediately; no reinstall needed.

### See what it's doing

```sh
tail -f ~/.local/state/claude-throttle/throttle.log   # which commands were wrapped / queued
tail -f ~/.local/state/claude-throttle/watchdog.log   # pause / resume events
```

---

## Configuration

Edit `~/.config/claude-throttle/config.sh`. Changes take effect on the next
command or watchdog tick — no reinstall. The most useful settings:

| Setting | Default | What it does |
|---|---|---|
| `CT_ENABLED` | `1` | Master on/off switch for everything |
| `CT_MAX_CONCURRENCY` | `2` | How many heavy commands may run at once |
| `CT_GATE_MODE` | `heavy` | `heavy` = only throttle resource-heavy commands; `all` = throttle every command |
| `CT_HEAVY_REGEX` | *(see file)* | Which commands count as "heavy" (npm/pnpm/build/test/cargo/docker/…) |
| `CT_NICE` | `10` | Lower CPU priority applied to wrapped commands |
| `CT_USE_CPULIMIT` | `0` | Set to `1` after `brew install cpulimit` to also cap CPU % |
| `CT_CRIT_FREE_PCT` | `10` | Watchdog pauses processes when free memory drops to/below this |
| `CT_RESUME_FREE_PCT` | `25` | Watchdog resumes them when free memory rises to/above this |
| `CT_MIN_PAUSE_RSS_MB` | `150` | Never pause a process smaller than this |

**Tuning guidance**

- Lots of RAM (32 GB+)? You can raise `CT_MAX_CONCURRENCY` to 3–4.
- Tight on RAM (8 GB)? Keep it at 2 (the default) or even 1.
- Want *everything* throttled, not just builds/tests? Set `CT_GATE_MODE=all`
  (adds a few milliseconds to every command).

Precedence is **config file → environment variable → built-in default**, so you
can also override any setting for a one-off, e.g.
`CT_MAX_CONCURRENCY=1 claude ...`.

---

## Verify it works

```sh
bash test/selftest.sh        # parsers, hook rewrite, exit codes, kill switch
bash test/stress.sh          # launches parallel jobs, asserts concurrency stays within the limit
bash test/watchdog-test.sh   # spins up a heavy process, asserts it gets paused then resumed
```

`stress.sh` and `watchdog-test.sh` use isolated temporary state, so they never
touch your real configuration or running watchdog.

You can also confirm the hook end-to-end:

```sh
echo '{"tool_input":{"command":"pnpm install"}}' | claude-throttle hook
# -> JSON rewriting the command to: claude-throttle run -- 'pnpm install'

echo '{"tool_input":{"command":"ls"}}' | claude-throttle hook
# -> no output (a trivial command, left untouched)
```

---

## Troubleshooting

**The hook isn't running.** Restart Claude Code after installing. Check
`claude-throttle doctor` shows "PreToolUse hook installed". Confirm `jq` is
installed.

**Commands feel slow / serialized.** That's the throttle working — heavy commands
are queueing. Raise `CT_MAX_CONCURRENCY` if your machine can handle more.

**Watchdog not running.** `claude-throttle doctor` will say so. Re-run
`./install.sh`, or check `~/.local/state/claude-throttle/watchdog.log`. You can
also start it manually: `claude-throttle watchdog &`.

**A process got paused and I want it back now.** It resumes automatically when
memory recovers. To force it, stop the watchdog (`claude-throttle uninstall`, or
kill the watchdog pid in `~/.local/state/claude-throttle/watchdog.pid`) — it
resumes everything it paused on exit.

**I want it completely off.** Set `CT_ENABLED=0` in the config (instant), or run
`./uninstall.sh` to remove it entirely.

---

## Uninstall

```sh
./uninstall.sh
```

Removes the hook from `settings.json`, stops and unregisters the watchdog, and
removes the `claude-throttle` symlink. Your config and logs are left in place in
case you reinstall — delete `~/.config/claude-throttle` and
`~/.local/state/claude-throttle` if you want them gone too. Restart Claude Code
afterward.

---

## Files & layout

```
bin/claude-throttle              CLI entry point (hook|run|watchdog|status|doctor|install|uninstall)
  libexec/
    common.sh                      shared config loading, logging, metric parsing
    hook-pretooluse.sh             the PreToolUse hook (rewrites heavy commands)
    wrapper.sh                     holds a concurrency slot while a command runs
    watchdog.sh                    Layer 2 memory watchdog loop
  share/
    config.example.sh              documented default config
    com.user.claude-throttle.watchdog.plist.template
  test/                            selftest, stress, watchdog tests
  install.sh  uninstall.sh
```

Runtime files live under your home directory, never in the repo:

```
~/.config/claude-throttle/config.sh                  your settings
~/.local/state/claude-throttle/throttle.log          throttle activity
~/.local/state/claude-throttle/watchdog.log          watchdog activity
```

---

## How it works under the hood

- **Slots** are implemented with `lockf` (an advisory lock on a file descriptor).
  The lock is held for the command's whole life and released automatically if the
  process exits, crashes, or is killed — so there are no stale locks to clean up.
- **Memory readings** come from `memory_pressure`, parsed with `LC_ALL=C` and
  integer math so they're correct even on systems whose locale uses comma
  decimals.
- **Claude's child processes** are found by walking the process tree
  (`pid`/`ppid`) up to the `claude` process, then filtered by owner, size, and an
  exclusion list before anything is ever paused.

If you're curious, every script is short and commented.
