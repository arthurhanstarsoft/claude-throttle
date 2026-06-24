# claude-throttle config — sourced as bash. Copied to
# ~/.config/claude-throttle/config.sh at install time. Edit values and they take
# effect on the next command / watchdog tick (no reinstall needed).
# Anything you delete falls back to the built-in default in shared/common.sh.

CT_ENABLED=1            # master switch: 0 disables hook, wrapper AND watchdog instantly
CT_GATE_MODE=heavy      # heavy = only wrap resource-heavy commands; all = wrap every Bash command
CT_HEAVY_REGEX='(pnpm|npm|yarn|bun|tsc|webpack|vite|jest|vitest|build|test|install|cargo|make|gradle|xcodebuild|docker)'

# Long-running commands (dev servers, watchers) are NEVER throttled: they would
# hold a concurrency slot forever and starve real work. Add your own patterns.
CT_LONGRUN_REGEX='(--watch|[[:space:]]-w([[:space:]]|$)|[[:space:]]watch([[:space:]]|$)|run (dev|start|serve)|[[:space:]]dev([[:space:]]|$)|[[:space:]]serve([[:space:]]|$)|nodemon|next dev|nuxt dev|ng serve|rails (s|server)|artisan serve|flask run|uvicorn|gunicorn|storybook|http-server|live-server)'

# Permission handling for throttled commands:
#   0 = keep your normal Claude Code permission prompts / allow rules (recommended)
#   1 = auto-approve wrapped commands, skipping the prompt (the old behavior)
CT_BYPASS_PERMISSIONS=0

# ---- Layer 1: concurrency throttle -----------------------------------------
# Dynamic concurrency: the live limit scales with free RAM (more free -> more
# parallel heavy commands; less free -> fewer, down to the floor).
CT_DYNAMIC=1            # 1 = scale with memory; 0 = always use CT_MAX_CONCURRENCY
CT_MAX_CONCURRENCY=6    # ceiling (also the fixed value when CT_DYNAMIC=0)
CT_MIN_CONCURRENCY=1    # floor: always allow at least this many (so work never fully stalls)
CT_MEM_PER_SLOT_MB=1500 # assume each concurrent heavy command needs ~this much free RAM
CT_FALLBACK_CONCURRENCY=2 # used only if free memory can't be read
CT_ACQUIRE_TIMEOUT=300  # seconds to wait for a slot before running unthrottled (never deadlock Claude)
CT_POLL=0.3             # base slot-poll interval in seconds (random jitter added)
CT_NICE=10              # nice level applied to wrapped commands
CT_USE_CPULIMIT=0       # set 1 after `brew install cpulimit` to also cap CPU%
CT_CPULIMIT_PCT=300     # cpulimit --limit value (100 = one core) when enabled
CT_PRESTART_WAIT=1      # wait for memory to recover before STARTING a heavy command
CT_PRESTART_TIMEOUT=60  # max seconds to wait in that pre-start gate

# ---- Layer 2: memory watchdog ----------------------------------------------
CT_WATCHDOG_INTERVAL=2  # seconds between checks
CT_CRIT_FREE_PCT=10     # pause heaviest claude descendants when free memory <= this
CT_RESUME_FREE_PCT=25   # resume them when free memory >= this (hysteresis band)
CT_CRIT_LOAD=300        # optional secondary trigger: load1 x100 (300 = 3.00)
CT_CRIT_SUSTAIN=2       # require this many consecutive critical ticks before acting
CT_PAUSE_COUNT=2        # how many of the heaviest processes to pause
CT_MIN_PAUSE_RSS_MB=150 # never pause a process smaller than this
