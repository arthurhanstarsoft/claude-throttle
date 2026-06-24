# claude-throttle config (Windows) — dot-sourced PowerShell. Copied to
# %USERPROFILE%\.config\claude-throttle\config.ps1 at install time. Edits take
# effect on the next command / watchdog tick. Deleting a line falls back to the
# built-in default. Editing this file is running code (same trust model as the
# bash config.sh).

$CT_ENABLED            = 1          # master switch: 0 disables hook, wrapper AND watchdog
$CT_GATE_MODE          = 'heavy'    # heavy = only wrap heavy commands; all = wrap everything
$CT_HEAVY_REGEX        = '(pnpm|npm|yarn|bun|tsc|webpack|vite|jest|vitest|build|test|install|cargo|make|gradle|msbuild|dotnet|docker)'
# .NET regex (use \s, not POSIX [[:space:]]). Dev servers / watchers are NEVER throttled.
$CT_LONGRUN_REGEX      = '(--watch|\s-w(\s|$)|\swatch(\s|$)|run (dev|start|serve)|\sdev(\s|$)|\sserve(\s|$)|nodemon|next dev|nuxt dev|ng serve|rails (s|server)|artisan serve|flask run|uvicorn|gunicorn|storybook|http-server|live-server)'
$CT_BYPASS_PERMISSIONS = 0          # 1 = auto-approve wrapped commands (skip the prompt)

# ---- Layer 1: concurrency throttle ----
$CT_DYNAMIC            = 1          # 1 = scale with free RAM; 0 = fixed at CT_MAX_CONCURRENCY
$CT_MAX_CONCURRENCY    = 6          # ceiling
$CT_MIN_CONCURRENCY    = 1          # floor (work never fully stalls)
$CT_MEM_PER_SLOT_MB    = 1500       # assume each heavy command needs ~this much free RAM
$CT_FALLBACK_CONCURRENCY = 2        # used only if free memory can't be read
$CT_ACQUIRE_TIMEOUT    = 300        # seconds to wait for a slot before running unthrottled
$CT_POLL               = 0.3        # base slot-poll interval (seconds; jitter added)
$CT_PRESTART_WAIT      = 1          # wait for memory to recover before STARTING a heavy command
$CT_PRESTART_TIMEOUT   = 60
$CT_PRIORITY_CLASS     = 'BelowNormal'  # priority for wrapped commands ('' to disable); Windows analog of nice
$CT_INNER_SHELL        = ''         # '' = auto (bash.exe if present, else cmd); or 'bash' / 'cmd'

# ---- Layer 2: memory watchdog ----
$CT_MEM_METRIC         = 'available'  # 'available' (recommended) or 'free' (FreePhysicalMemory)
$CT_WATCHDOG_INTERVAL  = 2
$CT_CRIT_FREE_PCT      = 10         # pause heaviest claude descendants when free <= this
$CT_RESUME_FREE_PCT    = 25         # resume when free >= this (hysteresis)
$CT_CRIT_SUSTAIN       = 2          # consecutive critical ticks before acting
$CT_PAUSE_COUNT        = 2          # how many of the heaviest to pause
$CT_MIN_PAUSE_RSS_MB   = 150        # never pause a process smaller than this
