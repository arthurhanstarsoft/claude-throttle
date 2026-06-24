# claude-throttle

**Stop Claude Code from freezing or restarting your machine.**

When Claude Code spawns several parallel agents and each kicks off a heavy shell
command at once — `pnpm install`, a webpack build, a full test run — your machine
can run out of RAM and CPU, lock up, and hard-restart. `claude-throttle` caps the
resource footprint of whatever Claude Code spawns so it can never bring the whole
machine down.

It runs on **macOS, Linux, and Windows**.

---

## How it protects you

Two independent layers. Either one helps; together they make a freeze essentially
impossible.

### Layer 1 — Throttle (proactive)
A Claude Code **`PreToolUse` hook** intercepts each heavy command and reroutes it
through a wrapper that holds one of *N* concurrency "slots" for the command's whole
duration. Only *N* heavy commands run at once; the rest queue. **N is dynamic** —
it scales with free RAM (roughly one slot per `CT_MEM_PER_SLOT_MB` of free memory,
clamped between `CT_MIN_CONCURRENCY` and `CT_MAX_CONCURRENCY`, capped at your CPU
core count). Dev servers/watchers and background commands are never throttled, and
the hook fails open (if anything goes wrong, the original command runs unchanged).

### Layer 2 — Watchdog (safety net)
A background process watches free memory and, when it gets critically low,
**reversibly pauses** the heaviest processes Claude has spawned, then resumes them
once memory recovers. It's independent of the hook, so it catches anything Layer 1
misses (e.g. commands from subagents). Strict safeguards: only your own processes,
only those above an RSS floor, never system/UI processes or Claude itself.

---

## Supported platforms

| | Throttle (hook + wrapper) | Watchdog | Slot lock | Service manager |
|---|---|---|---|---|
| **macOS** | bash | `memory_pressure`, SIGSTOP/SIGCONT | `lockf` | launchd LaunchAgent |
| **Linux** | bash | `/proc/meminfo`, SIGSTOP/SIGCONT | `flock` | systemd `--user` (nohup fallback) |
| **Windows** | PowerShell 5.1+ | CIM available-memory, `NtSuspendProcess` | named mutexes | Task Scheduler |

---

## Architecture

A shared bash core drives macOS and Linux; Windows is a native PowerShell port of
the same design.

```
bin/claude-throttle      # POSIX entry: detects OS, loads shared + the platform module
shared/                  # OS-agnostic bash: hook, wrapper (slots), watchdog loop, config, common
macos/platform.sh        # macOS metrics, lockf, shlock, launchd + plist template
linux/platform.sh        # Linux metrics, flock, systemd unit + template
windows/claude-throttle.ps1   # full PowerShell port (self-contained)
test/                    # selftest, stress, watchdog tests (bash)
install.sh uninstall.sh update.sh   # bash wrappers (macOS/Linux)
```

Each platform module implements a small interface (`ct_free_pct`, `ct_cores`,
`ct_slot_run`, `ct_singleton_acquire`, `ct_excluded_comm`, `ct_service_*`, …) so
the shared code stays OS-agnostic. Only the shared core + your OS's module are
copied at install time.

Runtime files live under your home directory on every OS:
`~/.config/claude-throttle/`, `~/.local/state/claude-throttle/`,
`~/.local/share/claude-throttle/`, `~/.claude/settings.json`.

---

## Install

**macOS / Linux:**
```sh
git clone <this-repo>
cd <this-repo>
./install.sh
```

**Windows** (normal, non-admin PowerShell):
```powershell
git clone <this-repo>
cd <this-repo>
powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1
```

Then **restart Claude Code** so it loads the hook. The installer is idempotent and
reversible: it seeds your config, copies the tool to a stable location, merges a
`PreToolUse` hook into `~/.claude/settings.json` (backing up the original), and
registers the watchdog to run at login. Nothing happens until you run it.

**Requirements**
- macOS: `bash`, `jq`; `lockf`/`shlock` ship with macOS. `cpulimit` optional.
- Linux: `bash`, `jq`, `flock` (util-linux), `tac`; systemd `--user` recommended
  (a nohup/login fallback is used otherwise). procps `ps` recommended.
