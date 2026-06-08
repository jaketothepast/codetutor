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

This is an early local package. It is designed for stock Emacs and Doom Emacs, with local `codex` and `pi` backends.

## Requirements

- Emacs 28.1 or newer
- Optional but recommended: Emacs 29+ with built-in tree-sitter support
- One local backend:
  - `codex`
  - `pi`

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
(setq codetutor-backend 'auto)        ;; 'auto, 'codex, or 'pi
(setq codetutor-model nil)            ;; nil uses backend default
(setq codetutor-window-width 84)
(setq codetutor-review-on-save t)
(setq codetutor-enable-web-search t)
(setq codetutor-include-open-buffers-on-save t)
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

For Codex, the package uses a read-only sandbox. For pi, it only enables read/search/list tools.

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
