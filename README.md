# CodeTutor

CodeTutor is an Emacs package for learning while you code. It opens a right-side tutor buffer, watches file saves, sends a diff of what changed, and asks a local AI assistant to teach concepts, architecture, testing, and engineering judgment without writing the code for you.

It can use local `codex` or `pi`:

- `codex exec` runs with a read-only sandbox and `--ask-for-approval never`.
- `pi --print` runs with only `read`, `grep`, `find`, and `ls` tools enabled.

## Install

Stock Emacs:

```elisp
(add-to-list 'load-path "/Users/jacobwindle/Projects/codetutor")
(require 'codetutor)
(setq codetutor-backend 'auto)
(codetutor-mode 1)
```

Doom Emacs with a local package recipe:

```elisp
;; packages.el
(package! codetutor :recipe (:local-repo "/Users/jacobwindle/Projects/codetutor"))

;; config.el
(use-package! codetutor
  :config
  (setq codetutor-backend 'auto)
  (codetutor-mode 1))
```

Doom Emacs with direct load path:

```elisp
;; config.el
(add-to-list 'load-path "/Users/jacobwindle/Projects/codetutor")
(require 'codetutor)
(setq codetutor-backend 'auto)
(codetutor-mode 1)
```

## Commands

- `M-x codetutor-mode`: enable the global tutor mode.
- `M-x codetutor-open`: open the right-side tutor tray and start a project assessment.
- `M-x codetutor-what-next`: ask the tutor to inspect/search context and recommend the best next step.
- `M-x codetutor-ask`: prompt the tutor from the minibuffer with the current file included as context.
- `M-x codetutor-follow-up`: ask a follow-up about the previous answer using recent private conversation turns.
- `M-x codetutor-refresh-architecture-memory`: refresh `.codetutor/ARCHITECTURE.md`.

Default keybindings while `codetutor-mode` is enabled:

- `C-c t o`: open tutor.
- `C-c t n`: what next.
- `C-c t a`: ask from minibuffer.
- `C-c t f`: ask a follow-up.
- `C-c t m`: refresh architecture memory.

## Project Context

CodeTutor loads these from the project root:

- `PROJECT.md`, `Project.md`, or `project.md`
- files under `spec/` matching common text/spec extensions
- `.codetutor/ARCHITECTURE.md`
- a project file index
- the current file text and tree-sitter/imenu outline
- the diff since last save
- other open file-backed project buffers during save reviews
- recent private conversation turns for follow-up requests

The side tray shows a single current response. Requests clear the tray to
`Status: thinking`, then replace that status with the final tutor answer. The
prompt, project context, file contents, and backend transcript are not shown in
the tray.

Project root detection uses Emacs `project.el` first, then falls back to locating `.git`, project context files, or `spec/`.

## Teaching Posture

The built-in prompt tells the tutor to:

- never edit files
- never output patches, full-file replacements, or complete ready-to-paste implementations
- include short illustrative code samples when they teach the concept or API shape
- teach the concept behind feedback
- ask guiding questions
- give one concrete next move
- maintain durable architecture memory in `.codetutor/ARCHITECTURE.md`

The package writes only its own memory file. The AI backend is configured to be read-only.

## Customization

```elisp
(setq codetutor-backend 'codex)       ;; 'auto, 'codex, or 'pi
(setq codetutor-model "gpt-5")        ;; optional
(setq codetutor-window-width 90)
(setq codetutor-review-on-save t)
(setq codetutor-include-open-buffers-on-save t)
(setq codetutor-enable-web-search t)
```

The main prompt is customizable:

```elisp
(setq codetutor-system-prompt
      "You are my read-only staff engineer tutor...")
```

## Tests

Run:

```sh
emacs --batch -L . -l test/codetutor-test.el -f ert-run-tests-batch-and-exit
emacs --batch -L . -f batch-byte-compile codetutor.el
```
