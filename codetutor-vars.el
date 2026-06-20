;;; codetutor-vars.el --- Customization and state for CodeTutor -*- lexical-binding: t; -*-

;; This file is part of CodeTutor; see codetutor.el for the package header.

;;; Commentary:

;; Defines the `codetutor' customization group, all user options, the
;; system prompt, the major-mode/tree-sitter language map, and the
;; package's mutable session-state variables.  This is the foundation
;; module: every other CodeTutor file requires it.

;;; Code:

(require 'subr-x)

(defgroup codetutor nil
  "A read-only senior engineer tutor for Emacs."
  :group 'tools
  :prefix "codetutor-")

(defcustom codetutor-backend 'auto
  "Backend used for tutor requests.

`auto' prefers Codex when available, then pi.dev.  `codex' uses
`codex exec' with a read-only sandbox.  `pi' uses `pi --print'
with only read/grep/find/ls tools enabled.  `fireworks' sends the
gathered context to the Fireworks AI HTTP API over `curl'.

`auto' never selects `fireworks': the remote backend transmits project
files, diffs, and architecture memory off the machine, so it must be
chosen explicitly."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Codex CLI" codex)
                 (const :tag "pi.dev CLI" pi)
                 (const :tag "Fireworks AI" fireworks)))

(defcustom codetutor-codex-command "codex"
  "Command used to run the Codex CLI."
  :type 'string)

(defcustom codetutor-pi-command "pi"
  "Command used to run the pi.dev CLI."
  :type 'string)

(defcustom codetutor-fireworks-command "curl"
  "Command used to send Fireworks AI requests.

CodeTutor talks to Fireworks over its OpenAI-compatible HTTP API.  Only
`curl' is supported."
  :type 'string)

(defcustom codetutor-fireworks-api-base "https://api.fireworks.ai/inference/v1"
  "Base URL for the Fireworks AI OpenAI-compatible API.

The chat-completions endpoint is derived by appending
`/chat/completions' to this value."
  :type 'string)

(defcustom codetutor-fireworks-model "accounts/fireworks/models/glm-5p2"
  "Default Fireworks AI model used when `codetutor-model' is nil.

Fireworks model identifiers are account-scoped paths such as
`accounts/fireworks/models/<model>'.  The serverless catalog rotates, so
update this if the model starts returning a 404."
  :type 'string)

(defcustom codetutor-fireworks-api-key nil
  "Fireworks AI API key, or nil to resolve it elsewhere.

When nil, CodeTutor reads the FIREWORKS_API_KEY environment variable and
then falls back to `auth-source' (host `api.fireworks.ai').  Prefer the
environment variable or `auth-source' over storing the key here."
  :type '(choice (const :tag "Resolve from environment or auth-source" nil)
                 string))

(defcustom codetutor-fireworks-max-tokens 2048
  "Maximum number of tokens Fireworks AI may generate per response."
  :type 'integer)

(defcustom codetutor-fireworks-temperature 0.3
  "Sampling temperature for Fireworks AI requests."
  :type 'number)

(defcustom codetutor-fireworks-use-tools t
  "Whether the Fireworks AI backend may pull context with read-only tools.

When non-nil, CodeTutor runs an agentic loop: it sends a lean prompt plus a
set of read-only tools and lets the model fetch project context on demand
\(files, directories, a project symbol table, and search).  When nil, the
Fireworks backend uses the single-shot path that pre-packs all context into
one prompt, like the `codex' and `pi' backends."
  :type 'boolean)

(defcustom codetutor-fireworks-max-tool-iterations 8
  "Maximum number of tool-call rounds in a Fireworks agentic request.

Each round is a separately billed Fireworks call, so this caps token spend
and prevents runaway loops.  On reaching the cap, CodeTutor asks for a final
answer without further tools."
  :type 'integer)

(defcustom codetutor-tool-max-output-bytes 20000
  "Maximum number of bytes returned to the model from a single tool call."
  :type 'integer)

(defcustom codetutor-cache-tool-results t
  "Whether the project symbol table is cached until project files change.

When non-nil, `project_symbol_table' reuses its cached tree-sitter parse while
the project's file modification times are unchanged, rebuilding only when a
file changes.  Set to nil to always rebuild."
  :type 'boolean)

(defcustom codetutor-symbol-table-max-files 400
  "Maximum number of project files scanned for the project symbol table."
  :type 'integer)

(defcustom codetutor-search-command "rg"
  "Command used by the `search_project' tool.

When this command is not found, CodeTutor falls back to `grep'."
  :type 'string)

(defcustom codetutor-show-cost t
  "Whether to report Fireworks token usage and cost in the minibuffer."
  :type 'boolean)

(defcustom codetutor-fireworks-cost-input-per-million nil
  "US dollars per one million Fireworks prompt (input) tokens, or nil.

When this and `codetutor-fireworks-cost-output-per-million' are both set,
CodeTutor includes an estimated dollar cost in the usage report.  Fireworks
serverless pricing rotates per model, so set this to your current rate."
  :type '(choice (const :tag "Unknown (tokens only)" nil)
                 number))

(defcustom codetutor-fireworks-cost-output-per-million nil
  "US dollars per one million Fireworks completion (output) tokens, or nil.

See `codetutor-fireworks-cost-input-per-million'."
  :type '(choice (const :tag "Unknown (tokens only)" nil)
                 number))

(defcustom codetutor-model nil
  "Optional model name passed to the selected backend.

When nil, the backend default is used."
  :type '(choice (const :tag "Backend default" nil)
                 string))

(defcustom codetutor-enable-web-search t
  "Whether Codex requests should enable web search.

This only affects the Codex backend.  pi.dev provider behavior depends on
the pi.dev configuration."
  :type 'boolean)

(defcustom codetutor-panel-side 'bottom
  "Frame edge where the CodeTutor panel docks for normal requests.

`bottom' mirrors the spec/scratch workbench layout (a panel docked along
the bottom of the frame).  `right' uses a vertical side window the width of
`codetutor-window-width'."
  :type '(choice (const :tag "Bottom" bottom)
                 (const :tag "Right" right)))

(defcustom codetutor-panel-height 0.4
  "Height of the CodeTutor panel when it docks at the bottom.

An integer is a number of lines; a float is a fraction of the frame height."
  :type '(choice integer float))

(defcustom codetutor-window-width 84
  "Width of the CodeTutor panel when `codetutor-panel-side' is `right'.

When this is an integer, it is treated as a number of columns.  When this
is a float, it is treated as a fraction of the current frame width."
  :type '(choice integer float))

(defcustom codetutor-open-on-enable t
  "Whether `codetutor-mode' should open the side panel immediately."
  :type 'boolean)

(defcustom codetutor-start-session-on-open t
  "Whether `codetutor-open' should run a startup assessment for the project."
  :type 'boolean)

(defcustom codetutor-review-on-save t
  "Whether CodeTutor should review the diff after each file save."
  :type 'boolean)

(defcustom codetutor-skip-auto-request-while-busy t
  "Whether automatic save reviews should be skipped when a request is running.

Manual requests cancel the running request and start the new one."
  :type 'boolean)

(defcustom codetutor-project-files '("PROJECT.md" "Project.md" "project.md")
  "Project-root files loaded into tutor context."
  :type '(repeat string))

(defcustom codetutor-spec-directory "spec"
  "Project-root directory loaded into tutor context."
  :type 'string)

(defcustom codetutor-spec-file-regexp
  "\\.\\(md\\|markdown\\|org\\|txt\\|rst\\|adoc\\|yaml\\|yml\\|json\\)\\'"
  "Regular expression for files loaded from `codetutor-spec-directory'."
  :type 'regexp)

(defcustom codetutor-spec-template
  "# {name}

## Problem / Why
<!-- What problem does this solve, and for whom? What is painful today? -->

## Goals
<!-- What must be true for this to be a success? Keep these outcome-focused. -->

## Non-goals
<!-- What are you deliberately NOT doing? Scope cuts make a spec honest. -->

## Requirements (acceptance criteria)
<!-- Concrete, testable statements. \"Given/when/then\" works well. -->

## Design
<!-- The shape of the solution: boundaries, data flow, key modules, tradeoffs. -->

## Build plan (slices)
<!-- Small, ordered, independently testable steps. Sequence to de-risk early. -->

## Open questions
<!-- What you are unsure about. The tutor will help you close these. -->

## Risks & edge cases
<!-- What could go wrong, and the inputs/states that are easy to forget. -->
"
  "Template for a new spec document.

The substring `{name}' is replaced with the spec's title.  Each section
carries an HTML comment that teaches what belongs there; you replace the
comment with your own content."
  :type 'string)

(defcustom codetutor-spec-window-height 0.4
  "Height of the tutor panel in spec mode.

An integer is a number of lines; a float is a fraction of the frame height."
  :type '(choice integer float))

(defcustom codetutor-spec-kickoff t
  "Whether opening a new spec starts a proactive tutoring interview."
  :type 'boolean)

(defcustom codetutor-scratch-max-bytes 8000
  "Maximum bytes of the CodeTutor scratch buffer pinned into each prompt."
  :type 'integer)

(defcustom codetutor-memory-file ".codetutor/ARCHITECTURE.md"
  "Project-relative file where CodeTutor stores durable architecture notes."
  :type 'string)

(defcustom codetutor-apply-memory-updates t
  "Whether CodeTutor should append durable architecture memory notes."
  :type 'boolean)

(defcustom codetutor-max-project-context-bytes 80000
  "Maximum number of bytes of project/spec/memory context sent per request."
  :type 'integer)

(defcustom codetutor-max-current-file-bytes 50000
  "Maximum number of bytes of the current buffer sent per request."
  :type 'integer)

(defcustom codetutor-include-open-buffers-on-save t
  "Whether save reviews should include other open project buffers as context."
  :type 'boolean)

(defcustom codetutor-max-open-buffers 12
  "Maximum number of other open file-backed buffers included on save."
  :type 'integer)

(defcustom codetutor-max-open-buffer-bytes 20000
  "Maximum number of bytes included for each other open buffer."
  :type 'integer)

(defcustom codetutor-max-open-buffer-context-bytes 80000
  "Maximum total bytes of other open buffer context included on save."
  :type 'integer)

(defcustom codetutor-max-diff-bytes 60000
  "Maximum number of bytes of save diff sent per request."
  :type 'integer)

(defcustom codetutor-max-file-index-entries 250
  "Maximum number of project file paths included in context."
  :type 'integer)

(defcustom codetutor-max-conversation-turns 8
  "Maximum number of prior conversation turns included in tutor prompts."
  :type 'integer)

(defcustom codetutor-max-conversation-bytes 30000
  "Maximum number of bytes of prior conversation included in tutor prompts."
  :type 'integer)

(defcustom codetutor-ignored-directories
  '(".git" ".hg" ".svn" "node_modules" "vendor" "dist" "build" ".next"
    ".turbo" ".venv" "venv" "__pycache__" ".mypy_cache" ".pytest_cache"
    ".elixir_ls" "_build" "deps" "target" ".codetutor")
  "Directory names excluded from fallback project file indexing."
  :type '(repeat string))

(defcustom codetutor-language-by-major-mode
  '((python-mode . python)
    (python-ts-mode . python)
    (js-mode . javascript)
    (js-ts-mode . javascript)
    (js2-mode . javascript)
    (typescript-mode . typescript)
    (typescript-ts-mode . typescript)
    (tsx-ts-mode . tsx)
    (ruby-mode . ruby)
    (ruby-ts-mode . ruby)
    (go-mode . go)
    (go-ts-mode . go)
    (rust-mode . rust)
    (rust-ts-mode . rust)
    (c-mode . c)
    (c-ts-mode . c)
    (c++-mode . cpp)
    (c++-ts-mode . cpp)
    (java-mode . java)
    (java-ts-mode . java)
    (json-mode . json)
    (json-ts-mode . json)
    (yaml-mode . yaml)
    (yaml-ts-mode . yaml)
    (toml-mode . toml)
    (toml-ts-mode . toml)
    (css-mode . css)
    (css-ts-mode . css)
    (html-mode . html)
    (html-ts-mode . html)
    (sh-mode . bash)
    (bash-ts-mode . bash))
  "Mapping from major modes to tree-sitter language symbols."
  :type '(alist :key-type symbol :value-type symbol))

(defcustom codetutor-system-prompt
  (string-join
   '("You are CodeTutor, a senior/staff engineer pair-programming tutor inside Emacs."
     ""
     "Purpose:"
     "- Help the user learn as they code."
     "- Teach the underlying concepts, engineering judgment, architecture, testing, and maintainability tradeoffs behind the work."
     "- Guide the user toward writing the code themselves."
     ""
     "Hard boundaries:"
     "- Never edit files."
     "- Never produce patches, full implementations, or replacement files."
     "- You may provide short, clearly labeled illustrative code samples when they teach a concept, API shape, testing approach, or refactoring pattern."
     "- Code samples should be examples, sketches, or analogous fragments, not complete ready-to-paste solutions for the user's exact task."
     "- Prefer questions, conceptual framing, debugging heuristics, and next-step guidance."
     "- If you inspect files or research best practices, summarize what matters and cite sources when available."
     "- Your final answer must contain only the tutor response. Do not echo the prompt, request metadata, project context, file contents, diffs, or tool transcripts."
     ""
     "Response style:"
     "- Be direct, concise, and senior-engineer practical."
     "- Explain why the advice matters."
     "- Include one concrete next move the user can take."
     "- Teach one concept that transfers beyond this specific file."
     "- When a code sample would make the concept clearer, include a compact snippet and explain how to adapt it."
     "- Keep feedback proportional to the diff; do not overwhelm the user."
     ""
     "Architecture memory:"
     "- Maintain an evolving understanding of this project's architecture."
     "- At the end of every response, include a fenced block exactly named codetutor-memory."
     "- Put only durable architecture observations in that block, one bullet per line."
     "- If there is nothing durable to remember, leave the block empty."
     "- Do not put code in the memory block."
     "- Wrap the visible tutor answer in <codetutor-answer> and </codetutor-answer> tags. Put the codetutor-memory block after those tags.")
   "\n")
  "System-style instructions included in every tutor request."
  :type 'string)

(defvar codetutor--sessions (make-hash-table :test #'equal))
(defvar codetutor--pre-save (make-hash-table :test #'eq))
(defvar codetutor--writing-memory nil)

(defun codetutor--nonempty-string (value)
  "Return VALUE when it is a non-blank string, else nil."
  (and (stringp value)
       (not (string-empty-p (string-trim value)))
       value))

;;; Inline tips ------------------------------------------------------------

(defface codetutor-inline-tip-face
  '((((class color) (background dark))
     :foreground "#d7d787" :background "#33332a" :extend t :slant italic)
    (((class color) (background light))
     :foreground "#6b6b00" :background "#fbfbe6" :extend t :slant italic)
    (t :slant italic))
  "Face for CodeTutor inline teaching tips shown as virtual lines."
  :group 'codetutor)

(defcustom codetutor-inline-tips-enable t
  "When non-nil, allow CodeTutor to render inline tips in code buffers."
  :type 'boolean)

(defcustom codetutor-inline-tip-placement 'below
  "Where an inline tip renders relative to its target line."
  :type '(choice (const :tag "Below the line" below)
                 (const :tag "Above the line" above)))

(defcustom codetutor-inline-tip-max 12
  "Maximum number of inline tips rendered for a single tutor run.

Tips beyond this cap are dropped to avoid flooding the buffer."
  :type 'integer)

(defcustom codetutor-inline-tip-prefix "💡 "
  "String prefixed to the first visual line of each inline tip."
  :type 'string)

(defcustom codetutor-inline-tip-clear-on-edit t
  "When non-nil, clear inline tips on the first user edit of the buffer.

This prevents tips anchored to now-stale line numbers from misleading."
  :type 'boolean)

(defvar-local codetutor--inline-tip-overlays nil
  "List of inline-tip overlays placed in the current buffer.")

(provide 'codetutor-vars)

;;; codetutor-vars.el ends here