- Windows: Windows PowerShell 5.1 (preinstalled on Win10/11). No admin, no jq.

---

## Everyday use

Once installed there's nothing to do — Claude Code just stops overwhelming your
machine. To check on it:

```sh
claude-throttle status     # live: concurrency now, free memory, watchdog, paused procs
claude-throttle doctor     # full health check: OS, deps, config, install, metrics
```
On Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File <install-dir>\windows\claude-throttle.ps1 status`.

Logs: `~/.local/state/claude-throttle/throttle.log` (what got wrapped/queued) and
`watchdog.log` (pause/resume events).

---

## Configure

Edit the config (takes effect on the next command / watchdog tick — no reinstall):
- macOS/Linux: `~/.config/claude-throttle/config.sh`
- Windows: `~/.config/claude-throttle/config.ps1`

Most useful settings (same names on all platforms):

| Setting | Default | Meaning |
|---|---|---|
| `CT_ENABLED` | `1` | Master on/off for all three components |
| `CT_DYNAMIC` | `1` | `1` = scale concurrency with free RAM; `0` = fixed at `CT_MAX_CONCURRENCY` |
| `CT_MAX_CONCURRENCY` | `6` | Ceiling on concurrent heavy commands |
| `CT_MIN_CONCURRENCY` | `1` | Floor (work never fully stalls) |
| `CT_MEM_PER_SLOT_MB` | `1500` | RAM assumed per heavy command — **lower for more parallelism, raise to be safer** |
| `CT_GATE_MODE` | `heavy` | `heavy` = only wrap heavy commands; `all` = wrap everything |
| `CT_BYPASS_PERMISSIONS` | `0` | `1` = auto-approve wrapped commands (skip the prompt) |
| `CT_CRIT_FREE_PCT` / `CT_RESUME_FREE_PCT` | `10` / `25` | Watchdog pause / resume memory thresholds |

---

## Update

After editing the repo:
```sh
./update.sh                 # macOS/Linux (or: claude-throttle update, from anywhere)
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\claude-throttle.ps1 update   # Windows
```
Re-copies the latest code into the install location and reloads the watchdog,
preserving your config.

## Uninstall

```sh
./uninstall.sh              # macOS/Linux
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <install-dir>\windows\claude-throttle.ps1 uninstall
```
Removes the hook, the watchdog service, and the installed copy; keeps your config
and logs. Restart Claude Code afterward.

---

## Verify it works

macOS/Linux:
```sh
bash test/selftest.sh        # parsers, hook rewrite, exit codes, kill switch, dynamic concurrency
bash test/stress.sh          # asserts concurrency never exceeds the limit
bash test/watchdog-test.sh   # spins up a heavy process, asserts it gets paused then resumed
```
Hook smoke test (any OS): pipe a JSON tool call into the `hook` subcommand —
`{"tool_input":{"command":"pnpm install"}}` should produce a rewrite to the
wrapper; `{"tool_input":{"command":"ls"}}` should produce nothing.

---

## Platform notes & caveats

- **macOS:** the tool installs to `~/.local/share` (never `~/Documents`, which
  macOS privacy controls block launchd from executing).
- **Linux:** without systemd `--user`, the watchdog falls back to a login-launched
  background process (no crash auto-restart). `flock`, `tac`, and procps `ps` are
  expected; `doctor` warns if missing.
- **Windows:** the watchdog suspends processes via the undocumented (but stable)
  `NtSuspendProcess` API; on locked-down corporate machines (Constrained Language
  Mode) this may be unavailable — the hook still works, the watchdog degrades.
  The wrapper runs your command through `bash.exe` if present, otherwise `cmd.exe`
  (set `CT_INNER_SHELL` to force one); it must match the shell Claude itself uses.

## How it works under the hood

- **Slots**: a lock held for the command's whole life, auto-released if the
  process dies (`lockf`/`flock` advisory locks; named mutexes with
  abandoned-mutex recovery on Windows).
- **Memory**: macOS `memory_pressure`; Linux `/proc/meminfo` MemAvailable; Windows
  CIM available memory — all parsed locale-safely as integers.
- **Process tree**: walk the pid/ppid tree up to the `claude` process, then filter
  by owner, size, and an OS-specific exclusion list before pausing anything.
