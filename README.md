# CodeTutor

CodeTutor is an Emacs package for learning while you code. It opens a right-side tutor panel, watches file saves, gathers project context, and asks a local AI assistant to respond like a senior/staff engineer pair-programming tutor.

The important boundary: CodeTutor helps you write the code. It does not write into your project files for you.

It can:

- review what changed after a save
- explain the concept behind feedback
- show compact illustrative code samples
- recommend the best next step
- answer minibuffer prompts
- answer follow-up questions using recent conversation turns
- keep durable architecture notes in `.codetutor/ARCHITECTURE.md`

It should not:

- edit your source files
- produce patches
- produce full-file replacements
- hand you a complete ready-to-paste implementation for the exact task

## Status

This is an early package. It is designed for stock Emacs and Doom Emacs, with local `codex` and `pi` backends and an optional remote Fireworks AI backend.

## Requirements

- Emacs 28.1 or newer
- Optional but recommended: Emacs 29+ with built-in tree-sitter support
- One backend:
  - `codex` (local, read-only sandbox)
  - `pi` (local, read-only tools)
  - Fireworks AI (remote HTTP API via `curl`, plus an API key; optional `rg` for the search tool)

CodeTutor degrades gracefully when tree-sitter is not available by using `imenu` where possible.

## Install

### Stock Emacs

```elisp
(add-to-list 'load-path "/Users/jacobwindle/Projects/codetutor")
(require 'codetutor)

(setq codetutor-backend 'auto)
(codetutor-mode 1)
```

### Doom Emacs

Add the local package:

```elisp
;; ~/.config/doom/packages.el
(package! codetutor
  :recipe (:local-repo "~/Projects/codetutor"))
```

Configure it:

```elisp
;; ~/.config/doom/config.el
(use-package! codetutor
  :commands (codetutor-open
             codetutor-what-next
             codetutor-ask
             codetutor-follow-up
             codetutor-refresh-architecture-memory)
  :init
  (setq codetutor-backend 'auto
        codetutor-open-on-enable nil
        codetutor-start-session-on-open t
        codetutor-review-on-save t)
  :config
  (codetutor-mode 1))
```

Then run:

```sh
~/.config/emacs/bin/doom sync
```

Restart Emacs after syncing.

## Commands

| Command | Keybinding | What It Does |
| --- | --- | --- |
| `codetutor-mode` | none | Enables/disables global CodeTutor hooks. |
| `codetutor-open` | `C-c t o` | Opens the side panel and starts a project assessment. |
| `codetutor-what-next` | `C-c t n` | Asks for the single best next step. |
| `codetutor-ask` | `C-c t a` | Prompts from the minibuffer with current file/project context. |
| `codetutor-follow-up` | `C-c t f` | Asks a follow-up about the previous answer using recent turns. |
| `codetutor-refresh-architecture-memory` | `C-c t m` | Asks the tutor to refresh durable architecture notes. |
| `codetutor-new-spec` | `C-c t s` | Starts a new feature spec and opens the spec workbench. |
| `codetutor-open-spec` | `C-c t S` | Opens an existing spec as the active spec. |
| `codetutor-finish-spec` | none | Clears the active spec. |
| `codetutor-scratch` | `C-c t t` | Opens the scratch buffer to think out loud while building. |

## How It Works

CodeTutor has four core loops: startup assessment, save review, manual prompt, and follow-up.

### Startup Assessment

When you run `M-x codetutor-open`, CodeTutor:

1. Detects the project root.
2. Opens a right-side panel.
3. Gathers project context.
4. Starts a read-only backend request.
5. Replaces the panel with `Status: thinking`.
6. Replaces that status with the final tutor answer.

The startup answer should tell you where to begin, what to learn first, and what engineering judgment matters before writing code.

### Save Review

When `codetutor-mode` and `codetutor-review-on-save` are enabled, CodeTutor hooks into Emacs saves:

