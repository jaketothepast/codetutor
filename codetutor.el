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

;; CodeTutor is split across modules; this umbrella loads them in order.
(require 'codetutor-vars)
(require 'codetutor-backend)
(require 'codetutor-tools)
(require 'codetutor-agent)
(require 'codetutor-inline-tips)

(defvar codetutor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t o") #'codetutor-open)
    (define-key map (kbd "C-c t n") #'codetutor-what-next)
    (define-key map (kbd "C-c t a") #'codetutor-ask)
    (define-key map (kbd "C-c t f") #'codetutor-follow-up)
    (define-key map (kbd "C-c t m") #'codetutor-refresh-architecture-memory)
    (define-key map (kbd "C-c t s") #'codetutor-new-spec)
    (define-key map (kbd "C-c t S") #'codetutor-open-spec)
    (define-key map (kbd "C-c t t") #'codetutor-scratch)
    (define-key map (kbd "C-c t i") #'codetutor-inline-tips)
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
  :group 'codetutor
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

(defconst codetutor--inline-tips-request
  "Read the code file I am editing and place short teaching annotations on the most valuable specific lines. Call annotate_line once per tip (between 3 and 8 tips), each 1-3 sentences. Then give me a one-paragraph summary of the themes. Do not write the code for me."
  "User-request string sent for an inline-tips run.")

;;;###autoload
(defun codetutor-inline-tips ()
  "Annotate the current code buffer with inline teaching tips from CodeTutor.
The tutor reads the buffer and places short annotations on specific lines
via the `annotate_line' tool.  Requires the Fireworks agentic backend.

Refuses to run on spec documents, the CodeTutor scratch buffer, the tutor
panel, or any non-file-backed buffer."
  (interactive)
  (let ((buffer (current-buffer))
        (file buffer-file-name)
        (root (codetutor--project-root)))
    ;; Reject panel / scratch first so the message is specific (both are
    ;; non-file buffers and would otherwise hit the generic check).
    (when (derived-mode-p 'codetutor-panel-mode)
      (user-error "Run inline tips from a code buffer, not the CodeTutor panel"))
    (when (bound-and-true-p codetutor-scratch-mode)
      (user-error "Inline tips do not apply to the CodeTutor scratch buffer"))
    (unless file
      (user-error "CodeTutor inline tips need a file-backed buffer"))
    (when (codetutor--spec-file-p file root)
      (user-error "Inline tips are for code files, not spec documents"))
    (unless (and (eq (codetutor--select-backend) 'fireworks)
                 codetutor-fireworks-use-tools)
      (user-error "Inline tips require the Fireworks agentic backend (set `codetutor-backend' to `fireworks' and keep `codetutor-fireworks-use-tools' non-nil)"))
    (codetutor-clear-inline-tips buffer)
    (codetutor--display-panel root)
    (codetutor--request
     :root root
     :kind 'inline-tips
     :title "Inline Tips"
     :manual t
     :file file
     :user-request codetutor--inline-tips-request
     :target-buffer buffer
     :prompt (codetutor--build-prompt
              'inline-tips :root root :file file
              :user-request codetutor--inline-tips-request))))

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

(cl-defun codetutor--request (&key root kind title prompt manual user-request
                                   file diff target-buffer)
  "Run a tutor request for ROOT with KIND, TITLE, and PROMPT.

MANUAL requests cancel an active request.  Automatic requests may be skipped
when `codetutor-skip-auto-request-while-busy' is non-nil.

When the Fireworks backend is selected and `codetutor-fireworks-use-tools' is
non-nil, the request runs as an agentic tool-calling loop that builds its own
lean prompt from KIND, FILE, DIFF, and USER-REQUEST instead of PROMPT.
TARGET-BUFFER, when given (inline-tips runs), is the code buffer the agent
annotates; it is threaded into the agent context."
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
         root kind title panel user-request file diff target-buffer)))
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
                :coding 'utf-8
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
         (posture-instruction (codetutor--kind-instruction kind))
         (pinned-context (codetutor--pinned-context project-root))
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
       (when pinned-context
         (format "PINNED CONTEXT (always included while open):\n\n%s" pinned-context))
       (when conversation-context
         (format "RECENT CONVERSATION:\n%s" conversation-context))
       (when spec-context
         (format "SPEC STATUS:\n%s" spec-context))
       posture-instruction
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
  "Display and return the CodeTutor panel buffer for ROOT.

The panel docks per `codetutor-panel-side' (bottom by default, matching the
spec/scratch workbench; or right).  When the panel is already visible (for
example in the spec workbench's bottom window) it is reused rather than
opened a second time."
  (let ((buffer (codetutor--panel-buffer root)))
    (unless (get-buffer-window buffer)
      (display-buffer-in-side-window
       buffer
       (if (eq codetutor-panel-side 'right)
           `((side . right)
             (slot . 1)
             (window-width . ,(codetutor--window-width)))
         `((side . bottom)
           (slot . 1)
           (window-height . ,(codetutor--panel-height))))))
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
  "Return the right side-window width in columns."
  (if (floatp codetutor-window-width)
      (max 40 (round (* (frame-width) codetutor-window-width)))
    codetutor-window-width))

(defun codetutor--panel-height ()
  "Return the bottom panel height in lines."
  (if (floatp codetutor-panel-height)
      (max 8 (round (* (frame-height) codetutor-panel-height)))
    codetutor-panel-height))


(defun codetutor--read-existing-file (file)
  "Return FILE contents or an empty string when FILE does not exist."
  (if (file-readable-p file)
      (codetutor--read-file file most-positive-fixnum)
    ""))

(defun codetutor--read-file (file max-bytes)
  "Read at most MAX-BYTES from FILE as a UTF-8 string.

The byte range is read literally (so MAX-BYTES stays byte-accurate) and then
decoded as UTF-8, so multibyte characters are not left as raw bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let* ((size (file-attribute-size (file-attributes file)))
           (end (when (and (integerp max-bytes)
                           size
                           (< max-bytes size))
                  max-bytes)))
      (insert-file-contents-literally file nil 0 end))
    (decode-coding-string
     (buffer-substring-no-properties (point-min) (point-max))
     'utf-8)))

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

(defun codetutor--numbered-buffer-text ()
  "Return the current buffer's text with a 1-based line-number prefix per line."
  (let ((lines (split-string (buffer-substring-no-properties (point-min) (point-max))
                             "\n"))
        (n 0))
    (mapconcat (lambda (line)
                 (setq n (1+ n))
                 (format "%d| %s" n line))
               lines "\n")))

(defun codetutor--current-file-context (file &optional numbered)
  "Return context for FILE and the current buffer.
When NUMBERED is non-nil, the buffer text is shown with line-number prefixes
so callers (e.g. inline tips) can target lines reliably."
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
              (if numbered
                  (codetutor--numbered-buffer-text)
                (buffer-substring-no-properties (point-min) (point-max)))
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

(defconst codetutor--scratch-instruction
  "SCRATCH MODE (teach-only):
- The user is thinking out loud while building, in the SCRATCH notes pinned above. Respond to their latest thoughts and questions.
- Teach the next concrete move and the concept behind it; never write the code for them.
- Be tight and practical: they are mid-build, not reading an essay."
  "Teach-only posture for scratch (thoughts) requests.")

(defconst codetutor--inline-tips-instruction
  "INLINE TIPS MODE (teach-only):
- The user wants short teaching annotations placed directly on lines of the current code file.
- Read the file first with read_current_file (it returns line-numbered text) before annotating.
- For each teaching point, call annotate_line with the 1-based line number and a 1-3 sentence tip. Favor concepts, risks, naming, design tradeoffs, and edge cases over restating the code.
- Annotate only the most valuable lines: at least 3 and at most 8. Do not annotate every line.
- Never write replacement code. After placing the tips, give a short one-paragraph summary of the themes as your final answer."
  "Teach-only posture for inline-tips requests.")

(defun codetutor--kind-instruction (kind)
  "Return the teach-only posture instruction for request KIND, or nil."
  (pcase kind
    ((or 'spec 'spec-implement) (codetutor--spec-instruction kind))
    ('scratch codetutor--scratch-instruction)
    ('inline-tips codetutor--inline-tips-instruction)
    (_ nil)))

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

(defun codetutor--display-workbench (root top-buffer)
  "Show TOP-BUFFER in the main window and the tutor panel below it for ROOT."
  (let ((panel (codetutor--panel-buffer root)))
    ;; Close any window already showing the panel (e.g. the right side window
    ;; from a prior request) so the workbench has exactly one panel window.
    (dolist (win (get-buffer-window-list panel nil t))
      (when (window-live-p win)
        (ignore-errors (delete-window win))))
    (delete-other-windows)
    (switch-to-buffer top-buffer)
    (display-buffer-in-side-window
     panel
     `((side . bottom)
       (slot . 1)
       (window-height . ,(codetutor--spec-window-height))))
    top-buffer))

(defun codetutor--display-spec-layout (root spec-file)
  "Show SPEC-FILE in the main window and the tutor panel below it for ROOT."
  (codetutor--display-workbench root (find-file-noselect spec-file)))

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

;;; Scratch (thoughts) buffer + pinned context ------------------------------

(defvar-local codetutor--scratch-root nil
  "Project root associated with a CodeTutor scratch buffer.")

(defun codetutor--scratch-buffer-name (root)
  "Return the scratch buffer name for ROOT."
  (format "*CodeTutor Scratch: %s*"
          (directory-file-name
           (file-name-nondirectory
            (directory-file-name (file-name-as-directory (expand-file-name root)))))))

(defun codetutor--scratch-buffer-if-live (root)
  "Return ROOT's scratch buffer if it exists, else nil."
  (get-buffer (codetutor--scratch-buffer-name root)))

(defun codetutor--open-spec-buffers (root)
  "Return live buffers visiting spec files under ROOT."
  (cl-remove-if-not
   (lambda (buf)
     (let ((file (buffer-local-value 'buffer-file-name buf)))
       (and file (codetutor--spec-file-p file root))))
   (buffer-list)))

(defun codetutor--pinned-context (root)
  "Return labeled pinned-context sections for ROOT, or nil.

Pins open spec documents (their live, possibly-unsaved text) and the scratch
buffer so they ride in every prompt while open."
  (let (sections)
    (dolist (buf (codetutor--open-spec-buffers root))
      (with-current-buffer buf
        (push (format "PINNED SPEC DOCUMENT — %s%s:\n%s"
                      (file-relative-name buffer-file-name root)
                      (if (buffer-modified-p) " (unsaved edits)" "")
                      (codetutor--truncate
                       (buffer-substring-no-properties (point-min) (point-max))
                       codetutor-max-current-file-bytes))
              sections)))
    (let ((scratch (codetutor--scratch-buffer-if-live root)))
      (when scratch
        (with-current-buffer scratch
          (let ((text (string-trim
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (unless (string-empty-p text)
              (push (format "SCRATCH — the user's live thoughts, notes, and questions while building (treat as the current focus; teach against these):\n%s"
                            (codetutor--truncate text codetutor-scratch-max-bytes))
                    sections))))))
    (when sections
      (string-join (nreverse sections) "\n\n"))))

(defvar codetutor-scratch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-s") #'codetutor-scratch-submit)
    (define-key map (kbd "C-c C-c") #'codetutor-scratch-submit)
    (define-key map (kbd "C-c C-k") #'codetutor-scratch-clear)
    map)
  "Keymap for `codetutor-scratch-mode'.")

(define-minor-mode codetutor-scratch-mode
  "Minor mode for the CodeTutor scratch (thoughts) buffer.

Saving the buffer submits your thoughts to the tutor instead of writing a file."
  :lighter " Scratch"
  :keymap codetutor-scratch-mode-map
  (setq-local buffer-offer-save nil))

(defun codetutor--scratch-buffer (root)
  "Return (creating if needed) the scratch buffer for ROOT."
  (let ((buffer (get-buffer-create (codetutor--scratch-buffer-name root))))
    (with-current-buffer buffer
      (unless (bound-and-true-p codetutor-scratch-mode)
        (codetutor-scratch-mode 1)
        (setq codetutor--scratch-root root)))
    buffer))

;;;###autoload
(defun codetutor-scratch ()
  "Open the CodeTutor scratch buffer for thinking out loud while building.

Type thoughts and questions, then save (\\[codetutor-scratch-submit]) to ask
the tutor.  The scratch buffer is ephemeral but persists for the session; clear
it with \\[codetutor-scratch-clear].  Its contents are pinned into every tutor
request while it has text."
  (interactive)
  (let* ((root (codetutor--project-root))
         (buffer (codetutor--scratch-buffer root)))
    (codetutor--display-workbench root buffer)
    (message "CodeTutor scratch: jot thoughts, then C-x C-s (or C-c C-c) to ask; C-c C-k clears.")
    buffer))

;;;###autoload
(defun codetutor-scratch-submit ()
  "Submit the scratch buffer's thoughts to the tutor (teach-only)."
  (interactive)
  (let* ((root (or codetutor--scratch-root (codetutor--project-root)))
         (text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (request "Respond to my latest thoughts and questions in the scratch notes. Teach me the next move as I build, and keep it tight. Do not write the code for me."))
    (if (string-empty-p text)
        (message "CodeTutor scratch is empty.")
      (codetutor--display-panel root)
      (codetutor--request
       :root root :kind 'scratch :title "Scratch" :manual t
       :user-request request
       :prompt (codetutor--build-prompt 'scratch :root root :user-request request)))))

;;;###autoload
(defun codetutor-scratch-clear ()
  "Clear the CodeTutor scratch buffer."
  (interactive)
  (let ((buffer (or (and codetutor--scratch-root
                         (codetutor--scratch-buffer-if-live codetutor--scratch-root))
                    (codetutor--scratch-buffer-if-live (codetutor--project-root)))))
    (if (null buffer)
        (message "No CodeTutor scratch buffer.")
      (with-current-buffer buffer (erase-buffer))
      (message "CodeTutor scratch cleared."))))

(provide 'codetutor)

;;; codetutor.el ends here
