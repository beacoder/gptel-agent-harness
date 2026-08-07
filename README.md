# gptel-agent-harness

An extension to `gptel-agent` that makes it behave like a reliable coding agent (similar to OpenCode).
It adds completion supervision, context management, session persistence, opencode agent and more.

## Features

- **Completion supervision** — Prevents agents from stopping prematurely.
- **Context supervision** — Monitors token usage, auto-compacts when exceeding threshold, self-calibrates estimation using API-reported counts.
- **Session management** — Auto-saves sessions after each response, generates titles, supports restore with live preview.
- **Enhanced tools** — Fast `glob` via `git ls-files`, robust `grep` via `git grep -e`, and a `Question` tool for interactive user input during execution.
- **Tool result caching** — Caches Glob/Grep/Read results with deduplication.
- **Safety layer** — Forbidden-path guards for all file tools, Bash timeout, tiered Bash approval that respects `gptel-confirm-tool-calls`.
- **FSM hardening** — Narrow advice on gptel's state machine so malformed tool calls/results can never wedge a request.
- **Build/Plan mode** — Per-buffer agent modes (default: build), with a `PlanExit` tool for user-approved switch to build.
- **OpenCode agent** — `gptel-opencode-agent` with OpenCode-like behavior, loaded from `gptel-agent-harness-agent-dirs`.
- **Sub-agent model selection** — Enable sub-agents to use a different model than the main agent.
- **Commands** — Project initialization, code review, conversation summary, manual compaction and user-defined commands.

## Installation

```elisp
(require 'gptel-agent-harness)
(gptel-agent-harness-mode 1)
```

## Example Configuration

```elisp
(use-package gptel-agent-harness
  :ensure t
  :config
  (require 'gptel-context)
  ;; MUST add task-completion-rules into llm context
  (gptel-add-file
   (expand-file-name
    "rules/task-completion-rules.md"
    (file-name-directory
     (or (locate-library "gptel-agent-harness")
         (error "gptel-agent-harness not found")))))
  (gptel-agent-harness-mode 1)
  (gptel-agent-update)
  ;; Add custom model context windows
  (add-to-list 'gptel-agent-harness-context-windows
               '("openai/gpt-oss-120b" . 128000))
  (setq gptel-agent-harness-subagent-model "deepseek-v4-flash")   ; cheap model
  (setq gptel-agent-harness-subagent-backend nil)                 ; inherit backend
  (setq gptel-agent-harness-safety-bash-timeout 600)              ; extend timeout to 10 minutes
  ;; Optional keybindings
  (global-set-key (kbd "C-c g a") #'gptel-opencode-agent)
  (global-set-key (kbd "C-c g m") #'gptel-agent-harness-toggle-mode)
  (global-set-key (kbd "C-c g r") #'gptel-agent-harness-commands-review)
  (global-set-key (kbd "C-c g i") #'gptel-agent-harness-commands-initialize)
  (global-set-key (kbd "C-c g u") #'gptel-agent-harness-commands-summary)
  (global-set-key (kbd "C-c g c") #'gptel-agent-harness-commands-compact-buffer)
  (global-set-key (kbd "C-c g s") #'gptel-agent-harness-restore-session)
  (global-set-key (kbd "C-c g l") #'gptel-agent-harness-restore-latest-session))
```

## Completion Supervision

When the agent attempts to stop, the harness injects a nudge message asking it to verify task completion. Configurable via:

- `gptel-agent-harness-max-nudges` — Max consecutive nudges (default: 2). Resets on tool calls.
- `gptel-agent-harness-nudge-message` — Message injected on premature stop.

Only applies to top-level agentic sessions with tools enabled.

## Context Supervision

Estimates token usage before each LLM request. When usage exceeds the threshold, compaction is triggered automatically.

- `gptel-agent-harness-context-trigger` — Ratio threshold (default: 0.70).
- `gptel-agent-harness-context-windows` — Alist of model name patterns to context sizes. Unknown models fall back to 32768.

### Token Calibration

Self-calibrates by comparing heuristic estimates (~4 chars/token Latin, ~2 CJK) against actual API-reported input token counts. Clamped to [0.5, 3.0]. No configuration needed.

### Mode-Line Display

Shows `[Ctx:45%/70%]` color-coded: green (<50%), yellow (50–80%), red (>80%).

- `gptel-agent-harness-show-context-ratio` — Toggle display (default: t).

## Compaction

### Automatic

Triggered when context exceeds `gptel-agent-harness-context-trigger`. The harness:

1. Removes the current round (last response + tool results)
2. Aborts the in-flight request and strips the previous compaction frame (header/separator), leaving any earlier summary as plain text
3. Sends the buffer to the LLM with the compact prompt
4. Rebuilds: header + new summary + separator
5. Re-appends the last real user request (nudge messages excluded) and resumes with `gptel-send`

