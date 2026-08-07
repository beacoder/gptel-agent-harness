# python-agent-harness

A Python port of the Emacs [gptel-agent-harness](https://github.com/beacoder/gptel-agent-harness): a minimal-dependency coding agent designed for daily use and easy customization.

## Features

- **Agent loop with FSM supervision** — the model is nudged (max 2) when it
  tries to stop before the task is complete; the nudge counter resets on tool
  calls; tool results are sanitized so a failed call never strands the loop.
- **Context management** — CJK-aware token estimation, per-model context
  windows (deepseek-v4/glm-5.2 1M, gpt-5 400k, kimi-k2.7 256k, claude 200k,
  ...), self-calibrating estimates from API-reported input tokens, and
  automatic compaction at 70% usage that summarizes the conversation and
  resumes with the last user request.
- **Tools** — Agent (sub-agents), TodoWrite, Glob (git-aware), Grep
  (rg → git → grep), Read, Insert, Edit (incl. unified diffs), Write, Mkdir,
  Bash, Skill, Question, PlanExit — all OpenAI-compatible tool schemas.
- **Default agent prompts** — the main agent and sub-agents each get a
  distinct default system prompt bundled with the package
  (`prompts/agent.txt`, `prompts/subagent.txt`), with YAML frontmatter
  stripped. Override the main prompt per-run with `run --system`.
- **Tool cache** — per-file mtime / per-directory TTL validity, write-through
  invalidation on edits, and per-epoch deduplication
  (`[Cached: Read ... — same as earlier call, see above]`).
- **Plan / Build modes** — plan mode is read-only except the per-session
  plan file; PlanExit switches back to build with an "execute the plan"
  prompt; sub-agents in plan mode receive the read-only reminder.
- **Safety** — forbidden paths (default `/mnt/`), catastrophic/destructive/
  dangerous bash pattern tiers, per-session allow/deny memory, 300s command
  timeout, plan-mode read-only bash whitelist, and file snapshots with
  `/undo` `/history`.
- **Sessions** — auto-saved after every response to
  `~/.local/share/python-agent-harness/sessions/`, LLM-generated titles
  (one-shot per session, fired when the FSM run finishes; the file is
  renamed to `<title>_<TS>.md`), `restore` / `restore-latest` /
  `sessions` commands.
- **Commands** — `init` (create/update AGENTS.md), `review` (uncommitted
  changes / commit / branch / PR), `summary`, and custom commands from
  `prompts/commands/*.txt`.
- **Editing input** — `prompt_toolkit`-backed multi-line editor with
  persistent history (Up/Down recall), Enter for a newline, Esc+Enter
  (or Alt+Enter) to submit.
- **Diff rendering** — Edit/Write tool calls capture a unified diff of
  the file change and render it inline (red/green) in the TUI, so file
  edits are visible without leaving the app.

## Install

```sh
python -m venv venv
venv/bin/pip install rich httpx prompt_toolkit
venv/bin/pip install -e python-agent-harness
```

## Configuration

LLM settings live in a JSON config file — no environment variables needed:

```sh
python-agent-harness config --init        # write ~/.config/python-agent-harness/config.json
python-agent-harness config               # show effective settings (API key masked)
```

Edit `~/.config/python-agent-harness/config.json`:

```json
{
  "llm": {
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "sk-...",
    "model": "deepseek-chat",
    "reasoning_effort": "medium"
  }
}
```

`reasoning_effort` is passed to the API as-is (omitted when unset), so you
can use whatever your provider accepts ("low"/"medium"/"high" for OpenAI
and compatible providers). Other optional keys: `backend`, `temperature`,
`max_tokens`, `timeout`.

Precedence: code defaults < config file < `OPENAI_*` environment variables
(env still wins if you set them, but nothing is required).  Use a custom
file with `--config PATH` (also settable via `PYTHON_AGENT_HARNESS_CONFIG`).

## Usage

```sh
python-agent-harness run [project-dir]   # interactive TUI agent
python-agent-harness init [project]      # create/update AGENTS.md
python-agent-harness review [project] [commit|branch|PR]
python-agent-harness sessions            # list saved sessions
python-agent-harness restore --latest    # restore newest session
```

TUI slash commands: `/plan` `/build` `/init` `/review` `/explain`
`/compact` `/undo` `/history` `/save` `/summary` `/clear` `/exit`
(`/explain [project] [target]` explains code — TUI slash command only,
not a CLI subcommand).

Input editing: type your message, press **Enter** for a new line, and
**Esc then Enter** (or **Alt+Enter**) to submit. **Up/Down** recall
previous inputs from `~/.local/share/python-agent-harness/input_history`.
**Ctrl-D** quits; **Ctrl-C** cancels the current input or agent run
without leaving the app — the conversation history is preserved, so you
can immediately ask a follow-up question; a cancelled worker can never
clobber the next run's state (per-run cancellation identity).

## Layout

```
python_agent_harness/
├── agent.py        agent loop (FSM, nudges, compaction)
├── fsm.py          state machine + supervision
├── client.py       OpenAI-compatible streaming client (httpx)
├── tokenizer.py    CJK-aware token estimation + calibration
├── safety.py       path guards + bash policy tiers
├── undo.py         file snapshots / undo
├── cache.py        tool-result cache + dedup
├── planmode.py     build/plan mode + plan file lifecycle
├── compaction.py   compact frame / anchored summary
├── session.py      session persistence + titles
├── harness.py      AgentSession (wiring hub)
├── commands.py     init/review/custom command definitions
├── cli.py          argparse entry points
├── tui.py          rich + prompt_toolkit TUI
├── diffrender.py   unified diff generation + rich rendering
└── tools/          tool implementations + registry
```

## Tests

```sh
venv/bin/python -m unittest discover -s tests -v
```

## Verification checklist (ported semantics)

- [x] Nudge supervision with fail-closed dead-session budget
- [x] Tool-result sanitization (None → error placeholder)
- [x] Compaction: frame, epoch reset, resume last request
- [x] Plan mode: read-only + plan-file writes only
- [x] Bash tiers: catastrophic → plan gate → destructive → dangerous → run
- [x] Cache dedup messages and write-through invalidation
- [x] Session metadata round-trip and title sanitization
- [x] One-shot LLM title generation after the FSM run finishes
- [x] Ctrl-C cancel: stale workers can't clobber the next run's history