1. `before-save-hook` reads the current on-disk file.
2. The save happens normally.
3. `after-save-hook` compares the previous on-disk contents with the saved buffer text.
4. CodeTutor builds a unified diff.
5. CodeTutor sends the diff plus project context to the backend.
6. The side panel shows `Status: thinking`.
7. The side panel is replaced with the final teaching response.

Save reviews are proportional to the diff. The tutor should focus on concept, risk, architecture, tests, and one next move.

### Manual Prompt

`M-x codetutor-ask` prompts from the minibuffer. It includes:

- the current file
- tree-sitter or imenu outline
- project context
- architecture memory
- project file index
- recent conversation turns

The backend may inspect/search other project files through read-only tools when supported.

### Follow-Up

`M-x codetutor-follow-up` asks a question about the previous answer. It does not display the prompt in the side panel.

Follow-ups include recent private conversation turns, so you can ask things like:

```text
Can you show me a smaller example?
```

or:

```text
What would the test shape look like?
```

The follow-up still includes current file and project context, so the tutor can connect the prior answer to where you are now.

### What Next

`M-x codetutor-what-next` asks the tutor to inspect available context and recommend one best next step.

This is useful when you are between implementation slices and want a senior engineer's judgment on what to do next.

### Architecture Memory

The tutor is asked to include durable architecture observations in a fenced block:

````markdown
```codetutor-memory
- Boundary: The editor integration owns context gathering; the backend owns tutoring.
```
````

CodeTutor extracts those lines and appends new ones to:

```text
.codetutor/ARCHITECTURE.md
```

That memory file is the only project file CodeTutor writes automatically.

## Context Sources

CodeTutor builds a prompt from several local sources.

| Source | When Included | Purpose |
| --- | --- | --- |
| `PROJECT.md`, `Project.md`, `project.md` | Every request | Product/project direction. |
| `spec/` | Every request | Specs, requirements, design notes. |
| `.codetutor/ARCHITECTURE.md` | Every request when present | Durable project memory. |
| Current file text | Every request | What you are actively editing. |
| Tree-sitter summary | Every request when available | Syntax-level outline of the current buffer. |
| Imenu summary | Fallback when tree-sitter is unavailable | Lightweight outline. |
| Project file index | Every request | Helps the tutor decide what else to inspect. |
| Diff since last save | Save reviews | The actual change being reviewed. |
| Other open project buffers | Save reviews | Nearby work you already have open. |
| Recent conversation turns | Follow-ups and later prompts | Continuity across questions. |

Open-buffer context is capped so a large Emacs session does not overwhelm the backend.

## Backends

### Codex

The Codex backend uses `codex exec` non-interactively. It is configured with:

- read-only sandbox
- approval policy `never`
- ephemeral session
- no terminal color
- optional web search
- `--output-last-message` so the panel displays only the final answer

The command is built roughly like this:

```sh
codex \
  --sandbox read-only \
  --ask-for-approval never \
  --search \
  exec \
  -C "$PROJECT_ROOT" \
  --skip-git-repo-check \
  --color never \
  --ephemeral \
  --output-last-message "$TEMP_FILE" \
  -
```

### pi

The pi backend uses non-interactive print mode with only read-only tools:

```sh
pi --print --tools read,grep,find,ls
```

It can inspect files, but should not write or edit them.

### Fireworks AI