### Manual

```
M-x gptel-agent-harness-commands-compact-buffer
```

Same summarization logic without interrupting active requests or replaying messages.

### Custom Compaction Engine

The harness uses its own `gptel-agent-harness-commands-compact` instead of
`gptel-agent-compact` from `gptel-agent.el`:

| | Built-in (`gptel-agent-compact`) | Harness version |
|---|---|---|
| Prompt delivery | Reads buffer up to point | Sends content as explicit string |
| Buffer replacement | Narrowing + position tracking | `erase-buffer` + `insert` |
| Transforms | Applies default transforms | None (`:transforms nil`) |
| Error handling | Falls through on non-string | Handles all response types |

The built-in's narrowing/position approach caused issues with repeated compaction (stale markers, partial replacement). The harness version is stateless: send string → receive string → replace buffer.

### Configuration

- `gptel-agent-harness-compact-header` — Header text (default: `"**[Compacted Summary]**\n\n"`).
- `gptel-agent-harness-compact-separator` — Separator text (default: `"\n\n---\n\n**[Context compacted]**\n\n---\n\n"`).
- Compaction prompt: edit `prompts/compact.txt` directly.

## Session Management

Auto-saves after each LLM response. Generates meaningful titles asynchronously.

- `gptel-agent-harness-session-dir` — Storage directory (default: `~/.emacs.d/gptel-sessions/`).
- `gptel-agent-harness-auto-save-session` — Toggle auto-save (default: t).
- `M-x gptel-agent-harness-restore-session` — Restore with live preview.
- `M-x gptel-agent-harness-restore-latest-session` — Restore most recent.

## Commands

| Command | Description |
|---------|-------------|
| `gptel-opencode-agent` | Start an OpenCode-like agent session |
| `gptel-agent-harness-toggle-mode` | Toggle build/plan mode in the current gptel buffer |
| `gptel-agent-harness-set-mode` | Set the agent mode explicitly (`build` or `plan`) |
| `gptel-agent-harness-commands-initialize` | Create/update AGENTS.md for a project |
| `gptel-agent-harness-commands-review` | Code review (uncommitted, commit, branch, or PR) |
| `gptel-agent-harness-commands-summary` | Summarize conversation (full buffer or region) |
| `gptel-agent-harness-commands-compact-buffer` | Manually compact the current buffer |
| `gptel-agent-harness-commands-load-custom` | (Re)discover custom commands from the custom dir |
| `gptel-agent-harness-restore-session` | Restore a saved session |
| `gptel-agent-harness-restore-latest-session` | Restore the most recent session |
| `gptel-agent-harness-undo-last-edit` | Undo the most recent Edit/Write/Insert |
| `gptel-agent-harness-undo-history` | Show the edit snapshot stack |
| `gptel-agent-harness-safety-clear-session` | Reset session Bash allow/deny decisions |
| `gptel-agent-harness-cache-stats` | Show cache hit/miss/dedup counts |
| `gptel-agent-harness-cache-clear` | Clear the cache for the current buffer |

## Sub-Agent Model/Backend

The main agent usually runs a strong (and expensive) model, while `Agent`
tool sub-agents do narrower delegated work where a smaller, cheaper model
suffices. The harness can force a different model and backend onto every
sub-agent request:

