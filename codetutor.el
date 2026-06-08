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
;; The tutor is intentionally read-only.  The default backends are local
;; Codex CLI and pi.dev CLI invocations configured so the model can inspect
;; context but cannot apply edits.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'imenu)
(require 'treesit nil t)

(defgroup codetutor nil
  "A read-only senior engineer tutor for Emacs."
  :group 'tools
  :prefix "codetutor-")

(defcustom codetutor-backend 'auto
  "Backend used for tutor requests.

`auto' prefers Codex when available, then pi.dev.  `codex' uses
`codex exec' with a read-only sandbox.  `pi' uses `pi --print'
with only read/grep/find/ls tools enabled."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Codex CLI" codex)
                 (const :tag "pi.dev CLI" pi)))

(defcustom codetutor-codex-command "codex"
  "Command used to run the Codex CLI."
  :type 'string)

(defcustom codetutor-pi-command "pi"
  "Command used to run the pi.dev CLI."
  :type 'string)

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
  "Ask CodeTutor to inspect context and recommend the best next step."
  (interactive)
  (codetutor--display-panel (codetutor--project-root))
  (codetutor--request
   :root (codetutor--project-root)
   :kind 'what-next
   :title "What Next"
   :manual t
   :user-request "Recommend the single best next step for this project right now. Search or inspect files if useful. Teach me why that step matters and what concept I should pay attention to while doing it."
   :prompt (codetutor--build-prompt
            'what-next
            :user-request "Recommend the single best next step for this project right now. Search or inspect files if useful. Teach me why that step matters and what concept I should pay attention to while doing it.")))

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

(cl-defun codetutor--request (&key root kind title prompt manual user-request)
  "Run a tutor request for ROOT with KIND, TITLE, and PROMPT.

MANUAL requests cancel an active request.  Automatic requests may be skipped
when `codetutor-skip-auto-request-while-busy' is non-nil."
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
    (let* ((backend (codetutor--backend-command root prompt))
           (backend-name (plist-get backend :name))
           (command (plist-get backend :command))
           (stdin (plist-get backend :stdin))
           (output-file (plist-get backend :output-file))
           (temp-files (plist-get backend :temp-files))
           (process-buffer (generate-new-buffer " *codetutor-process*")))
      (if (null command)
          (progn
            (kill-buffer process-buffer)
            (codetutor--render-result
             panel
             root
             title
             "No CodeTutor backend is available. Install `codex` or `pi`, or customize `codetutor-backend`."))
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
                     proc event root title panel process-buffer output-file temp-files))))))
          (set-process-query-on-exit-flag process nil)
          (process-put process :kind kind)
          (process-put process :user-request user-request)
          (setf (plist-get session :process) process)
          (when stdin
            (process-send-string process stdin)
            (process-send-eof process))
          process)))))

(defun codetutor--handle-process-exit
    (process event root title panel process-buffer output-file temp-files)
  "Handle tutor PROCESS EVENT for ROOT and render output in PANEL."
  (let* ((session (codetutor--session root))
         (status (process-exit-status process))
         (stdout (when (buffer-live-p process-buffer)
                   (with-current-buffer process-buffer
                     (buffer-substring-no-properties (point-min) (point-max)))))
         (answer-raw (codetutor--backend-answer stdout output-file))
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
            (codetutor--render-result panel root title answer))
        (codetutor--render-result
         panel
         root
         title
         (format "Tutor backend exited with status %s (%s).\n\n%s"
                 status
                 (string-trim event)
                 (string-trim (codetutor--answer-text stdout))))))))

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
            (codetutor--display-panel root)
            (codetutor--request
             :root root
             :kind 'save
             :title (format "Save Review: %s" (file-relative-name file root))
             :manual nil
             :user-request "Review my diff from this save as a teaching pair-programmer. Teach the concept behind the most important feedback, identify risks or architectural implications, and give me one next move. Do not write the code for me."
             :prompt (codetutor--build-prompt
                      'save
                      :root root
                      :file file
                      :diff diff
                      :user-request "Review my diff from this save as a teaching pair-programmer. Teach the concept behind the most important feedback, identify risks or architectural implications, and give me one next move. Do not write the code for me."))))))))

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
                 (list :started nil :process nil :turns nil :last-answer nil)
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
    (_
     (list :name nil :command nil))))

(defun codetutor--select-backend ()
  "Select an available backend."
  (pcase codetutor-backend
    ('codex (when (executable-find codetutor-codex-command) 'codex))
    ('pi (when (executable-find codetutor-pi-command) 'pi))
    ('auto (cond
            ((executable-find codetutor-codex-command) 'codex)
            ((executable-find codetutor-pi-command) 'pi)))))

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

(provide 'codetutor)

;;; codetutor.el ends here
