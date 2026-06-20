;;; codetutor-backend.el --- Backends and cost reporting for CodeTutor -*- lexical-binding: t; -*-

;; This file is part of CodeTutor; see codetutor.el for the package header.

;;; Commentary:

;; Backend selection and command building for the Codex, pi.dev, and
;; single-shot Fireworks AI backends, the Fireworks OpenAI-compatible
;; HTTP plumbing (API key resolution, curl config, request/response
;; shaping), and token-usage cost reporting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'codetutor-vars)

(declare-function auth-source-search "auth-source")

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

(provide 'codetutor-backend)

;;; codetutor-backend.el ends here