- `gptel-agent-harness-subagent-model` — Model for sub-agents (default: `nil`
  = inherit the main agent's model). Set to a string or symbol, e.g.
  `"deepseek-v4-flash"`.
- `gptel-agent-harness-subagent-backend` — Backend name for sub-agents
  (default: `nil` = inherit the main agent's backend), e.g. `"DeepSeek"`.

```elisp
(setq gptel-agent-harness-subagent-model "deepseek-v4-flash")   ; cheap model
(setq gptel-agent-harness-subagent-backend nil)                 ; inherit backend
```

## Custom Commands

Drop a `NAME.txt` prompt file into `gptel-agent-harness-commands-custom-dir`
(default: `prompts/commands/`) and it becomes the interactive command
`gptel-agent-harness-commands-NAME`. The file contents are used as the agent's
system prompt, with two placeholders substituted:

- `${path}` → the current project root
- `$ARGUMENTS` → optional free-text the command reads interactively

Discovery runs when the package loads. After adding or renaming a file, run
`M-x gptel-agent-harness-commands-load-custom` to pick it up without restarting.

- `gptel-agent-harness-commands-custom-dir` — Directory scanned for `*.txt`
  command prompts (default: `prompts/commands/`).
- Names are sanitized to be symbol-safe (`Fix Bug!.txt` → `…-commands-fix-bug`).
- A file whose derived name matches an existing built-in command (e.g.
  `review.txt`) is skipped so built-ins are never clobbered.

An example `explain` command ships in `prompts/commands/explain.txt`.

## Enhanced Tools

- **Glob**: Uses `git ls-files` for `.gitignore`-aware listing; falls back to `tree`.
- **Grep**: Uses `git grep -e` for safe regex; falls back to `rg` or `grep`.
- **Question**: LLM asks user via `completing-read` (single/multi-select, free-text). Encourage usage by adding guidance to your system prompt.
- **PlanExit**: LLM asks the user for approval to leave plan mode. On approval the buffer switches to build mode and the agent starts to execute the approved plan.

## Tool Result Caching

Caches Glob/Grep/Read results per session. Repeated identical calls within the same compaction epoch return a short dedup message instead of full content, saving tokens. Resets on compaction so the LLM gets fresh data in the new context.

Invalidation: file mtime changes, TTL expiry (directories), and write-through on Edit/Write/Insert.

- `gptel-agent-harness-cache-enabled` — Toggle (default: t).
- `gptel-agent-harness-cache-ttl` — TTL for directory entries in seconds (default: 60).
- `gptel-agent-harness-cache-max-entries` — Max entries per session (default: 200).
- `M-x gptel-agent-harness-cache-stats` — Show hit/miss/dedup counts.
- `M-x gptel-agent-harness-cache-clear` — Clear cache for current buffer.

## Safety

The safety layer (`gptel-agent-harness-safety.el`) is enabled automatically by
`gptel-agent-harness-mode`. It adds guards on top of gptel's own tool
confirmation (which still runs first and is controlled by
`gptel-confirm-tool-calls`).

### Forbidden Paths

Read/Glob/Grep/Edit/Insert/Write operations whose expanded path matches
`gptel-agent-harness-safety-forbidden-paths` are rejected with an error before
any side effect. Bash commands are blocked as well: the command is split into
tokens and each is matched as a path, so anchored regexps (the default is
`` \`/mnt/ ``) work on the paths a command references rather than on the raw
command string.

### Bash Timeout

Asynchronous Bash commands are killed after
`gptel-agent-harness-safety-bash-timeout` seconds (default: 300) and report a
timeout error instead of hanging the agent FSM. Set to nil to disable.

### Tiered Bash Approval

Bash commands are classified into three tiers:

| Tier | Examples | Behavior |
|------|----------|----------|
| Catastrophic | `rm -rf /`, `mkfs`, `dd if=`, `shutdown`, `reboot`, `> /dev/sdX` | Always refused, never prompted, cannot be overridden by any setting |
| Destructive | `sudo`, `pkill`, `killall` | Run without prompting; refused only when the approval policy is `block` |
| Dangerous | `rm -rf <dir>`, `git push --force`, `git reset --hard`, `chmod -R 777`, `chown -R`, `su -`, `tar --remove-files` | Subject to the approval policy |

`gptel-agent-harness-safety-bash-approval` (default `confirm`):
- `confirm` — dangerous commands are confirmed with the user, unless
  `gptel-confirm-tool-calls` is nil, in which case the user's opt-out of
  confirmation is respected and the command runs without prompting
  (catastrophic commands are still refused).
- `block` — dangerous and destructive commands are refused without asking.
- nil — no approval prompts at all (catastrophic commands are still refused).

### Session Allow/Deny

When a dangerous command is prompted, `read-multiple-choice` offers:
- `y` — run once
- `n` — deny once
- `a` — always allow this command for the current session
- `d` — always deny this command for the current session

Decisions are remembered per session buffer.
`M-x gptel-agent-harness-safety-clear-session` resets them.

### Edit Undo

Every Edit/Write/Insert tool call snapshots the target file (new files are
recorded so undo can remove them) before modification.
`M-x gptel-agent-harness-undo-last-edit` restores the most recent snapshot;
calling it repeatedly walks back further. If a restore fails the snapshot is
kept so the call can be retried. `M-x gptel-agent-harness-undo-history` shows
the snapshot stack.

- `gptel-agent-harness-safety-undo-depth` — Max snapshots kept per session buffer (default: 50).
- `gptel-agent-harness-safety-backup-dir` — Snapshot storage directory (default: `temporary-file-directory`/`gptel-agent-harness-undo/`).

### Options

- `gptel-agent-harness-safety-forbidden-paths` — Regexps for paths tools must never touch (default: `("\\`/mnt/")`, anchored so unrelated paths containing a `mnt` component are not blocked).
- `gptel-agent-harness-safety-bash-timeout` — Max Bash runtime in seconds (default: 300, nil disables).
- `gptel-agent-harness-safety-bash-approval` — Approval policy: nil / `confirm` / `block`.
- `gptel-agent-harness-safety-bash-dangerous-patterns` — Prompted tier (respects `gptel-confirm-tool-calls`).
- `gptel-agent-harness-safety-bash-destructive-patterns` — Never-prompt tier.
- `gptel-agent-harness-safety-bash-catastrophic-patterns` — Always-blocked tier.

## Build/Plan Mode

Each gptel buffer has an agent mode, `build` or `plan`, defaulting to **build**.
Plan mode is a read-only planning phase: the agent may inspect the codebase and
write its plan to a dedicated plan file, but cannot modify anything else.

### Switching Modes

```
M-x gptel-agent-harness-toggle-mode     ; toggle build ↔ plan
M-x gptel-agent-harness-set-mode RET build|plan   ; set explicitly
```

The mode-line shows `[Build]`/`[Plan]` (with a tooltip) immediately before the
`[Ctx:...]` context indicator.

### Read-Only Enforcement

Edit/Insert/Write/mkdir are refused for every path except the plan file. Bash
is validated per segment (split on `&&`, `||`, `|`, `;`, `&`, newlines): each
segment's first word must be in
`gptel-agent-harness-safety-plan-readonly-bash-commands` and must contain no
mutating construct (redirection, `tee`, `xargs`, `sudo`, mutating `git`
subcommand). Command/process substitution (`$(...)`, backticks, `<(...)`,
`>(...)`) is refused wholesale.

### Options

- `gptel-agent-harness-plan-file-name` — Plan file name (default: `PLAN.md`),
  created in a per-session temp directory so concurrent sessions on the same
  project never share a plan file. Deleted when the session buffer is killed.
- `gptel-agent-harness-plan-mode-subagent-reminder` — READ-ONLY reminder
  template injected into sub-agent requests while plan mode is active (`%s` is
  replaced with the plan file path).
- `gptel-agent-harness-tools-plan-exit-approved-message` — Message queued after
  `PlanExit` approval (`%s` → plan file path).
- `gptel-agent-harness-safety-plan-readonly-bash-commands` — First-word
  whitelist of Bash commands allowed during plan mode.

## FSM Hardening

`gptel-agent-harness-fsm.el` installs four narrow `:around` advices on gptel's
request state machine (enabled/disabled with the minor mode; upstream files are
never modified). Without them, a malformed tool call or a missing tool result
can leave a request wedged mid-transition or make the backend reject the
conversation.

| Advice | Target | Effect |
|---|---|---|
| U1 | `gptel--map-tool-args` | Non-plist tool `:args` normalized to nil instead of throwing `wrong-type-argument` |
| U2 | `gptel--handle-tool-use` | Handler errors fail all pending tool calls, so the FSM leaves `TOOL` |
| U3 | `gptel--process-tool-call` | Result processing is idempotent — first result wins, duplicates are no-ops |
| U4 | `gptel--handle-tool-result` | Non-string/missing `:result` coerced to a string (avoids `{}` content rejected by OpenAI/Ollama/Gemini/Bedrock); handler errors still transition out of `TRET` |

## Miscellaneous Options

- `gptel-agent-harness-verbose` — Log harness actions (nudges, compaction,
  calibration, injection, FSM recoveries) via `message` (default: nil). Also
  enables the `*gptel-agent-harness-debug*` token-estimation dump.
- `gptel-agent-harness-agent-dirs` — Directories scanned for agent definition
  files (default: `agents/`).
- `gptel-agent-harness-preview-lines` — Lines shown in the session restore
  preview (default: 40).

## File Structure

```
site-lisp/
├── gptel-agent-harness.el          # Core: FSM supervision, context, compaction
├── gptel-agent-harness-cache.el    # Tool result caching with deduplication
├── gptel-agent-harness-safety.el   # Safety: path guards, Bash approval, edit undo
├── gptel-agent-harness-fsm.el      # FSM hardening advice on upstream gptel
├── gptel-agent-harness-session.el  # Session: auto-save, restore, preview
├── gptel-agent-harness-tools.el    # Enhanced tools + Question/PlanExit tools
├── gptel-agent-harness-agent.el    # Agent definition (gptel-opencode-agent)
├── gptel-agent-harness-commands.el # Commands (init, review, summary, compact)
├── gptel-agent-harness-test.el     # ERT tests: core supervision/context/commands
├── gptel-agent-harness-extra-test.el # ERT tests: safety, tools, cache
├── prompts/                        # Prompt templates
│   └── commands/                   # Auto-discovered custom command prompts
├── rules/                          # Agent rules (task-completion-rules.md)
└── agents/                         # Agent definition files
```

## Requirements

- Emacs 29.1+, gptel-agent >= 0.0.1, compat >= 30.1.0.0
- Optional: `git`, `tree`, `ripgrep`

## License

GPL-3.0-or-later
