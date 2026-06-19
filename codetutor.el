;;; codetutor.el --- Pair-programming tutor for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Jacob Windle
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, ai, education, convenience

;;; Commentary:

;; CodeTutor is an Emacs side-panel coding tutor.  It watches saves,
;; sends the tutor a diff of the changes since the previous save, and asks
;; for teaching-oriented feedback.  It can also answer minibuffer prompts
;; and recommend the next step for the current project.
;;
;; The tutor is intentionally read-only.  The local backends are Codex CLI
;; and pi.dev CLI invocations configured so the model can inspect context
;; but cannot apply edits.  A remote Fireworks AI backend is also available
;; for users without a local CLI; it sends gathered context over HTTP and
;; must be selected explicitly.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'imenu)
(require 'treesit nil t)

(declare-function auth-source-search "auth-source")

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

(defcustom codetutor-window-width 84
  "Width of the CodeTutor side window.

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

(defvar codetutor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t o") #'codetutor-open)
    (define-key map (kbd "C-c t n") #'codetutor-what-next)
    (define-key map (kbd "C-c t a") #'codetutor-ask)
    (define-key map (kbd "C-c t f") #'codetutor-follow-up)
    (define-key map (kbd "C-c t m") #'codetutor-refresh-architecture-memory)
    (define-key map (kbd "C-c t s") #'codetutor-new-spec)
    (define-key map (kbd "C-c t S") #'codetutor-open-spec)
    map)
  "Keymap used by `codetutor-mode'.")

(define-derived-mode codetutor-panel-mode special-mode "CodeTutor"
  "Major mode for the CodeTutor side panel."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;;;###autoload
(define-minor-mode codetutor-mode
  "Toggle CodeTutor.

When enabled, CodeTutor can open a right-side panel, review diffs after
saves, answer minibuffer prompts, and recommend what to do next."
  :global t
  :lighter " Tutor"
  :keymap codetutor-mode-map
  (if codetutor-mode
      (progn
        (add-hook 'before-save-hook #'codetutor--before-save)
        (add-hook 'after-save-hook #'codetutor--after-save)
        (when codetutor-open-on-enable
          (codetutor-open)))
    (remove-hook 'before-save-hook #'codetutor--before-save)
    (remove-hook 'after-save-hook #'codetutor--after-save)))

;;;###autoload
(defun codetutor-open (&optional refresh)
  "Open the CodeTutor side panel.

With prefix argument REFRESH, run a fresh startup assessment even if the
current project already has an active tutor session."
  (interactive "P")
  (let* ((root (codetutor--project-root))
         (session (codetutor--session root))
         (buffer (codetutor--display-panel root)))
    (when (or refresh
              (and codetutor-start-session-on-open
                   (not (plist-get session :started))))
      (setf (plist-get session :started) t)
      (codetutor--startup root))
    buffer))

;;;###autoload
(defun codetutor-what-next ()
  "Ask CodeTutor to inspect context and recommend the best next step.

With an active spec, the recommendation is the next build slice for that spec."
  (interactive)
  (let* ((root (codetutor--project-root))
         (request (if (codetutor--active-spec root)
                      "Given the active spec and what I have built so far, teach me the single best next build slice to implement and the concept to focus on while doing it. Do not write the code for me."
                    "Recommend the single best next step for this project right now. Search or inspect files if useful. Teach me why that step matters and what concept I should pay attention to while doing it.")))
    (codetutor--display-panel root)
    (codetutor--request
     :root root
     :kind 'what-next
     :title "What Next"
     :manual t
     :user-request request
     :prompt (codetutor--build-prompt
              'what-next :root root :user-request request))))

;;;###autoload
(defun codetutor-ask (question)
  "Ask CodeTutor QUESTION from the minibuffer.

The current file, project context, architecture memory, tree-sitter summary,
and project file index are included.  The backend may inspect other files
with read-only tools when supported."
  (interactive
   (list (read-string "CodeTutor: " nil 'codetutor--prompt-history)))
  (unless (string-empty-p (string-trim question))
    (codetutor--display-panel (codetutor--project-root))
    (codetutor--request
     :root (codetutor--project-root)
     :kind 'ask
     :title "Answer"
     :manual t
     :user-request question
     :prompt (codetutor--build-prompt
              'ask
              :user-request question))))

;;;###autoload
(defun codetutor-follow-up (question)
  "Ask CodeTutor QUESTION as a follow-up to the previous answer.

The follow-up includes recent private conversation turns, current file context,
project context, architecture memory, and the project file index.  The panel
does not display the prompt text."
  (interactive
   (list (read-string "CodeTutor follow-up: " nil
                      'codetutor--prompt-history)))
  (unless (string-empty-p (string-trim question))
    (let* ((root (codetutor--project-root))
           (session (codetutor--session root)))
      (codetutor--display-panel root)
      (if (plist-get session :last-answer)
          (codetutor--request
           :root root
           :kind 'follow-up
           :title "Follow Up"
           :manual t
           :user-request question
           :prompt (codetutor--build-prompt
                    'follow-up
                    :root root
                    :user-request question))
        (codetutor--render-result
         (codetutor--panel-buffer root)
         root
         "Follow Up"
         "No previous CodeTutor answer is available yet. Ask a normal question first with `M-x codetutor-ask`, then use `M-x codetutor-follow-up`.")))))

;;;###autoload
(defun codetutor-refresh-architecture-memory ()
  "Ask CodeTutor to refresh its architecture memory for the project."
  (interactive)
  (let ((session (codetutor--session (codetutor--project-root))))
    (setf (plist-get session :symbol-table) nil))
  (codetutor--display-panel (codetutor--project-root))
  (codetutor--request
   :root (codetutor--project-root)
   :kind 'memory-refresh
   :title "Architecture Memory Refresh"
   :manual t
   :user-request "Inspect the project context and file index. Refresh your durable understanding of the architecture. Focus on domain boundaries, important modules, design direction, conventions, and architectural gaps worth guiding me on. Do not suggest code changes unless they are necessary as learning goals."
   :prompt (codetutor--build-prompt
            'memory-refresh
            :user-request "Inspect the project context and file index. Refresh your durable understanding of the architecture. Focus on domain boundaries, important modules, design direction, conventions, and architectural gaps worth guiding me on. Do not suggest code changes unless they are necessary as learning goals.")))

(defun codetutor--startup (root)
  "Start a CodeTutor session for ROOT."
  (codetutor--request
   :root root
   :kind 'startup
   :title "Startup Assessment"
   :manual t
   :user-request "Start a tutoring session for this project. Examine the current state of the world from PROJECT.md, spec/, architecture memory, current file context, and the file index. Tell me where to begin, what to learn first, and what engineering judgment I should apply before writing code."
   :prompt (codetutor--build-prompt
            'startup
            :root root
            :user-request "Start a tutoring session for this project. Examine the current state of the world from PROJECT.md, spec/, architecture memory, current file context, and the file index. Tell me where to begin, what to learn first, and what engineering judgment I should apply before writing code.")))

(cl-defun codetutor--request (&key root kind title prompt manual user-request file diff)
  "Run a tutor request for ROOT with KIND, TITLE, and PROMPT.

MANUAL requests cancel an active request.  Automatic requests may be skipped
when `codetutor-skip-auto-request-while-busy' is non-nil.

When the Fireworks backend is selected and `codetutor-fireworks-use-tools' is
non-nil, the request runs as an agentic tool-calling loop that builds its own
lean prompt from KIND, FILE, DIFF, and USER-REQUEST instead of PROMPT."
  (let* ((session (codetutor--session root))
         (existing (plist-get session :process))
         (panel (codetutor--panel-buffer root)))
    (cond
     ((and existing (process-live-p existing) manual)
      (process-put existing :codetutor-canceled t)
      (delete-process existing)
      (setf (plist-get session :process) nil))
     ((and existing (process-live-p existing) codetutor-skip-auto-request-while-busy)
      (message "CodeTutor skipped automatic save review because a tutor request is still running.")
      (cl-return-from codetutor--request nil)))
    (when (and (eq (codetutor--select-backend) 'fireworks)
               codetutor-fireworks-use-tools)
      (cl-return-from codetutor--request
        (codetutor--fireworks-agent-start
         root kind title panel user-request file diff)))
    (let* ((backend (codetutor--backend-command root prompt))
           (backend-name (plist-get backend :name))
           (command (plist-get backend :command))
           (stdin (plist-get backend :stdin))
           (output-file (plist-get backend :output-file))
           (temp-files (plist-get backend :temp-files))
           (parser (plist-get backend :parser))
           (message-text (plist-get backend :message))
           (process-buffer (generate-new-buffer " *codetutor-process*")))
      (if (null command)
          (progn
            (kill-buffer process-buffer)
            (codetutor--render-result
             panel
             root
             title
             (or message-text
                 "No CodeTutor backend is available. Install `codex` or `pi`, configure Fireworks AI, or customize `codetutor-backend`.")))
        (codetutor--render-status panel root title backend-name kind)
        (let ((process
               (make-process
                :name "codetutor"
                :buffer process-buffer
                :command command
                :connection-type 'pipe
                :noquery t
                :sentinel
                (lambda (proc event)
                  (unless (process-live-p proc)
                    (codetutor--handle-process-exit
                     proc event root title panel process-buffer output-file temp-files parser))))))
          (set-process-query-on-exit-flag process nil)
          (process-put process :kind kind)
          (process-put process :user-request user-request)
          (setf (plist-get session :process) process)
          (when stdin
            (process-send-string process stdin)
            (process-send-eof process))
          process)))))

(defun codetutor--handle-process-exit
    (process event root title panel process-buffer output-file temp-files parser)
  "Handle tutor PROCESS EVENT for ROOT and render output in PANEL.

PARSER, when non-nil, extracts the assistant answer from raw stdout (used
by HTTP backends such as Fireworks AI that return JSON)."
  (let* ((session (codetutor--session root))
         (status (process-exit-status process))
         (stdout (when (buffer-live-p process-buffer)
                   (with-current-buffer process-buffer
                     (buffer-substring-no-properties (point-min) (point-max)))))
         (answer-raw (if parser
                         (funcall parser stdout)
                       (codetutor--backend-answer stdout output-file)))
         (clean (codetutor--answer-text answer-raw)))
    (dolist (file temp-files)
      (when (and file (file-exists-p file))
        (ignore-errors (delete-file file))))
    (when (buffer-live-p process-buffer)
      (kill-buffer process-buffer))
    (unless (process-get process :codetutor-canceled)
      (when (eq (plist-get session :process) process)
        (setf (plist-get session :process) nil))
      (if (zerop status)
          (let ((answer (string-trim clean)))
            (codetutor--apply-memory-updates root answer-raw)
            (codetutor--record-turn
             root
             (process-get process :kind)
             (process-get process :user-request)
             answer)
            (codetutor--render-result panel root title answer)
            (when (eq parser #'codetutor--fireworks-parse-response)
              (let ((data (codetutor--fireworks-parse-data stdout)))
                (when data
                  (let ((usage (codetutor--fireworks-usage data)))
                    (codetutor--report-cost session (car usage) (cdr usage) 0))))))
        (codetutor--render-result
         panel
         root
         title
         (format "Tutor backend exited with status %s (%s).\n\n%s"
                 status
                 (string-trim event)
                 (string-trim (if parser
                                  (or answer-raw "")
                                (codetutor--answer-text stdout)))))))))

(defun codetutor--before-save ()
  "Capture the current buffer and on-disk file before save."
  (when (and codetutor-mode
             codetutor-review-on-save
             buffer-file-name
             (not codetutor--writing-memory))
    (puthash
     (current-buffer)
     (list :file buffer-file-name
           :root (codetutor--project-root)
           :before (codetutor--read-existing-file buffer-file-name)
           :after (buffer-substring-no-properties (point-min) (point-max)))
     codetutor--pre-save)))

(defun codetutor--after-save ()
  "Send a save diff to CodeTutor after a file is saved."
  (when (and codetutor-mode
             codetutor-review-on-save
             buffer-file-name
             (not codetutor--writing-memory))
    (let ((snapshot (gethash (current-buffer) codetutor--pre-save)))
      (remhash (current-buffer) codetutor--pre-save)
      (when snapshot
        (let* ((file (plist-get snapshot :file))
               (root (plist-get snapshot :root))
               (before (plist-get snapshot :before))
               (after (plist-get snapshot :after))
               (diff (codetutor--unified-diff before after file)))
          (when (and diff (not (string-empty-p (string-trim diff))))
            (let* ((kind (codetutor--save-kind file root))
                   (touched (when (eq kind 'spec)
                              (codetutor--spec-section-at
                               after (or (codetutor--diff-touched-line diff) 1))))
                   (request (codetutor--save-request kind touched)))
              (codetutor--display-panel root)
              (codetutor--request
               :root root
               :kind kind
               :title (codetutor--save-title kind file root)
               :manual nil
               :file file
               :diff diff
               :user-request request
               :prompt (codetutor--build-prompt
                        kind
                        :root root
                        :file file
                        :diff diff
                        :user-request request)))))))))

(cl-defun codetutor--build-prompt (kind &key root file diff user-request)
  "Build a tutor prompt for KIND.

ROOT defaults to the current project root.  FILE defaults to the current
buffer file.  DIFF and USER-REQUEST are included when present."
  (let* ((project-root (file-name-as-directory (or root (codetutor--project-root))))
         (current-file (or file buffer-file-name))
         (project-context (codetutor--project-context project-root))
         (conversation-context (codetutor--conversation-context project-root))
         (file-context (codetutor--current-file-context current-file))
         (open-buffer-context (when (and codetutor-include-open-buffers-on-save
                                         (eq kind 'save))
                                (codetutor--open-buffers-context
                                 project-root
                                 current-file)))
         (file-index (codetutor--project-file-index project-root))
         (spec-context (codetutor--spec-context
                        project-root (when (eq kind 'spec) diff)))
         (spec-instruction (when (memq kind '(spec spec-implement))
                             (codetutor--spec-instruction kind)))
         (diff-text (when diff
                      (codetutor--truncate diff codetutor-max-diff-bytes))))
    (string-join
     (delq
      nil
      (list
       codetutor-system-prompt
       (format "REQUEST TYPE: %s" kind)
       (format "PROJECT ROOT:\n%s" project-root)
       (when user-request
         (format "USER REQUEST:\n%s" user-request))
       (when conversation-context
         (format "RECENT CONVERSATION:\n%s" conversation-context))
       (when spec-context
         (format "SPEC STATUS:\n%s" spec-context))
       spec-instruction
       "OPERATING RULES FOR THIS REQUEST:
- You may inspect/search project files if the backend gives you read-only tools.
- Treat PROJECT.md/Project.md/project.md and spec/ as the source of product direction.
- Use the current file and diff as teaching context, not as permission to generate code.
- If the user asks what to do next, pick one best next step and justify it.
- If the user asks a direct question, answer it, but keep the teaching posture.
- If this is a follow-up, use the recent conversation turns to answer in context without restating them.
- Include short illustrative code snippets when they help the user understand the concept or shape of the solution.
- Do not output patches, full-file replacements, or complete ready-to-paste implementations for the exact task."
       (format "PROJECT CONTEXT:\n%s" project-context)
       (format "PROJECT FILE INDEX:\n%s" file-index)
       (format "CURRENT FILE CONTEXT:\n%s" file-context)
       (when open-buffer-context
         (format "OTHER OPEN PROJECT BUFFERS:\n%s" open-buffer-context))
       (when diff-text
         (format "DIFF SINCE LAST SAVE:\n%s" diff-text))
       "RESPONSE CONTRACT:
- Start with the most useful guidance, not a summary of the prompt.
- Do not echo any prompt sections, request metadata, context files, file contents, or diffs.
- Teach the underlying concept in plain language.
- Include a compact code example when it would teach the idea better than prose alone.
- Give one concrete next move.
- Keep the response short enough to read while coding.
- Wrap the visible tutor answer in <codetutor-answer> and </codetutor-answer> tags.
- End with a codetutor-memory fenced block for durable architecture observations only."))
     "\n\n")))

(defun codetutor--project-root ()
  "Return the current project root."
  (file-name-as-directory
   (expand-file-name
    (or (when-let ((project (project-current nil)))
          (project-root project))
        (locate-dominating-file default-directory ".git")
        (cl-loop for marker in (append codetutor-project-files
                                       (list codetutor-spec-directory))
                 thereis (locate-dominating-file default-directory marker))
        default-directory))))

(defun codetutor--session (root)
  "Return the mutable CodeTutor session plist for ROOT."
  (let ((key (file-name-as-directory (expand-file-name root))))
    (or (gethash key codetutor--sessions)
        (puthash key
                 (list :started nil :process nil :turns nil :last-answer nil
                       :symbol-table nil :active-spec nil
                       :cost-prompt-tokens 0 :cost-completion-tokens 0)
                 codetutor--sessions))))

(defun codetutor--record-turn (root kind user-request answer)
  "Record USER-REQUEST and ANSWER as a private conversation turn for ROOT."
  (when (and user-request answer (not (string-empty-p (string-trim answer))))
    (let* ((session (codetutor--session root))
           (turns (plist-get session :turns))
           (new-turns
            (append
             turns
             (list
              (list :role 'user :kind kind :text user-request)
              (list :role 'assistant :kind kind :text answer)))))
      (setf (plist-get session :last-answer) answer)
      (setf (plist-get session :turns)
            (codetutor--limit-turns new-turns)))))

(defun codetutor--limit-turns (turns)
  "Return TURNS limited by `codetutor-max-conversation-turns'."
  (let ((max-turns (* 2 codetutor-max-conversation-turns)))
    (if (> (length turns) max-turns)
        (last turns max-turns)
      turns)))

(defun codetutor--conversation-context (root)
  "Return recent private conversation context for ROOT, or nil."
  (let* ((session (codetutor--session root))
         (turns (plist-get session :turns)))
    (when turns
      (codetutor--truncate
       (string-join
        (cl-loop for turn in (codetutor--limit-turns turns)
                 for index from 1
                 collect
                 (format "%s. %s (%s):\n%s"
                         index
                         (capitalize (symbol-name (plist-get turn :role)))
                         (plist-get turn :kind)
                         (string-trim (plist-get turn :text))))
        "\n\n")
       codetutor-max-conversation-bytes))))

(defun codetutor--panel-buffer (root)
  "Return the side-panel buffer for ROOT."
  (let* ((root-dir (file-name-as-directory (expand-file-name root)))
         (name (format "*CodeTutor: %s*"
                       (directory-file-name
                        (file-name-nondirectory
                         (directory-file-name root-dir))))))
    (with-current-buffer (get-buffer-create name)
      (unless (derived-mode-p 'codetutor-panel-mode)
        (codetutor-panel-mode)
        (codetutor--append
         (current-buffer)
         (format "# CodeTutor\n\nProject: %s\n" root-dir)))
      (current-buffer))))

(defun codetutor--render-status (buffer root title backend-name kind)
  "Clear BUFFER and render a thinking status for ROOT, TITLE, and KIND."
  (codetutor--replace
   buffer
   (format "%sStatus: thinking\n\n## %s\n\nThinking with %s for `%s`...\n"
           (codetutor--panel-header root)
           title
           backend-name
           kind)))

(defun codetutor--render-result (buffer root title output)
  "Clear BUFFER and render OUTPUT for ROOT and TITLE."
  (codetutor--replace
   buffer
   (format "%s## %s\n\n%s\n"
           (codetutor--panel-header root)
           title
           (if (string-empty-p (string-trim (or output "")))
               "CodeTutor returned an empty response."
             (string-trim output)))))

(defun codetutor--panel-header (root)
  "Return the common CodeTutor panel header for ROOT."
  (format "# CodeTutor\n\nProject: %s\n\n"
          (file-name-as-directory (expand-file-name root))))

(defun codetutor--replace (buffer text)
  "Replace BUFFER contents with TEXT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))))))

(defun codetutor--display-panel (root)
  "Display and return the side-panel buffer for ROOT."
  (let ((buffer (codetutor--panel-buffer root)))
    (display-buffer-in-side-window
     buffer
     `((side . right)
       (slot . 1)
       (window-width . ,(codetutor--window-width))))
    buffer))

(defun codetutor--append (buffer text)
  "Append TEXT to BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (moving (= (point) (point-max))))
        (goto-char (point-max))
        (insert text)
        (unless (string-suffix-p "\n" text)
          (insert "\n"))
        (when moving
          (goto-char (point-max)))))))

(defun codetutor--window-width ()
  "Return the side-window width in columns."
  (if (floatp codetutor-window-width)
      (max 40 (round (* (frame-width) codetutor-window-width)))
    codetutor-window-width))

(defun codetutor--backend-command (root prompt)
  "Return a backend command plist for ROOT and PROMPT."
  (pcase (codetutor--select-backend)
    ('codex
     (let* ((output-file (make-temp-file "codetutor-codex-answer-" nil ".md"))
            (command (append
                      (list codetutor-codex-command
                            "--sandbox" "read-only"
                            "--ask-for-approval" "never")
                      (when codetutor-enable-web-search
                        (list "--search"))
                      (list "exec"
                            "-C" root
                            "--skip-git-repo-check"
                            "--color" "never"
                            "--ephemeral"
                            "--output-last-message" output-file)
                      (when codetutor-model
                        (list "-m" codetutor-model))
                      (list "-"))))
       (list :name "Codex"
             :command command
             :stdin prompt
             :output-file output-file
             :temp-files (list output-file))))
    ('pi
     (let ((prompt-file (make-temp-file "codetutor-prompt-" nil ".md")))
       (let ((coding-system-for-write 'utf-8))
         (write-region prompt nil prompt-file nil 'silent))
       (list :name "pi.dev"
             :temp-files (list prompt-file)
             :command
             (append
              (list codetutor-pi-command
                    "--print"
                    "--tools" "read,grep,find,ls"
                    "--system-prompt" codetutor-system-prompt)
              (when codetutor-model
                (list "--model" codetutor-model))
              (list (concat "@" prompt-file)
                    "Respond to the CodeTutor request in the attached prompt file.")))))
    ('fireworks
     (let ((api-key (codetutor--fireworks-api-key)))
       (if (null api-key)
           (list :name "Fireworks AI"
                 :command nil
                 :message (concat "No Fireworks AI API key is available. "
                                  "Set `codetutor-fireworks-api-key', the "
                                  "FIREWORKS_API_KEY environment variable, or an "
                                  "auth-source entry for host `api.fireworks.ai'."))
         (let* ((model (or codetutor-model codetutor-fireworks-model))
                (endpoint (concat (string-remove-suffix "/" codetutor-fireworks-api-base)
                                  "/chat/completions"))
                (config-file (make-temp-file "codetutor-fireworks-config-"))
                (body-file (make-temp-file "codetutor-fireworks-body-" nil ".json"))
                (body (codetutor--fireworks-request-body model prompt)))
           (let ((coding-system-for-write 'utf-8-unix))
             ;; `make-temp-file' creates 0600 files, so the secret config is
             ;; not world-readable; overwriting preserves that mode.
             (write-region (codetutor--fireworks-curl-config api-key)
                           nil config-file nil 'silent)
             (write-region body nil body-file nil 'silent))
           (list :name "Fireworks AI"
                 :temp-files (list config-file body-file)
                 :parser #'codetutor--fireworks-parse-response
                 :command
                 (list codetutor-fireworks-command
                       "--silent" "--show-error" "--fail-with-body"
                       "--config" config-file
                       "--header" "Content-Type: application/json"
                       "--data" (concat "@" body-file)
                       endpoint))))))
    (_
     (list :name nil :command nil))))

(defun codetutor--select-backend ()
  "Select an available backend."
  (pcase codetutor-backend
    ('codex (when (executable-find codetutor-codex-command) 'codex))
    ('pi (when (executable-find codetutor-pi-command) 'pi))
    ;; Require only the command here; `codetutor--backend-command' reports a
    ;; specific message when the API key cannot be resolved.
    ('fireworks (when (executable-find codetutor-fireworks-command) 'fireworks))
    ;; `auto' never selects `fireworks': the remote backend transmits
    ;; project context off the machine and must be chosen explicitly.
    ('auto (cond
            ((executable-find codetutor-codex-command) 'codex)
            ((executable-find codetutor-pi-command) 'pi)))))

(defun codetutor--nonempty-string (value)
  "Return VALUE when it is a non-blank string, else nil."
  (and (stringp value)
       (not (string-empty-p (string-trim value)))
       value))

(defun codetutor--fireworks-api-key ()
  "Return the Fireworks AI API key, or nil when none is configured.

Resolution order: `codetutor-fireworks-api-key', the FIREWORKS_API_KEY
environment variable, then an `auth-source' entry for host
`api.fireworks.ai'."
  (or (codetutor--nonempty-string codetutor-fireworks-api-key)
      (codetutor--nonempty-string (getenv "FIREWORKS_API_KEY"))
      (codetutor--fireworks-auth-source-key)))

(defun codetutor--fireworks-auth-source-key ()
  "Return a Fireworks AI API key from `auth-source', or nil."
  (condition-case nil
      (progn
        (require 'auth-source)
        (when-let* ((entry (car (auth-source-search
                                 :host "api.fireworks.ai"
                                 :require '(:secret)
                                 :max 1)))
                    (secret (plist-get entry :secret)))
          (codetutor--nonempty-string
           (if (functionp secret) (funcall secret) secret))))
    (error nil)))

(defun codetutor--fireworks-curl-config (api-key)
  "Return curl --config file contents carrying API-KEY in an auth header.

The key is written to a config file rather than passed as a command-line
argument so it never appears in the process list."
  (when (string-match-p "[\n\r]" api-key)
    (error "CodeTutor: Fireworks API key must not contain newlines"))
  (let ((escaped (replace-regexp-in-string "[\\\"]" "\\\\\\&" api-key)))
    (format "header = \"Authorization: Bearer %s\"\n" escaped)))

(defun codetutor--fireworks-messages (prompt)
  "Return a Fireworks AI messages vector for PROMPT.

`codetutor--build-prompt' embeds `codetutor-system-prompt' at the head of
PROMPT.  When that preamble is present it is sent as a `system' message
and stripped from the `user' message so the instructions are not
duplicated."
  (let ((preamble (concat codetutor-system-prompt "\n\n")))
    (if (string-prefix-p preamble prompt)
        (vector `((role . "system") (content . ,codetutor-system-prompt))
                `((role . "user") (content . ,(substring prompt (length preamble)))))
      (vector `((role . "user") (content . ,prompt))))))

(defun codetutor--fireworks-request-body (model prompt)
  "Return a JSON chat-completions request body for MODEL and PROMPT."
  (json-serialize
   `((model . ,model)
     (messages . ,(codetutor--fireworks-messages prompt))
     (max_tokens . ,codetutor-fireworks-max-tokens)
     (temperature . ,codetutor-fireworks-temperature))))

(defun codetutor--fireworks-parse-response (stdout)
  "Extract assistant text or an error message from Fireworks STDOUT."
  (let ((text (string-trim (or stdout ""))))
    (if (string-empty-p text)
        ""
      (condition-case err
          (let* ((data (json-parse-string text
                                          :object-type 'alist
                                          :array-type 'list))
                 (error-info (alist-get 'error data))
                 (choices (alist-get 'choices data)))
            (cond
             (error-info
              (format "Fireworks API error: %s"
                      (or (and (listp error-info) (alist-get 'message error-info))
                          error-info)))
             (choices
              (let ((content (alist-get 'content (alist-get 'message (car choices)))))
                (if (stringp content) content "")))
             (t text)))
        (error
         (format "CodeTutor could not parse the Fireworks response: %s\n\n%s"
                 (error-message-string err)
                 text))))))

(defun codetutor--fireworks-parse-data (stdout)
  "Return the parsed Fireworks response alist from STDOUT, or nil.

Returns nil on empty output, malformed JSON, or an API error payload (no
`choices'); callers fall back to `codetutor--fireworks-parse-response' for a
human-readable error string."
  (let ((text (string-trim (or stdout ""))))
    (unless (string-empty-p text)
      (condition-case nil
          (let ((data (json-parse-string text
                                         :object-type 'alist
                                         :array-type 'list)))
            (when (alist-get 'choices data) data))
        (error nil)))))

(defun codetutor--fireworks-usage (data)
  "Return (PROMPT . COMPLETION) token counts from response DATA."
  (let ((usage (alist-get 'usage data)))
    (cons (or (alist-get 'prompt_tokens usage) 0)
          (or (alist-get 'completion_tokens usage) 0))))

;;; Cost reporting ----------------------------------------------------------

(defun codetutor--group-number (n)
  "Return integer N as a string with thousands separators."
  (let ((digits (number-to-string (abs n)))
        (parts nil))
    (while (> (length digits) 3)
      (push (substring digits (- (length digits) 3)) parts)
      (setq digits (substring digits 0 (- (length digits) 3))))
    (push digits parts)
    (concat (if (< n 0) "-" "") (string-join parts ","))))

(defun codetutor--cost-dollars (prompt completion)
  "Return estimated USD cost for PROMPT/COMPLETION tokens, or nil when unpriced."
  (when (and (numberp codetutor-fireworks-cost-input-per-million)
             (numberp codetutor-fireworks-cost-output-per-million))
    (+ (* (/ prompt 1000000.0) codetutor-fireworks-cost-input-per-million)
       (* (/ completion 1000000.0) codetutor-fireworks-cost-output-per-million))))

(defun codetutor--format-cost (prompt completion tool-calls
                                      session-prompt session-completion)
  "Return a one-line usage/cost summary string.

PROMPT and COMPLETION are this request's token counts, TOOL-CALLS the number of
tool calls it made, and SESSION-PROMPT/SESSION-COMPLETION the cumulative session
totals.  A dollar estimate is included only when both price customs are set."
  (let ((dollars (codetutor--cost-dollars prompt completion))
        (session-dollars (codetutor--cost-dollars session-prompt session-completion)))
    (concat
     (format "%s tokens (%s in / %s out)"
             (codetutor--group-number (+ prompt completion))
             (codetutor--group-number prompt)
             (codetutor--group-number completion))
     (when (> tool-calls 0)
       (format " · %d tool call%s" tool-calls (if (= tool-calls 1) "" "s")))
     (when dollars (format " · ~$%.4f" dollars))
     (format " · session %s tokens"
             (codetutor--group-number (+ session-prompt session-completion)))
     (when session-dollars (format " (~$%.4f)" session-dollars)))))

(defun codetutor--report-cost (session prompt completion tool-calls)
  "Add PROMPT/COMPLETION tokens to SESSION totals and message the usage line."
  (when codetutor-show-cost
    (cl-incf (plist-get session :cost-prompt-tokens) prompt)
    (cl-incf (plist-get session :cost-completion-tokens) completion)
    (message "CodeTutor: %s"
             (codetutor--format-cost
              prompt completion tool-calls
              (plist-get session :cost-prompt-tokens)
              (plist-get session :cost-completion-tokens)))))

;;; Read-only tools ---------------------------------------------------------

(defun codetutor--resolve-project-path (root rel)
  "Resolve REL against ROOT, returning an absolute path inside ROOT, or nil.

Rejects paths that escape ROOT (via `..' or absolute paths), so tools can only
read inside the project."
  (when (stringp rel)
    (let* ((root-dir (file-name-as-directory (expand-file-name root)))
           (resolved (expand-file-name rel root-dir)))
      (when (or (string= (file-name-as-directory resolved) root-dir)
                (file-in-directory-p resolved root-dir))
        resolved))))

(defun codetutor--read-file-region (file rel start end)
  "Return text of FILE (display name REL), optionally lines START..END."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (let ((total (line-number-at-pos (point-max))))
      (if (or (integerp start) (integerp end))
          (let ((from (max 1 (or start 1)))
                (to (min total (or end total)))
                beg)
            (if (> from to)
                (format "Error: line range %s-%s is empty (%s has %d lines)."
                        from to rel total)
              (goto-char (point-min))
              (forward-line (1- from))
              (setq beg (point))
              (goto-char (point-min))
              (forward-line to)
              (format "%s (lines %d-%d of %d):\n%s"
                      rel from to total
                      (buffer-substring-no-properties beg (point)))))
        (format "%s (%d lines):\n%s"
                rel total
                (buffer-substring-no-properties (point-min) (point-max)))))))

(defun codetutor--tool-read-file (root _ctx args)
  "Tool: read a project file (optionally a line range)."
  (let ((rel (alist-get 'path args))
        (start (alist-get 'start_line args))
        (end (alist-get 'end_line args)))
    (if (not (stringp rel))
        "Error: read_file requires a string \"path\"."
      (let ((file (codetutor--resolve-project-path root rel)))
        (cond
         ((null file) (format "Error: %S is outside the project root." rel))
         ((file-directory-p file)
          (format "Error: %S is a directory; use list_directory." rel))
         ((not (file-readable-p file)) (format "Error: cannot read %S." rel))
         (t (codetutor--read-file-region file rel start end)))))))

(defun codetutor--tool-list-directory (root _ctx args)
  "Tool: list a project directory, skipping ignored directories."
  (let* ((rel (or (alist-get 'path args) "."))
         (dir (codetutor--resolve-project-path root rel)))
    (cond
     ((null dir) (format "Error: %S is outside the project root." rel))
     ((not (file-directory-p dir)) (format "Error: %S is not a directory." rel))
     (t (let ((entries
               (cl-remove-if
                (lambda (name)
                  (or (member name '("." ".."))
                      (member name codetutor-ignored-directories)))
                (directory-files dir))))
          (if (null entries)
              (format "%s is empty." rel)
            (string-join
             (mapcar (lambda (name)
                       (concat name
                               (if (file-directory-p (expand-file-name name dir))
                                   "/" "")))
                     (sort entries #'string<))
             "\n")))))))

(defun codetutor--tool-read-project-context (root _ctx _args)
  "Tool: return PROJECT.md/spec/architecture-memory context for ROOT."
  (codetutor--project-context root))

(defun codetutor--tool-read-current-file (_root ctx _args)
  "Tool: return the file/buffer that triggered this request."
  (or (plist-get ctx :current-file-context)
      "No current file is associated with this request."))

(defun codetutor--tool-project-symbol-table (root _ctx args)
  "Tool: return the project-wide symbol table, optionally filtered."
  (codetutor--project-symbol-table root (alist-get 'name_filter args)))

(defun codetutor--search-project (root pattern rel)
  "Search PATTERN under ROOT (optionally subpath REL) read-only, returning matches."
  (let ((dir (if rel (codetutor--resolve-project-path root rel) root)))
    (if (null dir)
        (format "Error: %S is outside the project root." rel)
      (let* ((rg (executable-find codetutor-search-command))
             (program (or rg "grep"))
             (default-directory (file-name-as-directory dir))
             (args (if rg
                       (list "--line-number" "--no-heading" "--color" "never"
                             "--max-count" "50" "-e" pattern ".")
                     (list "-rnI" "--" pattern "."))))
        (if (not (or rg (executable-find "grep")))
            "Error: no search command (rg/grep) is available."
          (with-temp-buffer
            (let ((exit (apply #'call-process program nil t nil args)))
              (let ((out (string-trim
                          (buffer-substring-no-properties (point-min) (point-max)))))
                (cond
                 ((string-empty-p out) "No matches.")
                 ((memq exit '(0 1)) out)
                 (t (format "Search exited with status %s.\n%s" exit out)))))))))))

(defun codetutor--tool-search-project (root _ctx args)
  "Tool: search the project for a regexp PATTERN."
  (let ((pattern (alist-get 'pattern args))
        (rel (alist-get 'path args)))
    (if (not (stringp pattern))
        "Error: search_project requires a string \"pattern\"."
      (codetutor--search-project root pattern rel))))

(defvar codetutor--tools
  `((:name "read_file"
     :description "Read a UTF-8 text file from the project, optionally a line range. Paths are relative to the project root."
     :schema ((type . "object")
              (properties
               (path (type . "string")
                     (description . "Project-relative path to the file."))
               (start_line (type . "integer")
                           (description . "1-based first line to include (optional)."))
               (end_line (type . "integer")
                         (description . "1-based last line to include (optional).")))
              (required . ["path"]))
     :handler codetutor--tool-read-file)
    (:name "list_directory"
     :description "List the entries of a project directory. Directories end with a slash. Ignored directories (.git, node_modules, ...) are omitted."
     :schema ((type . "object")
              (properties
               (path (type . "string")
                     (description . "Project-relative directory path. Defaults to the project root.")))
              (required . []))
     :handler codetutor--tool-list-directory)
    (:name "read_project_context"
     :description "Return product/project direction: PROJECT.md, the spec/ directory, and CodeTutor's architecture memory."
     :schema ((type . "object") (properties . ,(make-hash-table :test 'equal)))
     :handler codetutor--tool-read-project-context)
    (:name "read_current_file"
     :description "Return the file the user is currently editing (path, outline, and text) that triggered this request."
     :schema ((type . "object") (properties . ,(make-hash-table :test 'equal)))
     :handler codetutor--tool-read-current-file)
    (:name "project_symbol_table"
     :description "Return a project-wide index of top-level symbols (functions, classes, etc.) with their files and line numbers, built with tree-sitter."
     :schema ((type . "object")
              (properties
               (name_filter (type . "string")
                            (description . "Only return symbol lines containing this substring (optional).")))
              (required . []))
     :handler codetutor--tool-project-symbol-table)
    (:name "search_project"
     :description "Search the project for a regular expression and return matching file:line results (capped)."
     :schema ((type . "object")
              (properties
               (pattern (type . "string")
                        (description . "Regular expression to search for."))
               (path (type . "string")
                     (description . "Project-relative directory to limit the search (optional).")))
              (required . ["pattern"]))
     :handler codetutor--tool-search-project))
  "Read-only tools exposed to the Fireworks agentic backend.
Each entry is a plist: :name :description :schema :handler.")

(defun codetutor--tool-specs ()
  "Return the tools array (vector of function specs) for the Fireworks request."
  (vconcat
   (mapcar
    (lambda (tool)
      `((type . "function")
        (function . ((name . ,(plist-get tool :name))
                     (description . ,(plist-get tool :description))
                     (parameters . ,(plist-get tool :schema))))))
    codetutor--tools)))

(defun codetutor--dispatch-tool (root ctx name args)
  "Run tool NAME with ARGS for ROOT and CTX; return a capped result string."
  (let ((tool (cl-find name codetutor--tools
                       :key (lambda (s) (plist-get s :name))
                       :test #'equal)))
    (if (null tool)
        (format "Error: unknown tool %S." name)
      (codetutor--truncate
       (condition-case err
           (or (funcall (plist-get tool :handler) root ctx args) "")
         (error (format "Error running %s: %s" name (error-message-string err))))
       codetutor-tool-max-output-bytes))))

;;; Project-wide symbol table (tree-sitter) ---------------------------------

(defun codetutor--file-major-mode (file)
  "Return the major mode Emacs would choose for FILE, or nil."
  (let ((mode (assoc-default file auto-mode-alist 'string-match)))
    (when (consp mode) (setq mode (car mode)))
    (and (symbolp mode) mode)))

(defun codetutor--file-treesit-language (file)
  "Return an available tree-sitter language symbol for FILE, or nil."
  (let* ((mode (codetutor--file-major-mode file))
         (language (and mode (alist-get mode codetutor-language-by-major-mode))))
    (when (and language
               (fboundp 'treesit-language-available-p)
               (treesit-language-available-p language))
      language)))

(defun codetutor--treesit-symbol-line (node)
  "Return a one-line symbol description for NODE, or nil when unnamed."
  (let ((name (or (ignore-errors (treesit-defun-name node))
                  (codetutor--treesit-child-name node))))
    (when (and name (not (string-empty-p name)))
      (format "  L%d  %s  %s"
              (line-number-at-pos (treesit-node-start node))
              (treesit-node-type node)
              name))))

(defun codetutor--file-symbol-lines (file language)
  "Return top-level symbol lines for FILE parsed as LANGUAGE, or nil."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (let* ((parser (treesit-parser-create language))
               (root (treesit-parser-root-node parser))
               (children (treesit-node-children root t)))
          (delq nil (mapcar #'codetutor--treesit-symbol-line children))))
    (error nil)))

(defun codetutor--build-symbol-table (root)
  "Build the project symbol table for ROOT as a plist."
  (let* ((root-dir (file-name-as-directory (expand-file-name root)))
         (files (codetutor--project-files root-dir))
         (limited (cl-subseq files 0 (min (length files)
                                          codetutor-symbol-table-max-files)))
         (entries nil)
         (symbol-files 0)
         (skipped 0))
    (dolist (rel limited)
      (let ((language (codetutor--file-treesit-language rel)))
        (if (null language)
            (setq skipped (1+ skipped))
          (let ((lines (codetutor--file-symbol-lines
                        (expand-file-name rel root-dir) language)))
            (when lines
              (setq symbol-files (1+ symbol-files))
              (push (cons rel lines) entries))))))
    (list :entries (nreverse entries)
          :scanned (length limited)
          :total (length files)
          :symbol-files symbol-files
          :skipped skipped)))

(defun codetutor--filter-symbol-entries (entries name-filter)
  "Return ENTRIES keeping only symbol lines containing NAME-FILTER."
  (delq nil
        (mapcar
         (lambda (entry)
           (let ((matches (cl-remove-if-not
                           (lambda (line)
                             (string-match-p (regexp-quote name-filter) line))
                           (cdr entry))))
             (when matches (cons (car entry) matches))))
         entries)))

(defun codetutor--render-symbol-table (table name-filter)
  "Render symbol TABLE as a string, optionally filtered by NAME-FILTER."
  (let* ((filtering (and (stringp name-filter)
                         (not (string-empty-p name-filter))))
         (entries (plist-get table :entries))
         (filtered (if filtering
                       (codetutor--filter-symbol-entries entries name-filter)
                     entries)))
    (if (null filtered)
        (if filtering
            (format "No symbols matching %S in %d scanned files."
                    name-filter (plist-get table :scanned))
          "No symbols found (no installed tree-sitter grammars for this project's files).")
      (concat
       (format "Project symbols — %d files with symbols, %d of %d files scanned, %d skipped (no grammar)%s:\n\n"
               (plist-get table :symbol-files)
               (plist-get table :scanned)
               (plist-get table :total)
               (plist-get table :skipped)
               (if filtering (format ", filtered by %S" name-filter) ""))
       (string-join
        (mapcar (lambda (entry)
                  (format "%s\n%s" (car entry)
                          (string-join (cdr entry) "\n")))
                filtered)
        "\n\n")))))

(defun codetutor--project-symbol-table (root &optional name-filter)
  "Return the project symbol table for ROOT, optionally filtered by NAME-FILTER.

The table is built once per session and cached on the session plist; it is
rebuilt when `codetutor-refresh-architecture-memory' clears the cache."
  (let* ((session (codetutor--session root))
         (table (or (plist-get session :symbol-table)
                    (let ((built (codetutor--build-symbol-table root)))
                      (setf (plist-get session :symbol-table) built)
                      built))))
    (codetutor--render-symbol-table table name-filter)))

;;; Fireworks agentic loop --------------------------------------------------

(cl-defun codetutor--build-agent-seed-prompt (kind &key root file diff user-request)
  "Build the lean seed prompt for an agentic Fireworks request of KIND.

Deep context is left for the model to fetch with tools; this only seeds the
task, the current-file outline, the diff (on save), and the file index."
  (let* ((project-root (file-name-as-directory (or root (codetutor--project-root))))
         (current-file (or file buffer-file-name))
         (conversation (codetutor--conversation-context project-root))
         (outline (codetutor--syntax-summary))
         (file-index (codetutor--project-file-index project-root))
         (spec-context (codetutor--spec-context
                        project-root (when (eq kind 'spec) diff)))
         (spec-instruction (when (memq kind '(spec spec-implement))
                             (codetutor--spec-instruction kind)))
         (diff-text (when diff (codetutor--truncate diff codetutor-max-diff-bytes))))
    (string-join
     (delq
      nil
      (list
       (format "REQUEST TYPE: %s" kind)
       (format "PROJECT ROOT:\n%s" project-root)
       (when user-request (format "USER REQUEST:\n%s" user-request))
       (when conversation (format "RECENT CONVERSATION:\n%s" conversation))
       (when spec-context (format "SPEC STATUS:\n%s" spec-context))
       spec-instruction
       (format "CURRENT FILE: %s" (or current-file "none"))
       (format "CURRENT FILE OUTLINE:\n%s" outline)
       (when diff-text (format "DIFF SINCE LAST SAVE:\n%s" diff-text))
       (format "PROJECT FILE INDEX:\n%s" file-index)
       "TOOLS:
- You have read-only tools: read_file, list_directory, read_project_context, read_current_file, project_symbol_table, search_project.
- Use them to gather any context you need before answering. Product/project direction lives in read_project_context.
- Do not ask the user to paste code; fetch it yourself. All paths are relative to the project root. You cannot modify files."
       "RESPONSE CONTRACT:
- Teach the underlying concept and give one concrete next move.
- Include a compact code example only when it teaches the idea better than prose.
- Do not output patches, full-file replacements, or complete ready-to-paste implementations.
- Wrap the visible answer in <codetutor-answer> and </codetutor-answer> tags.
- End with a codetutor-memory fenced block for durable architecture notes only."))
     "\n\n")))

(defun codetutor--normalize-tool-calls (tool-calls)
  "Return TOOL-CALLS (parsed list) as a clean vector for re-serialization."
  (vconcat
   (mapcar
    (lambda (tc)
      (let ((fn (alist-get 'function tc)))
        `((id . ,(alist-get 'id tc))
          (type . "function")
          (function . ((name . ,(alist-get 'name fn))
                       (arguments . ,(or (alist-get 'arguments fn) "{}")))))))
    tool-calls)))

(defun codetutor--parse-tool-arguments (args-string)
  "Parse a tool-call ARGS-STRING (JSON) into an alist, or nil."
  (if (or (null args-string)
          (string-empty-p (string-trim args-string)))
      nil
    (condition-case nil
        (json-parse-string args-string :object-type 'alist :array-type 'list)
      (error nil))))

(defun codetutor--fireworks-agent-body (model messages tool-choice)
  "Serialize a Fireworks chat-completions body with MESSAGES, tools, TOOL-CHOICE."
  (json-serialize
   `((model . ,model)
     (messages . ,(vconcat messages))
     (tools . ,(codetutor--tool-specs))
     (tool_choice . ,tool-choice)
     (max_tokens . ,codetutor-fireworks-max-tokens)
     (temperature . ,codetutor-fireworks-temperature))))

(defun codetutor--fireworks-agent-start (root kind title panel user-request file diff)
  "Begin an agentic Fireworks request for ROOT; return the first process or nil."
  (let ((api-key (codetutor--fireworks-api-key)))
    (if (null api-key)
        (codetutor--render-result
         panel root title
         (concat "No Fireworks AI API key is available. Set "
                 "`codetutor-fireworks-api-key', the FIREWORKS_API_KEY environment "
                 "variable, or an auth-source entry for host `api.fireworks.ai'."))
      (let* ((seed (codetutor--build-agent-seed-prompt
                    kind :root root :file file :diff diff
                    :user-request user-request))
             (ctx (list :current-file-context
                        (codetutor--current-file-context (or file buffer-file-name))))
             (messages (list `((role . "system") (content . ,codetutor-system-prompt))
                             `((role . "user") (content . ,seed))))
             (state (list :root root :kind kind :title title :panel panel
                          :user-request user-request
                          :api-key api-key
                          :ctx ctx
                          :messages messages
                          :iteration 0
                          :tool-calls 0
                          :prompt-tokens 0
                          :completion-tokens 0)))
        (codetutor--render-status panel root title "Fireworks AI" kind)
        (codetutor--fireworks-agent-step state)))))

(defun codetutor--fireworks-agent-step (state)
  "Send one Fireworks request for STATE; return the process."
  (let* ((root (plist-get state :root))
         (session (codetutor--session root))
         (model (or codetutor-model codetutor-fireworks-model))
         (endpoint (concat (string-remove-suffix "/" codetutor-fireworks-api-base)
                           "/chat/completions"))
         (tool-choice (if (>= (plist-get state :iteration)
                              codetutor-fireworks-max-tool-iterations)
                          "none" "auto"))
         (config-file (make-temp-file "codetutor-fireworks-config-"))
         (body-file (make-temp-file "codetutor-fireworks-body-" nil ".json"))
         (body (codetutor--fireworks-agent-body
                model (plist-get state :messages) tool-choice))
         (process-buffer (generate-new-buffer " *codetutor-process*")))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (codetutor--fireworks-curl-config (plist-get state :api-key))
                    nil config-file nil 'silent)
      (write-region body nil body-file nil 'silent))
    (let ((process
           (make-process
            :name "codetutor"
            :buffer process-buffer
            :connection-type 'pipe
            :noquery t
            :command (list codetutor-fireworks-command
                           "--silent" "--show-error" "--fail-with-body"
                           "--config" config-file
                           "--header" "Content-Type: application/json"
                           "--data" (concat "@" body-file)
                           endpoint)
            :sentinel
            (lambda (proc _event)
              (unless (process-live-p proc)
                (codetutor--fireworks-agent-handle
                 state proc process-buffer (list config-file body-file)))))))
      (set-process-query-on-exit-flag process nil)
      (setf (plist-get session :process) process)
      process)))

(cl-defun codetutor--fireworks-agent-handle (state process process-buffer temp-files)
  "Handle one Fireworks step exit for STATE: run tools and loop, or finalize."
  (let* ((root (plist-get state :root))
         (session (codetutor--session root))
         (title (plist-get state :title))
         (panel (plist-get state :panel))
         (status (process-exit-status process))
         (stdout (when (buffer-live-p process-buffer)
                   (with-current-buffer process-buffer
                     (buffer-substring-no-properties (point-min) (point-max))))))
    (dolist (file temp-files)
      (when (and file (file-exists-p file)) (ignore-errors (delete-file file))))
    (when (buffer-live-p process-buffer) (kill-buffer process-buffer))
    (when (process-get process :codetutor-canceled)
      (cl-return-from codetutor--fireworks-agent-handle nil))
    (when (eq (plist-get session :process) process)
      (setf (plist-get session :process) nil))
    (let ((data (codetutor--fireworks-parse-data stdout)))
      (if (null data)
          (codetutor--render-result
           panel root title
           (format "Fireworks request failed (status %s).\n\n%s"
                   status
                   (string-trim (or (codetutor--fireworks-parse-response stdout) ""))))
        (let* ((usage (codetutor--fireworks-usage data))
               (choice (car (alist-get 'choices data)))
               (message (alist-get 'message choice))
               (tool-calls (alist-get 'tool_calls message))
               (content (alist-get 'content message)))
          (cl-incf (plist-get state :prompt-tokens) (car usage))
          (cl-incf (plist-get state :completion-tokens) (cdr usage))
          (if (and tool-calls
                   (< (plist-get state :iteration)
                      codetutor-fireworks-max-tool-iterations))
              (codetutor--fireworks-agent-run-tools state message tool-calls)
            (codetutor--fireworks-agent-finalize
             state (if (stringp content) content ""))))))))

(defun codetutor--render-agent-status (state tool-calls)
  "Render a tool-call status line in the panel for STATE."
  (let ((panel (plist-get state :panel))
        (root (plist-get state :root))
        (title (plist-get state :title))
        (names (mapconcat (lambda (tc)
                            (alist-get 'name (alist-get 'function tc)))
                          tool-calls ", ")))
    (codetutor--replace
     panel
     (format "%sStatus: thinking\n\n## %s\n\nGathering context (round %d): %s\n"
             (codetutor--panel-header root)
             title
             (1+ (plist-get state :iteration))
             names))))

(defun codetutor--fireworks-agent-run-tools (state message tool-calls)
  "Append assistant MESSAGE + TOOL-CALLS results to STATE, then loop."
  (let* ((root (plist-get state :root))
         (ctx (plist-get state :ctx))
         (content (alist-get 'content message))
         (assistant `((role . "assistant")
                      ,@(when (stringp content) (list (cons 'content content)))
                      (tool_calls . ,(codetutor--normalize-tool-calls tool-calls))))
         (tool-msgs nil))
    (setf (plist-get state :messages)
          (append (plist-get state :messages) (list assistant)))
    (codetutor--render-agent-status state tool-calls)
    (dolist (tc tool-calls)
      (let* ((id (alist-get 'id tc))
             (fn (alist-get 'function tc))
             (name (alist-get 'name fn))
             (args (codetutor--parse-tool-arguments (alist-get 'arguments fn)))
             (result (codetutor--dispatch-tool root ctx name args)))
        (cl-incf (plist-get state :tool-calls))
        (push `((role . "tool") (tool_call_id . ,id) (content . ,result)) tool-msgs)))
    (setf (plist-get state :messages)
          (append (plist-get state :messages) (nreverse tool-msgs)))
    (cl-incf (plist-get state :iteration))
    (codetutor--fireworks-agent-step state)))

(defun codetutor--fireworks-agent-finalize (state raw)
  "Render RAW as the final answer for STATE and report token cost."
  (let* ((root (plist-get state :root))
         (session (codetutor--session root))
         (title (plist-get state :title))
         (panel (plist-get state :panel))
         (answer (string-trim (codetutor--answer-text raw))))
    (codetutor--apply-memory-updates root raw)
    (codetutor--record-turn root (plist-get state :kind)
                            (plist-get state :user-request) answer)
    (codetutor--render-result panel root title answer)
    (codetutor--report-cost session
                            (plist-get state :prompt-tokens)
                            (plist-get state :completion-tokens)
                            (plist-get state :tool-calls))))

(defun codetutor--read-existing-file (file)
  "Return FILE contents or an empty string when FILE does not exist."
  (if (file-readable-p file)
      (codetutor--read-file file most-positive-fixnum)
    ""))

(defun codetutor--read-file (file max-bytes)
  "Read at most MAX-BYTES from FILE as a string."
  (with-temp-buffer
    (let* ((size (file-attribute-size (file-attributes file)))
           (end (when (and (integerp max-bytes)
                           size
                           (< max-bytes size))
                  max-bytes))
           (coding-system-for-read 'utf-8))
      (insert-file-contents-literally file nil 0 end))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun codetutor--read-file-section (root file max-bytes)
  "Read FILE as a labeled context section relative to ROOT."
  (let ((relative (file-relative-name file root)))
    (format "### %s\n\n%s"
            relative
            (codetutor--read-file file max-bytes))))

(defun codetutor--project-context (root)
  "Return project context loaded from ROOT."
  (let* ((root-dir (file-name-as-directory (expand-file-name root)))
         (sections nil)
         (remaining codetutor-max-project-context-bytes))
    (dolist (name codetutor-project-files)
      (let ((file (expand-file-name name root-dir)))
        (when (and (> remaining 0) (file-readable-p file))
          (let ((section (codetutor--read-file-section root-dir file remaining)))
            (push section sections)
            (setq remaining (max 0 (- remaining (string-bytes section))))))))
    (let ((spec-root (expand-file-name codetutor-spec-directory root-dir)))
      (when (and (> remaining 0) (file-directory-p spec-root))
        (dolist (file (sort (directory-files-recursively spec-root codetutor-spec-file-regexp)
                            #'string<))
          (when (> remaining 0)
            (let ((section (codetutor--read-file-section root-dir file remaining)))
              (push section sections)
              (setq remaining (max 0 (- remaining (string-bytes section)))))))))
    (let ((memory (expand-file-name codetutor-memory-file root-dir)))
      (when (and (> remaining 0) (file-readable-p memory))
        (let ((section (codetutor--read-file-section root-dir memory remaining)))
          (push section sections)
          (setq remaining (max 0 (- remaining (string-bytes section)))))))
    (if sections
        (string-join (nreverse sections) "\n\n")
      "No PROJECT.md/Project.md/project.md, spec/, or architecture memory found yet.")))

(defun codetutor--project-file-index (root)
  "Return a readable project file index for ROOT."
  (let* ((root-dir (file-name-as-directory (expand-file-name root)))
         (files (codetutor--project-files root-dir))
         (limited (cl-subseq files 0 (min (length files)
                                          codetutor-max-file-index-entries))))
    (if limited
        (concat
         (string-join limited "\n")
         (when (> (length files) (length limited))
           (format "\n... %s more files omitted" (- (length files) (length limited)))))
      "No project files found.")))

(defun codetutor--project-files (root)
  "Return project files below ROOT as relative paths."
  (let ((files
         (condition-case nil
             (when-let ((project (project-current nil root)))
               (project-files project))
           (error nil))))
    (setq files
          (or files
              (codetutor--directory-files-fallback root)))
    (sort
     (cl-remove-if
      (lambda (file)
        (or (file-directory-p (expand-file-name file root))
            (string-prefix-p "." (file-name-nondirectory file))))
      (mapcar (lambda (file) (file-relative-name file root)) files))
     #'string<)))

(defun codetutor--directory-files-fallback (root)
  "Return a recursive file list below ROOT, excluding ignored directories."
  (let ((result nil))
    (cl-labels
        ((walk (dir)
           (dolist (entry (directory-files dir t "\\`[^.]"))
             (cond
              ((file-directory-p entry)
               (unless (member (file-name-nondirectory entry)
                               codetutor-ignored-directories)
                 (walk entry)))
              ((file-regular-p entry)
               (push entry result))))))
      (walk root))
    result))

(defun codetutor--current-file-context (file)
  "Return context for FILE and the current buffer."
  (string-join
   (delq
    nil
    (list
     (format "File: %s" (or file "No file-backed buffer"))
     (format "Major mode: %s" major-mode)
     (when file
       (format "Relative path: %s" (file-relative-name file (codetutor--project-root))))
     (format "Point line: %s" (line-number-at-pos))
     (format "Buffer size: %s chars" (buffer-size))
     (format "Tree-sitter / outline summary:\n%s" (codetutor--syntax-summary))
     (format "Current buffer text%s:\n%s"
             (if (> (buffer-size) codetutor-max-current-file-bytes)
                 " (truncated)"
               "")
             (codetutor--truncate
              (buffer-substring-no-properties (point-min) (point-max))
              codetutor-max-current-file-bytes))))
   "\n\n"))

(defun codetutor--open-buffers-context (root current-file)
  "Return context for other open file-backed buffers under ROOT.

CURRENT-FILE is excluded because it is already included in the main current
file context and save diff."
  (let* ((root-dir (file-name-as-directory (expand-file-name root)))
         (current (and current-file (expand-file-name current-file)))
         (buffers (codetutor--open-project-buffers root-dir current))
         (limited (cl-subseq buffers 0 (min (length buffers)
                                            codetutor-max-open-buffers)))
         (remaining codetutor-max-open-buffer-context-bytes)
         sections)
    (dolist (buffer limited)
      (when (> remaining 0)
        (let ((section (with-current-buffer buffer
                         (codetutor--open-buffer-section root-dir))))
          (push (codetutor--truncate
                 section
                 (min remaining codetutor-max-open-buffer-bytes))
                sections)
          (setq remaining
                (max 0 (- remaining (string-bytes (car sections))))))))
    (when sections
      (string-join (nreverse sections) "\n\n"))))

(defun codetutor--open-project-buffers (root current-file)
  "Return open file-backed buffers below ROOT, excluding CURRENT-FILE."
  (sort
   (cl-remove-if-not
    (lambda (buffer)
      (when-let ((file (buffer-local-value 'buffer-file-name buffer)))
        (let ((expanded (expand-file-name file)))
          (and (file-in-directory-p expanded root)
               (not (and current-file
                         (string= expanded current-file)))))))
    (buffer-list))
   (lambda (left right)
     (string< (or (buffer-local-value 'buffer-file-name left) "")
              (or (buffer-local-value 'buffer-file-name right) "")))))

(defun codetutor--open-buffer-section (root)
  "Return a context section for the current open file-backed buffer."
  (let ((file buffer-file-name))
    (format "### %s\nMajor mode: %s\nModified: %s\n\n%s"
            (if file (file-relative-name file root) (buffer-name))
            major-mode
            (if (buffer-modified-p) "yes" "no")
            (codetutor--truncate
             (buffer-substring-no-properties (point-min) (point-max))
             codetutor-max-open-buffer-bytes))))

(defun codetutor--syntax-summary ()
  "Return a tree-sitter or imenu summary for the current buffer."
  (or (codetutor--treesit-summary)
      (codetutor--imenu-summary)
      "No tree-sitter parser or imenu outline is available for this buffer."))

(defun codetutor--treesit-summary ()
  "Return a short tree-sitter summary for the current buffer, when available."
  (when (fboundp 'treesit-available-p)
    (condition-case nil
        (when (treesit-available-p)
          (codetutor--ensure-treesit-parser)
          (when-let ((root (treesit-buffer-root-node)))
            (let* ((parser (treesit-node-parser root))
                   (language (and parser (treesit-parser-language parser)))
                   (children (treesit-node-children root t))
                   (top (cl-subseq children 0 (min 30 (length children)))))
              (string-join
               (append
                (list (format "Language: %s" language)
                      (format "Root node: %s" (treesit-node-type root)))
                (mapcar #'codetutor--treesit-node-line top))
               "\n"))))
      (error nil))))

(defun codetutor--ensure-treesit-parser ()
  "Create a tree-sitter parser for the current major mode when possible."
  (when (and (fboundp 'treesit-parser-list)
             (null (treesit-parser-list))
             (fboundp 'treesit-language-available-p)
             (fboundp 'treesit-parser-create))
    (when-let ((language (alist-get major-mode codetutor-language-by-major-mode)))
      (when (treesit-language-available-p language)
        (ignore-errors (treesit-parser-create language))))))

(defun codetutor--treesit-node-line (node)
  "Return a one-line description of tree-sitter NODE."
  (let ((name (or (ignore-errors (treesit-defun-name node))
                  (codetutor--treesit-child-name node)))
        (start (line-number-at-pos (treesit-node-start node)))
        (end (line-number-at-pos (treesit-node-end node))))
    (format "- %s%s lines %s-%s"
            (treesit-node-type node)
            (if name (format " `%s`" name) "")
            start
            end)))

(defun codetutor--treesit-child-name (node)
  "Return a plausible name for NODE from a child field."
  (when-let ((name-node (or (treesit-node-child-by-field-name node "name")
                            (treesit-node-child-by-field-name node "key"))))
    (string-trim
     (treesit-node-text name-node t))))

(defun codetutor--imenu-summary ()
  "Return an imenu summary for the current buffer, when available."
  (condition-case nil
      (let ((index (imenu--make-index-alist t)))
        (setq index (codetutor--flatten-imenu index))
        (when index
          (string-join
           (mapcar (lambda (item)
                     (format "- %s" item))
                   (cl-subseq index 0 (min 30 (length index))))
           "\n")))
    (error nil)))

(defun codetutor--flatten-imenu (index)
  "Flatten imenu INDEX into display names."
  (cl-loop for item in index
           if (imenu--subalist-p item)
           append (codetutor--flatten-imenu (cdr item))
           else if (and (consp item) (stringp (car item)))
           collect (car item)))

(defun codetutor--unified-diff (before after file)
  "Return a unified diff from BEFORE to AFTER for FILE."
  (let ((old-file (make-temp-file "codetutor-before-"))
        (new-file (make-temp-file "codetutor-after-"))
        (label (or file "buffer"))
        diff)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (write-region before nil old-file nil 'silent)
            (write-region after nil new-file nil 'silent))
          (setq diff
                (with-temp-buffer
                  (let ((exit (call-process "diff" nil t nil
                                            "-u"
                                            "--label" (concat label " (before)")
                                            "--label" (concat label " (after)")
                                            old-file
                                            new-file)))
                    (when (memq exit '(0 1))
                      (buffer-substring-no-properties (point-min) (point-max)))))))
      (ignore-errors (delete-file old-file))
      (ignore-errors (delete-file new-file)))
    diff))

(defun codetutor--backend-answer (stdout output-file)
  "Return backend answer text from OUTPUT-FILE or STDOUT.

Codex can write the final assistant message to OUTPUT-FILE.  Prefer that over
STDOUT because STDOUT may contain command progress or transcript output."
  (let ((file-output
         (when (and output-file
                    (file-readable-p output-file)
                    (> (file-attribute-size (file-attributes output-file)) 0))
           (codetutor--read-file output-file most-positive-fixnum))))
    (or file-output stdout "")))

(defun codetutor--answer-text (text)
  "Return displayable answer text from backend TEXT."
  (let* ((plain (codetutor--strip-ansi (or text "")))
         (visible (or (codetutor--extract-answer-block plain)
                      plain)))
    (string-trim
     (codetutor--strip-memory-blocks visible))))

(defun codetutor--extract-answer-block (text)
  "Extract a <codetutor-answer> block from TEXT, or nil."
  (when (string-match
         "<codetutor-answer>[[:space:]\n\r]*\\(\\(?:.\\|\n\\)*?\\)[[:space:]\n\r]*</codetutor-answer>"
         text)
    (match-string 1 text)))

(defun codetutor--strip-ansi (text)
  "Remove ANSI escape sequences from TEXT."
  (replace-regexp-in-string
   "\x1b\\[[0-?]*[ -/]*[@-~]"
   ""
   text))

(defun codetutor--truncate (text max-bytes)
  "Return TEXT truncated to MAX-BYTES bytes."
  (if (<= (string-bytes text) max-bytes)
      text
    (concat
     (decode-coding-string
      (substring (encode-coding-string text 'utf-8) 0 max-bytes)
      'utf-8 t)
     "\n\n[Truncated by CodeTutor]\n")))

(defun codetutor--strip-memory-blocks (text)
  "Remove codetutor-memory fenced blocks from TEXT."
  (replace-regexp-in-string
   "```codetutor-memory\n\\(?:.\\|\n\\)*?```"
   ""
   text))

(defun codetutor--memory-lines (text)
  "Extract durable memory lines from codetutor-memory fenced blocks in TEXT."
  (let ((start 0)
        lines)
    (while (string-match "```codetutor-memory\n\\(\\(?:.\\|\n\\)*?\\)```" text start)
      (setq start (match-end 0))
      (setq lines
            (append lines
                    (cl-remove-if
                     #'string-empty-p
                     (mapcar #'string-trim
                             (split-string (match-string 1 text) "\n"))))))
    lines))

(defun codetutor--apply-memory-updates (root text)
  "Append durable memory updates from TEXT to ROOT memory file."
  (when codetutor-apply-memory-updates
    (let* ((lines (codetutor--memory-lines (or text "")))
           (root-dir (file-name-as-directory (expand-file-name root)))
           (memory-file (expand-file-name codetutor-memory-file root-dir)))
      (when lines
        (make-directory (file-name-directory memory-file) t)
        (let* ((existing (if (file-readable-p memory-file)
                             (codetutor--read-file memory-file most-positive-fixnum)
                           ""))
               (new-lines (cl-remove-if
                           (lambda (line) (string-match-p (regexp-quote line) existing))
                           lines)))
          (when new-lines
            (let ((codetutor--writing-memory t)
                  (coding-system-for-write 'utf-8))
              (with-temp-buffer
                (unless (string-empty-p existing)
                  (insert existing)
                  (unless (string-suffix-p "\n" existing)
                    (insert "\n")))
                (when (string-empty-p existing)
                  (insert "# CodeTutor Architecture Memory\n\n")
                  (insert "Durable notes captured from tutor sessions. Edit freely.\n\n")
                  (insert "## Notes\n\n"))
                (dolist (line new-lines)
                  (insert line "\n"))
                (write-region (point-min) (point-max) memory-file nil 'silent)))))))))

;;; Spec development mode ----------------------------------------------------

(defun codetutor--spec-slug (name)
  "Return a `<slug>.md' filename derived from spec NAME."
  (let* ((down (downcase (string-trim name)))
         (dashed (replace-regexp-in-string "[^a-z0-9]+" "-" down))
         (trimmed (replace-regexp-in-string "\\(\\`-+\\|-+\\'\\)" "" dashed)))
    (concat (if (string-empty-p trimmed) "spec" trimmed) ".md")))

(defun codetutor--spec-file-p (file root)
  "Return non-nil when FILE is inside ROOT's spec directory.

This is a lexical path check, so it does not require the directory to exist."
  (and file
       (let ((spec-dir (file-name-as-directory
                        (expand-file-name
                         codetutor-spec-directory
                         (file-name-as-directory (expand-file-name root))))))
         (string-prefix-p spec-dir (expand-file-name file)))))

(defun codetutor--active-spec (root)
  "Return the active spec file for ROOT, or nil."
  (plist-get (codetutor--session root) :active-spec))

(defun codetutor--set-active-spec (root file)
  "Set FILE as the active spec for ROOT (FILE may be nil to clear)."
  (let ((session (codetutor--session root)))
    (setf (plist-get session :active-spec) file)))

(defun codetutor--spec-sections (text)
  "Return an alist of (TITLE . BODY) for each `## ' section in TEXT."
  (let ((case-fold-search nil)
        (sections nil)
        (start 0))
    (while (string-match "^## +\\(.+\\)$" text start)
      (let* ((title (string-trim (match-string 1 text)))
             (body-start (match-end 0))
             (next (if (string-match "^## +.+$" text body-start)
                       (match-beginning 0)
                     (length text)))
             (body (substring text body-start next)))
        (push (cons title (string-trim body)) sections)
        (setq start next)))
    (nreverse sections)))

(defun codetutor--spec-section-at (text line)
  "Return the `## ' section title that 1-based LINE falls under in TEXT, or nil."
  (let ((case-fold-search nil)
        (n 0)
        (current nil))
    (catch 'done
      (dolist (l (split-string text "\n"))
        (setq n (1+ n))
        (when (> n line) (throw 'done current))
        (when (string-match "^## +\\(.+\\)" l)
          (setq current (string-trim (match-string 1 l))))))
    current))

(defun codetutor--spec-section-filled-p (body)
  "Return non-nil when section BODY has content beyond its guiding comment."
  (let ((stripped (string-trim
                   (replace-regexp-in-string "<!--\\(?:.\\|\n\\)*?-->" "" body))))
    (not (string-empty-p stripped))))

(defun codetutor--spec-empty-sections (text)
  "Return the list of section titles in TEXT that are still empty."
  (delq nil
        (mapcar (lambda (section)
                  (unless (codetutor--spec-section-filled-p (cdr section))
                    (car section)))
                (codetutor--spec-sections text))))

(defun codetutor--spec-context (root &optional diff)
  "Return a prompt context string about ROOT's active spec, or nil.

When DIFF is a unified diff of the spec itself, the section the user just
edited is identified and named."
  (let ((spec (codetutor--active-spec root)))
    (when (and spec (file-readable-p spec))
      (let* ((text (codetutor--read-file spec most-positive-fixnum))
             (touched (when diff
                        (codetutor--spec-section-at
                         text (or (codetutor--diff-touched-line diff) 1))))
             (empty (codetutor--spec-empty-sections text))
             (filled (cl-remove-if (lambda (s) (member (car s) empty))
                                   (codetutor--spec-sections text))))
        (string-join
         (delq
          nil
          (list
           (format "ACTIVE SPEC: %s" (file-relative-name spec root))
           (when touched
             (format "SECTION JUST EDITED: %s" touched))
           (format "SECTIONS WITH CONTENT: %s"
                   (if filled (mapconcat #'car filled ", ") "none yet"))
           (format "SECTIONS STILL EMPTY: %s"
                   (if empty (string-join empty ", ") "none"))))
         "\n")))))

(defun codetutor--diff-touched-line (diff)
  "Return a representative changed new-file line number in DIFF, or nil."
  (let ((newline-no nil)
        (result nil))
    (catch 'done
      (dolist (l (split-string diff "\n"))
        (cond
         ((string-match "^@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" l)
          (setq newline-no (string-to-number (match-string 1 l))))
         ((null newline-no) nil)
         ((string-prefix-p "+++" l) nil)
         ((string-prefix-p "+" l)
          (setq result newline-no)
          (throw 'done result))
         ((string-prefix-p "-" l) nil)
         (t (setq newline-no (1+ newline-no))))))
    result))

(defun codetutor--spec-instruction (kind)
  "Return the teach-only posture instruction for spec request KIND."
  (pcase kind
    ('spec "SPEC MODE (teach-only):
- You are co-developing a feature spec with the user. Teach them to write a strong spec; never write the spec body for them.
- Critique the section they just edited; name missing requirements, acceptance criteria, edge cases, and non-goals.
- Ask one sharp question and point them to the next empty section.
- When teaching the Build plan, teach how to decompose and sequence small, testable slices and critique the user's slices. Do not enumerate the tasks for them.")
    ('spec-implement "BUILD MODE (teach-only):
- The user is writing code toward the active spec above. Teach, never write the code.
- Tie the change to the spec: which requirement it advances, whether it meets the acceptance criteria, what is still missing.
- Teach the next build slice and the test that would prove it.")))

(defun codetutor--save-request (kind touched)
  "Return the user-request string for a save of KIND (TOUCHED section optional)."
  (pcase kind
    ('spec (format "I just edited my spec%s. Review it as a teaching pair-partner: critique what I wrote, name missing requirements, edge cases, or non-goals, and ask the sharpest next question. Point me to the next section to work on. Do not write the spec for me."
                   (if touched (format " (the \"%s\" section)" touched) "")))
    ('spec-implement "I just changed code while building toward the active spec. Teach me whether this moves a requirement forward, what the next build slice should be, and what test would prove it. Reference the spec. Do not write the code for me.")
    (_ "Review my diff from this save as a teaching pair-programmer. Teach the concept behind the most important feedback, identify risks or architectural implications, and give me one next move. Do not write the code for me.")))

(defun codetutor--save-title (kind file root)
  "Return the panel title for a save of KIND for FILE under ROOT."
  (pcase kind
    ('spec (format "Spec Review: %s" (file-relative-name file root)))
    ('spec-implement (format "Build Review: %s" (file-relative-name file root)))
    (_ (format "Save Review: %s" (file-relative-name file root)))))

(defun codetutor--save-kind (file root)
  "Return the tutor request kind for saving FILE in ROOT.

`spec' when FILE is a spec document, `spec-implement' when FILE is code and a
spec is active, otherwise `save'."
  (cond
   ((codetutor--spec-file-p file root) 'spec)
   ((codetutor--active-spec root) 'spec-implement)
   (t 'save)))

(defvar codetutor--spec-name-history nil
  "Minibuffer history of spec names.")

(defun codetutor--spec-window-height ()
  "Return the spec-mode tutor panel height in lines."
  (if (floatp codetutor-spec-window-height)
      (max 8 (round (* (frame-height) codetutor-spec-window-height)))
    codetutor-spec-window-height))

(defun codetutor--display-spec-layout (root spec-file)
  "Show SPEC-FILE in the main window and the tutor panel below it for ROOT."
  (delete-other-windows)
  (let ((spec-buffer (find-file-noselect spec-file)))
    (switch-to-buffer spec-buffer)
    (display-buffer-in-side-window
     (codetutor--panel-buffer root)
     `((side . bottom)
       (slot . 1)
       (window-height . ,(codetutor--spec-window-height))))
    spec-buffer))

(defun codetutor--spec-kickoff (root)
  "Start a proactive spec-writing interview for ROOT."
  (let ((request "I am starting a brand-new spec for a feature. Interview me to begin: ask what problem this solves and who it is for, and teach me what makes a strong problem statement. Do not write the spec for me."))
    (codetutor--request
     :root root :kind 'spec :title "New Spec" :manual t
     :user-request request
     :prompt (codetutor--build-prompt 'spec :root root :user-request request))))

;;;###autoload
(defun codetutor-new-spec (name)
  "Start a new feature spec named NAME and open the spec workbench.

Creates `spec/<slug>.md' from `codetutor-spec-template' (when it does not yet
exist), makes it the active spec, opens the spec document above the tutor
panel, and starts a proactive tutoring interview."
  (interactive
   (list (read-string "Spec name: " nil 'codetutor--spec-name-history)))
  (when (string-empty-p (string-trim name))
    (user-error "Spec name must not be empty"))
  (let* ((root (codetutor--project-root))
         (spec-dir (expand-file-name codetutor-spec-directory root))
         (file (expand-file-name (codetutor--spec-slug name) spec-dir))
         (new (not (file-exists-p file))))
    (make-directory spec-dir t)
    (when new
      (let ((coding-system-for-write 'utf-8))
        (write-region
         (replace-regexp-in-string "{name}" name codetutor-spec-template nil t)
         nil file nil 'silent)))
    (codetutor--set-active-spec root file)
    (codetutor--display-spec-layout root file)
    (when (and new codetutor-spec-kickoff)
      (codetutor--spec-kickoff root))
    file))

;;;###autoload
(defun codetutor-open-spec ()
  "Open an existing spec as the active spec and show the spec workbench."
  (interactive)
  (let* ((root (codetutor--project-root))
         (spec-dir (expand-file-name codetutor-spec-directory root)))
    (unless (file-directory-p spec-dir)
      (user-error "No `%s/' directory yet; use `codetutor-new-spec'"
                  codetutor-spec-directory))
    (let ((files (directory-files spec-dir nil "\\.md\\'")))
      (unless files
        (user-error "No spec documents found in `%s/'" codetutor-spec-directory))
      (let ((choice (completing-read "Open spec: " files nil t)))
        (unless (string-empty-p choice)
          (let ((file (expand-file-name choice spec-dir)))
            (codetutor--set-active-spec root file)
            (codetutor--display-spec-layout root file)))))))

;;;###autoload
(defun codetutor-finish-spec ()
  "Clear the active spec so saves return to the normal review posture."
  (interactive)
  (codetutor--set-active-spec (codetutor--project-root) nil)
  (message "CodeTutor: active spec cleared."))

(provide 'codetutor)

;;; codetutor.el ends here