The Fireworks backend talks to the [Fireworks AI](https://fireworks.ai/) OpenAI-compatible HTTP API with `curl`. Use it when you do not have a local `codex` or `pi` CLI.

It is **remote**: CodeTutor sends the gathered context (project files, current buffer, diffs, and architecture memory) to Fireworks. For that reason, `codetutor-backend 'auto` never selects it. You must opt in:

```elisp
(setq codetutor-backend 'fireworks)
```

Provide an API key in one of these ways (checked in order):

```elisp
;; 1. A custom variable (least preferred; avoid committing it):
(setq codetutor-fireworks-api-key "fw_...")
```

```sh
# 2. An environment variable:
export FIREWORKS_API_KEY=fw_...
```

```text
# 3. An auth-source entry, e.g. in ~/.authinfo.gpg:
machine api.fireworks.ai password fw_...
```

The key is written to a `curl --config` file rather than passed as a command-line argument, so it does not appear in the process list.

The request is built roughly like this:

```sh
curl --silent --show-error --fail-with-body \
  --config "$CONFIG_WITH_AUTH_HEADER" \
  --header "Content-Type: application/json" \
  --data @"$BODY_JSON" \
  https://api.fireworks.ai/inference/v1/chat/completions
```

Configure the model with `codetutor-fireworks-model` (or the generic `codetutor-model`); the default is `accounts/fireworks/models/glm-5p2`. Fireworks model identifiers are account-scoped paths such as `accounts/fireworks/models/<model>`. The serverless catalog rotates, so update the model if it starts returning a 404.

#### Agentic tools

By default (`codetutor-fireworks-use-tools` is `t`), the Fireworks backend does **not** receive one giant pre-packed prompt. Instead it gets a lean seed (the task, the current-file outline, the save diff, and the file index) plus a set of **read-only tools**, and it *pulls* the context it needs in an agentic loop — the way a senior engineer explores a codebase:

| Tool | What it returns |
| --- | --- |
| `read_file` | A project file, optionally a line range. |
| `list_directory` | Directory entries (ignored dirs omitted). |
| `read_project_context` | `PROJECT.md`, `spec/`, and architecture memory. |
| `read_current_file` | The file/buffer that triggered the request. |
| `project_symbol_table` | A project-wide tree-sitter index of top-level symbols with file/line. |
| `search_project` | Regex search results (`rg`, or `grep` fallback). |

The loop runs as a sequence of Fireworks calls: the model requests tools, CodeTutor executes them locally and feeds back the results, and it repeats until the model answers or hits `codetutor-fireworks-max-tool-iterations` (default 8). Every tool is **read-only and sandboxed to the project root** — paths that escape the root (via `..` or absolute paths) are refused. The model can read your project but cannot modify it; the only automatic write remains `.codetutor/ARCHITECTURE.md`.

The project symbol table is built with tree-sitter (no new dependencies) and cached per session; it is rebuilt when you run `codetutor-refresh-architecture-memory`. Files whose tree-sitter grammar is not installed are skipped, and the count is reported.

Set `codetutor-fireworks-use-tools` to `nil` to fall back to the single-shot pre-packed prompt (the same shape `codex`/`pi` receive).

#### Cost reporting

Because each tool round is a separately billed Fireworks call, CodeTutor sums token usage across the whole loop and prints a line to the **minibuffer** when a request finishes (the panel stays answer-only):

```text
CodeTutor: 15,212 tokens (8,901 in / 6,311 out) · 3 tool calls · ~$0.0142 · session 41,330 tokens (~$0.039)
```

The `~$` figures appear only when you set both price customs to your current rates (Fireworks per-model pricing rotates):

```elisp
(setq codetutor-fireworks-cost-input-per-million 0.9
      codetutor-fireworks-cost-output-per-million 0.9)
```

With the prices unset, the line shows token counts only. Disable the report entirely with `(setq codetutor-show-cost nil)`.

## Spec development mode

Spec mode turns CodeTutor into a thinking partner for *starting* a feature, not
just reviewing code. `M-x codetutor-new-spec` asks for a name, creates
`spec/<slug>.md` from a teaching template, and opens a two-pane workbench — the
spec document on top, the tutor panel below — then kicks off a proactive
interview ("what problem does this solve, and for whom?").

It is **teach-only**, end to end. The tutor never writes your spec or your code;
it interviews you, critiques what you wrote, names the gaps (missing requirements,
edge cases, non-goals), and teaches you how to actually *build* the feature.

### The template teaches first

A new spec opens pre-filled with sections, each carrying a guiding comment you
replace:

```markdown
## Requirements (acceptance criteria)
<!-- Concrete, testable statements. "Given/when/then" works well. -->
```

The sections are Problem / Goals / Non-goals / Requirements / Design / Build plan
/ Open questions / Risks. Customize the scaffold with `codetutor-spec-template`.

### The loop, from idea to built software

Once a spec is **active**, it becomes the lens for everything (the only state is a
single in-session pointer; the doc itself is the source of truth, re-parsed each
request):

- **Save a spec file** → the tutor reviews *the section you just edited*, names
  what's missing, and points you to the next empty section.
- **Save a code file while a spec is active** → the tutor teaches the change
  *against the spec*: which requirement it advances, the next build slice, and the
  test that would prove it.
- **`M-x codetutor-what-next`** with a spec active → teaches the next build slice.
- **`M-x codetutor-finish-spec`** → code saves return to the normal review posture.

So the spec is the throughline: idea → requirements → design → build plan →
implementation, with the tutor teaching the judgment at each step (including how
to decompose work into slices — it critiques your slices, it doesn't write them).

### Customization

```elisp
(setq codetutor-spec-window-height 0.4   ;; tutor panel height (lines or fraction)
      codetutor-spec-kickoff t           ;; proactive interview on new spec
      codetutor-spec-directory "spec")   ;; where specs live (already in context)
```

## Scratch buffer (think out loud)

When you don't want the ceremony of a spec and just want to *build*, `M-x
codetutor-scratch` (`C-c t t`) opens the **CodeTutor scratch buffer** — a freeform
place to jot thoughts, notes, and questions while you implement, with the tutor
panel below. Type whatever you're thinking, then:

| Key | Action |
| --- | --- |
| `C-x C-s` / `C-c C-c` | Submit your thoughts to the tutor (teach-only) |
| `C-c C-k` | Clear the scratch buffer |

The scratch buffer is **ephemeral** — it never touches disk — but it persists for
the session and remembers what you've written until you clear it (like Emacs'
`*scratch*`).

### Pinned context

Both the scratch buffer and any open **spec** documents are *pinned*: while they
have content, they are inserted into **every** tutor request as clearly labeled
sections (`SCRATCH — …`, `PINNED SPEC DOCUMENT — …`), so the tutor always has your
current thinking and working spec in view — not buried as generic context. Open
spec buffers are pinned with their **live, unsaved** text, so the tutor sees what
you're typing, not just what's on disk.

Pinning is teach-only like everything else: the tutor responds to your notes and
teaches the next move; it never writes the code. The pinned scratch is capped by
`codetutor-scratch-max-bytes` so a long thinking session can't bloat every
request.

## Output Model

The side panel is intentionally not a chat transcript.

For every request, CodeTutor:

1. Clears the panel.
2. Shows `Status: thinking`.
3. Runs the backend.
4. Extracts the final answer.
5. Clears the panel again.
6. Shows only the answer.

The panel should not show:

- your prompt text
- generated prompt metadata
- full project context
- file contents sent as context
- backend progress output
- CLI transcripts

The tutor is asked to wrap visible answers in:

```html
<codetutor-answer>
...
</codetutor-answer>
```

CodeTutor extracts that block when present and strips architecture memory blocks from the visible panel output.

## Teaching Posture

The built-in prompt tells the tutor to:

- teach underlying concepts
- guide the user toward the solution
- ask useful questions
- give one concrete next move
- include compact code samples when they clarify the idea
- explain how to adapt examples instead of handing over final code
- avoid patches, full-file replacements, and complete ready-to-paste implementations

Good CodeTutor output should feel like a senior engineer pairing with you, not like an autocomplete engine.

## Customization

Common settings:

```elisp
(setq codetutor-backend 'auto)        ;; 'auto, 'codex, 'pi, or 'fireworks
(setq codetutor-model nil)            ;; nil uses backend default
(setq codetutor-window-width 84)
(setq codetutor-review-on-save t)
(setq codetutor-enable-web-search t)
(setq codetutor-include-open-buffers-on-save t)
```

Fireworks AI backend:

```elisp
(setq codetutor-fireworks-api-key nil)  ;; nil resolves env/auth-source
(setq codetutor-fireworks-model "accounts/fireworks/models/glm-5p2")
(setq codetutor-fireworks-api-base "https://api.fireworks.ai/inference/v1")
(setq codetutor-fireworks-max-tokens 2048)
(setq codetutor-fireworks-temperature 0.3)
```

Fireworks agentic tools and cost:

```elisp
(setq codetutor-fireworks-use-tools t)          ;; nil = single-shot prompt
(setq codetutor-fireworks-max-tool-iterations 8)
(setq codetutor-tool-max-output-bytes 20000)    ;; per-tool result cap
(setq codetutor-symbol-table-max-files 400)
(setq codetutor-search-command "rg")            ;; falls back to grep
(setq codetutor-show-cost t)
(setq codetutor-fireworks-cost-input-per-million nil)   ;; set for $ estimates
(setq codetutor-fireworks-cost-output-per-million nil)
```

Context limits:

```elisp
(setq codetutor-max-project-context-bytes 80000)
(setq codetutor-max-current-file-bytes 50000)
(setq codetutor-max-diff-bytes 60000)
(setq codetutor-max-open-buffers 12)
(setq codetutor-max-open-buffer-bytes 20000)
(setq codetutor-max-open-buffer-context-bytes 80000)
(setq codetutor-max-conversation-turns 8)
(setq codetutor-max-conversation-bytes 30000)
```

Prompt customization:

```elisp
(setq codetutor-system-prompt
      "You are my read-only staff engineer tutor...")
```

## Safety Boundaries

CodeTutor has two layers of protection:

1. Prompt-level boundaries tell the tutor not to edit files or produce patches.
2. Backend command boundaries use read-only modes/tools where available.

For Codex, the package uses a read-only sandbox. For pi, it only enables read/search/list tools. For Fireworks AI, the agentic tools are all read-only and **sandboxed to the project root** — `read_file`/`list_directory`/`search_project` refuse paths that escape the root, there are no write or shell tools, and `search_project` passes its pattern as an argument (never through a shell). Because Fireworks is remote, the context the model fetches leaves your machine, so the backend is never chosen automatically and must be selected explicitly.

The only automatic write CodeTutor performs itself is `.codetutor/ARCHITECTURE.md`.

## Troubleshooting

### The panel shows backend errors

Run the backend directly:

```sh
codex doctor
codex exec --help
pi --help
```

Confirm the command-line flags in your installed version match what CodeTutor uses.

### I see prompt/context instead of just the answer

CodeTutor prefers Codex's `--output-last-message` file and extracts `<codetutor-answer>` blocks when present. If a backend still echoes context, use the Codex backend or adjust `codetutor-system-prompt` to reinforce the output contract.

### Save reviews are too large

Lower these limits:

```elisp
(setq codetutor-max-diff-bytes 30000)
(setq codetutor-max-open-buffers 6)
(setq codetutor-max-open-buffer-context-bytes 40000)
```

### I do not want automatic save reviews

```elisp
(setq codetutor-review-on-save nil)
```

You can still use `codetutor-ask`, `codetutor-follow-up`, and `codetutor-what-next`.

## Development

Run tests:

```sh
emacs --batch -L . -l test/codetutor-test.el -f ert-run-tests-batch-and-exit
```

Byte compile:

```sh
emacs --batch -L . -f batch-byte-compile codetutor.el
```

Remove generated bytecode before committing:

```sh
rm -f codetutor.elc
```

## Files

```text
codetutor.el                 Package implementation
codetutor-pkg.el             Package metadata
PROJECT.md                   Project direction consumed by CodeTutor
spec/initial-behavior.md     Initial behavior spec
test/codetutor-test.el       ERT regression tests
README.md                    User and developer guide
```
