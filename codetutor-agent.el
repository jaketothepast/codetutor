;;; codetutor-agent.el --- Fireworks agentic loop for CodeTutor -*- lexical-binding: t; -*-

;; This file is part of CodeTutor; see codetutor.el for the package header.

;;; Commentary:

;; The Fireworks AI agentic tool-calling loop: it seeds a lean prompt,
;; lets the model pull context with the read-only tools, runs the tool
;; calls, and finalizes the answer.  Each round is a separate curl
;; process whose sentinel drives the next step.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'codetutor-vars)
(require 'codetutor-backend)
(require 'codetutor-tools)

;; Defined in the umbrella core (codetutor.el); declared here because the
;; agent sits below the core in the dependency graph and must not require it.
(declare-function codetutor--project-root "codetutor")
(declare-function codetutor--conversation-context "codetutor")
(declare-function codetutor--syntax-summary "codetutor")
(declare-function codetutor--project-file-index "codetutor")
(declare-function codetutor--spec-context "codetutor")
(declare-function codetutor--kind-instruction "codetutor")
(declare-function codetutor--pinned-context "codetutor")
(declare-function codetutor--truncate "codetutor")
(declare-function codetutor--current-file-context "codetutor")
(declare-function codetutor--session "codetutor")
(declare-function codetutor--render-status "codetutor")
(declare-function codetutor--render-result "codetutor")
(declare-function codetutor--panel-header "codetutor")
(declare-function codetutor--replace "codetutor")
(declare-function codetutor--answer-text "codetutor")
(declare-function codetutor--apply-memory-updates "codetutor")
(declare-function codetutor--record-turn "codetutor")

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
         (posture-instruction (codetutor--kind-instruction kind))
         (pinned-context (codetutor--pinned-context project-root))
         (diff-text (when diff (codetutor--truncate diff codetutor-max-diff-bytes))))
    (string-join
     (delq
      nil
      (list
       (format "REQUEST TYPE: %s" kind)
       (format "PROJECT ROOT:\n%s" project-root)
       (when user-request (format "USER REQUEST:\n%s" user-request))
       (when pinned-context
         (format "PINNED CONTEXT (always included while open):\n\n%s" pinned-context))
       (when conversation (format "RECENT CONVERSATION:\n%s" conversation))
       (when spec-context (format "SPEC STATUS:\n%s" spec-context))
       posture-instruction
       (format "CURRENT FILE: %s" (or current-file "none"))
       (format "CURRENT FILE OUTLINE:\n%s" outline)
       (when diff-text (format "DIFF SINCE LAST SAVE:\n%s" diff-text))
       (format "PROJECT FILE INDEX:\n%s" file-index)
       (if (eq kind 'inline-tips)
           "TOOLS:
- You have read_current_file (returns the focused file as line-numbered text) and annotate_line(line, tip).
- Read the file first, then call annotate_line once per teaching point using the 1-based line numbers shown. You cannot modify files."
         "TOOLS:
- You have read-only tools: read_file, list_directory, read_project_context, read_current_file, project_symbol_table, search_project.
- Use them to gather any context you need before answering. Product/project direction lives in read_project_context.
- Do not ask the user to paste code; fetch it yourself. All paths are relative to the project root. You cannot modify files.")
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

(defun codetutor--fireworks-agent-body (model messages tool-choice &optional kind)
  "Serialize a Fireworks chat-completions body with MESSAGES, tools, TOOL-CHOICE.
The tools advertised are filtered for request KIND."
  (json-serialize
   `((model . ,model)
     (messages . ,(vconcat messages))
     (tools . ,(codetutor--tool-specs kind))
     (tool_choice . ,tool-choice)
     (max_tokens . ,codetutor-fireworks-max-tokens)
     (temperature . ,codetutor-fireworks-temperature))))

(defun codetutor--fireworks-agent-start
    (root kind title panel user-request file diff &optional target-buffer)
  "Begin an agentic Fireworks request for ROOT; return the first process or nil.

When TARGET-BUFFER is a live buffer (inline-tips runs), the seed prompt and
current-file context are built inside it so the outline, point, and file text
reflect that buffer, and the request CTX carries the target buffer, its file,
and its modified tick so `annotate_line' can detect stale line numbers."
  (let ((api-key (codetutor--fireworks-api-key)))
    (if (null api-key)
        (codetutor--render-result
         panel root title
         (concat "No Fireworks AI API key is available. Set "
                 "`codetutor-fireworks-api-key', the FIREWORKS_API_KEY environment "
                 "variable, or an auth-source entry for host `api.fireworks.ai'."))
      (let* ((live (and (bufferp target-buffer) (buffer-live-p target-buffer)))
             (numbered (eq kind 'inline-tips))
             (build (lambda ()
                      (cons (codetutor--build-agent-seed-prompt
                             kind :root root :file file :diff diff
                             :user-request user-request)
                            (codetutor--current-file-context
                             (or file buffer-file-name) numbered))))
             (built (if live (with-current-buffer target-buffer (funcall build))
                      (funcall build)))
             (seed (car built))
             (ctx (append
                   (list :current-file-context (cdr built))
                   (when live
                     (list :target-buffer target-buffer
                           :target-file (buffer-local-value 'buffer-file-name
                                                            target-buffer)
                           :target-tick (with-current-buffer target-buffer
                                          (buffer-chars-modified-tick))))))
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
                model (plist-get state :messages) tool-choice
                (plist-get state :kind)))
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
            :coding 'utf-8
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

(defun codetutor--inline-tips-count (state)
  "Return the number of inline tips currently placed in STATE's target buffer."
  (let ((buffer (plist-get (plist-get state :ctx) :target-buffer)))
    (if (and (bufferp buffer) (buffer-live-p buffer))
        (with-current-buffer buffer (length codetutor--inline-tip-overlays))
      0)))

(defun codetutor--fireworks-agent-finalize (state raw)
  "Render RAW as the final answer for STATE and report token cost.

For the `inline-tips' kind the real output is the overlays placed in the
target buffer, so the panel shows a tip count alongside any summary and the
turn is not recorded (annotation bookkeeping should not pollute follow-ups)."
  (let* ((root (plist-get state :root))
         (session (codetutor--session root))
         (kind (plist-get state :kind))
         (title (plist-get state :title))
         (panel (plist-get state :panel))
         (answer (string-trim (codetutor--answer-text raw))))
    (codetutor--apply-memory-updates root raw)
    (if (eq kind 'inline-tips)
        (let* ((count (codetutor--inline-tips-count state))
               (header (format "Placed %d inline tip%s in the buffer."
                               count (if (= count 1) "" "s"))))
          (codetutor--render-result
           panel root title
           (if (string-empty-p answer) header
             (concat header "\n\n" answer))))
      (codetutor--record-turn root kind
                              (plist-get state :user-request) answer)
      (codetutor--render-result panel root title answer))
    (codetutor--report-cost session
                            (plist-get state :prompt-tokens)
                            (plist-get state :completion-tokens)
                            (plist-get state :tool-calls))))

(provide 'codetutor-agent)

;;; codetutor-agent.el ends here
