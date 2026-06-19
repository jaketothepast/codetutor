;;; codetutor-test.el --- Tests for CodeTutor -*- lexical-binding: t; -*-

(require 'ert)
(require 'codetutor)

(ert-deftest codetutor-unified-diff-includes-change ()
  (let ((diff (codetutor--unified-diff "one\n" "one\ntwo\n" "sample.txt")))
    (should (string-match-p "^+two" diff))))

(ert-deftest codetutor-codex-command-puts-global-flags-before-exec ()
  (let* ((codetutor-backend 'codex)
         (codetutor-enable-web-search t)
         (codetutor-codex-command "codex")
         (backend (codetutor--backend-command default-directory "prompt"))
         (command (plist-get backend :command))
         (exec-position (cl-position "exec" command :test #'equal))
         (approval-position (cl-position "--ask-for-approval" command :test #'equal))
         (search-position (cl-position "--search" command :test #'equal))
         (output-position (cl-position "--output-last-message" command :test #'equal)))
    (should exec-position)
    (should approval-position)
    (should search-position)
    (should output-position)
    (should (< approval-position exec-position))
    (should (< search-position exec-position))
    (should (> output-position exec-position))))

(ert-deftest codetutor-fireworks-command-keeps-key-off-argv ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_cmd) "/usr/bin/curl")))
   (let* ((codetutor-backend 'fireworks)
          (codetutor-fireworks-command "curl")
          (codetutor-fireworks-api-key "secret-key-123")
          (codetutor-fireworks-model "accounts/fireworks/models/test")
          (codetutor-model nil)
          (backend (codetutor--backend-command default-directory "PROMPT"))
          (command (plist-get backend :command))
          (temp-files (plist-get backend :temp-files)))
    (unwind-protect
        (progn
          (should (equal (plist-get backend :name) "Fireworks AI"))
          (should (eq (plist-get backend :parser)
                      #'codetutor--fireworks-parse-response))
          (should (member "--config" command))
          (should (member "--data" command))
          (should (member "--fail-with-body" command))
          (should (cl-find "https://api.fireworks.ai/inference/v1/chat/completions"
                           command :test #'equal))
          ;; The API key must never appear in the process arguments.
          (should-not (cl-find-if (lambda (arg) (string-match-p "secret-key-123" arg))
                                  command))
          ;; The key lives in the curl --config file instead.
          (let* ((config-file (cadr (member "--config" command)))
                 (config (codetutor--read-file config-file most-positive-fixnum)))
            (should (string-match-p "Authorization: Bearer secret-key-123" config))))
      (dolist (file temp-files)
        (when (and file (file-exists-p file))
          (delete-file file)))))))

(ert-deftest codetutor-fireworks-command-reports-missing-key ()
  (let ((codetutor-backend 'fireworks)
        (codetutor-fireworks-api-key nil)
        (process-environment (cons "FIREWORKS_API_KEY=" process-environment)))
    ;; With no resolvable key there is no command, only a guidance message.
    (cl-letf (((symbol-function 'executable-find) (lambda (_cmd) "/usr/bin/curl"))
              ((symbol-function 'codetutor--fireworks-auth-source-key)
               (lambda () nil)))
      (let ((backend (codetutor--backend-command default-directory "PROMPT")))
        (should (null (plist-get backend :command)))
        (should (string-match-p "FIREWORKS_API_KEY" (plist-get backend :message)))))))

(ert-deftest codetutor-fireworks-parse-extracts-content ()
  (should (equal (codetutor--fireworks-parse-response
                  "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Hello tutor\"}}]}")
                 "Hello tutor")))

(ert-deftest codetutor-fireworks-parse-surfaces-error ()
  (should (string-match-p
           "invalid model"
           (codetutor--fireworks-parse-response
            "{\"error\":{\"message\":\"invalid model\",\"type\":\"invalid_request\"}}"))))

(ert-deftest codetutor-fireworks-parse-tolerates-non-json ()
  (should (string-match-p
           "curl: (7)"
           (codetutor--fireworks-parse-response "curl: (7) Failed to connect"))))

(ert-deftest codetutor-fireworks-api-key-prefers-custom-then-env ()
  (let ((codetutor-fireworks-api-key "from-custom"))
    (should (equal (codetutor--fireworks-api-key) "from-custom")))
  (cl-letf (((symbol-function 'codetutor--fireworks-auth-source-key)
             (lambda () nil)))
    (let ((codetutor-fireworks-api-key nil)
          (process-environment (cons "FIREWORKS_API_KEY=from-env" process-environment)))
      (should (equal (codetutor--fireworks-api-key) "from-env")))))

(ert-deftest codetutor-fireworks-messages-avoid-duplicate-system-prompt ()
  (let* ((codetutor-system-prompt "SYSTEM RULES")
         (prompt (concat codetutor-system-prompt "\n\nUSER BODY"))
         (messages (codetutor--fireworks-messages prompt)))
    (should (= (length messages) 2))
    (should (equal (alist-get 'role (aref messages 0)) "system"))
    (should (equal (alist-get 'content (aref messages 0)) "SYSTEM RULES"))
    (should (equal (alist-get 'role (aref messages 1)) "user"))
    (should (equal (alist-get 'content (aref messages 1)) "USER BODY"))))

(ert-deftest codetutor-fireworks-auto-never-selects-remote ()
  ;; `auto' must not pick the remote backend even when a key is present.
  (cl-letf (((symbol-function 'executable-find) (lambda (_cmd) nil))
            ((symbol-function 'codetutor--fireworks-api-key)
             (lambda () "present")))
    (let ((codetutor-backend 'auto))
      (should-not (eq (codetutor--select-backend) 'fireworks)))))

(ert-deftest codetutor-backend-answer-prefers-output-file ()
  (let ((answer-file (make-temp-file "codetutor-answer-" nil ".md")))
    (unwind-protect
        (progn
          (write-region "Final answer only\n" nil answer-file nil 'silent)
          (should (equal (codetutor--backend-answer
                          "PROMPT AND TRANSCRIPT"
                          answer-file)
                         "Final answer only\n")))
      (delete-file answer-file))))

(ert-deftest codetutor-answer-text-extracts-visible-answer ()
  (let ((text "PROMPT ECHO\n<codetutor-answer>\nUse the boundary as your guide.\n</codetutor-answer>\n```codetutor-memory\n- Boundary: service object owns orchestration.\n```"))
    (should (equal (codetutor--answer-text text)
                   "Use the boundary as your guide."))))

(ert-deftest codetutor-prompt-allows-teaching-code-samples ()
  (let ((prompt (codetutor--build-prompt
                 'ask
                 :root default-directory
                 :user-request "Show me the shape of this refactor.")))
    (should (string-match-p "illustrative code samples" prompt))
    (should (string-match-p "compact code example" prompt))
    (should (string-match-p "Never edit files" prompt))
    (should (string-match-p "Do not output patches" prompt))
    (should-not (string-match-p "Never tell the user exactly what to type" prompt))))

(ert-deftest codetutor-render-status-clears-old-output-and-hides-input ()
  (let ((root (make-temp-file "codetutor-render-" t))
        (buffer (generate-new-buffer " *codetutor-render-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "Old answer\nUser asked: show me this input\n"))
          (codetutor--render-status buffer root "Answer" "Codex" 'ask)
          (let ((text (with-current-buffer buffer
                        (buffer-string))))
            (should (string-match-p "Status: thinking" text))
            (should (string-match-p "## Answer" text))
            (should-not (string-match-p "show me this input" text))
            (should-not (string-match-p "Old answer" text))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest codetutor-render-result-replaces-thinking-status ()
  (let ((root (make-temp-file "codetutor-result-" t))
        (buffer (generate-new-buffer " *codetutor-result-test*")))
    (unwind-protect
        (progn
          (codetutor--render-status buffer root "Answer" "Codex" 'ask)
          (codetutor--render-result buffer root "Answer" "Think in data flow first.")
          (let ((text (with-current-buffer buffer
                        (buffer-string))))
            (should (string-match-p "Think in data flow first" text))
            (should-not (string-match-p "Status: thinking" text))
            (should-not (string-match-p "Thinking with" text))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest codetutor-follow-up-prompt-includes-private-conversation ()
  (let ((root (file-name-as-directory (make-temp-file "codetutor-follow-up-" t))))
    (unwind-protect
        (with-temp-buffer
          (let ((default-directory root))
            (codetutor--record-turn
             root
             'ask
             "How should I think about this service?"
             "Start by identifying its boundary and callers.")
            (let ((prompt (codetutor--build-prompt
                           'follow-up
                           :root root
                           :user-request "Can you say more?")))
              (should (string-match-p "RECENT CONVERSATION" prompt))
              (should (string-match-p "How should I think about this service" prompt))
              (should (string-match-p "identifying its boundary" prompt))
              (should (string-match-p "Can you say more" prompt)))))
      (remhash root codetutor--sessions)
      (delete-directory root t))))

(ert-deftest codetutor-save-prompt-includes-other-open-project-buffers ()
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-open-buffers-" t)))
         (current-file (expand-file-name "current.el" root))
         (other-file (expand-file-name "other.el" root))
         current-buffer
         other-buffer)
    (unwind-protect
        (progn
          (write-region "(message \"current\")\n" nil current-file nil 'silent)
          (write-region "(defun other-context () :loaded)\n" nil other-file nil 'silent)
          (setq current-buffer (find-file-noselect current-file))
          (setq other-buffer (find-file-noselect other-file))
          (with-current-buffer current-buffer
            (let ((codetutor-include-open-buffers-on-save t))
              (let ((prompt (codetutor--build-prompt
                             'save
                             :root root
                             :file current-file
                             :diff "diff"
                             :user-request "review")))
                (should (string-match-p "OTHER OPEN PROJECT BUFFERS" prompt))
                (should (string-match-p "### other.el" prompt))
                (should (string-match-p "other-context" prompt))
                (should-not (string-match-p "### current.el" prompt))))))
      (when (buffer-live-p current-buffer)
        (kill-buffer current-buffer))
      (when (buffer-live-p other-buffer)
        (kill-buffer other-buffer))
      (delete-directory root t))))

(ert-deftest codetutor-project-context-loads-project-and-spec ()
  (let ((root (make-temp-file "codetutor-project-" t)))
    (unwind-protect
        (progn
          (write-region "Project direction\n" nil (expand-file-name "PROJECT.md" root) nil 'silent)
          (make-directory (expand-file-name "spec" root))
          (write-region "Spec direction\n" nil (expand-file-name "spec/plan.md" root) nil 'silent)
          (let ((context (codetutor--project-context root)))
            (should (string-match-p "Project direction" context))
            (should (string-match-p "Spec direction" context))))
      (delete-directory root t))))

(ert-deftest codetutor-memory-lines-are-extracted ()
  (let ((text "Answer\n```codetutor-memory\n- Boundary: UI talks to service objects.\n\n- Data: records are append-only.\n```\n"))
    (should (equal (codetutor--memory-lines text)
                   '("- Boundary: UI talks to service objects."
                     "- Data: records are append-only.")))))

(ert-deftest codetutor-apply-memory-updates-deduplicates ()
  (let ((root (make-temp-file "codetutor-memory-" t)))
    (unwind-protect
        (let ((codetutor-memory-file ".codetutor/ARCHITECTURE.md"))
          (codetutor--apply-memory-updates
           root
           "```codetutor-memory\n- Boundary: Tutor is read-only.\n```")
          (codetutor--apply-memory-updates
           root
           "```codetutor-memory\n- Boundary: Tutor is read-only.\n- Backend: CLI process is asynchronous.\n```")
          (let ((memory (codetutor--read-file
                         (expand-file-name ".codetutor/ARCHITECTURE.md" root)
                         most-positive-fixnum)))
            (should (= 1 (codetutor-test--count
                          "- Boundary: Tutor is read-only."
                          memory)))
            (should (string-match-p "Backend: CLI process is asynchronous" memory))))
      (delete-directory root t))))

(defun codetutor-test--count (needle haystack)
  "Return the number of NEEDLE occurrences in HAYSTACK."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count))
      (setq start (match-end 0)))
    count))

(ert-deftest codetutor-strip-memory-block-removes-private-notes ()
  (let ((clean (codetutor--strip-memory-blocks
                "Visible\n```codetutor-memory\n- Private note\n```\nDone")))
    (should (string-match-p "Visible" clean))
    (should (string-match-p "Done" clean))
    (should-not (string-match-p "Private note" clean))))

;;; Agentic tools -----------------------------------------------------------

(ert-deftest codetutor-resolve-project-path-sandbox ()
  (let ((root (file-name-as-directory (make-temp-file "codetutor-sandbox-" t))))
    (unwind-protect
        (progn
          (should (codetutor--resolve-project-path root "a/b.txt"))
          (should (codetutor--resolve-project-path root "."))
          ;; escapes are rejected
          (should-not (codetutor--resolve-project-path root "../outside.txt"))
          (should-not (codetutor--resolve-project-path root "../../etc/passwd"))
          (should-not (codetutor--resolve-project-path root "/etc/passwd")))
      (delete-directory root t))))

(ert-deftest codetutor-tool-read-file-honors-range-and-sandbox ()
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-readfile-" t)))
         (file (expand-file-name "sample.txt" root)))
    (unwind-protect
        (progn
          (write-region "l1\nl2\nl3\nl4\n" nil file nil 'silent)
          (let ((ranged (codetutor--tool-read-file
                         root nil '((path . "sample.txt") (start_line . 2) (end_line . 3)))))
            (should (string-match-p "l2" ranged))
            (should (string-match-p "l3" ranged))
            (should-not (string-match-p "l1" ranged))
            (should-not (string-match-p "l4" ranged)))
          ;; sandbox escape is refused
          (should (string-match-p "outside the project root"
                                  (codetutor--tool-read-file
                                   root nil '((path . "../escape.txt"))))))
      (delete-directory root t))))

(ert-deftest codetutor-tool-list-directory-skips-ignored ()
  (let ((root (file-name-as-directory (make-temp-file "codetutor-listdir-" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (make-directory (expand-file-name "src" root))
          (write-region "x" nil (expand-file-name "keep.txt" root) nil 'silent)
          (let ((listing (codetutor--tool-list-directory root nil nil)))
            (should (string-match-p "keep.txt" listing))
            (should (string-match-p "src/" listing))
            (should-not (string-match-p "\\.git" listing))))
      (delete-directory root t))))

(ert-deftest codetutor-tool-specs-serialize-to-valid-json ()
  (let* ((json (json-serialize (codetutor--tool-specs)))
         (parsed (json-parse-string json :object-type 'alist :array-type 'list))
         (names (mapcar (lambda (s) (alist-get 'name (alist-get 'function s))) parsed)))
    (should (member "read_file" names))
    (should (member "project_symbol_table" names))
    (should (member "search_project" names))
    ;; every spec is a function tool with a parameters object
    (dolist (spec parsed)
      (should (equal "function" (alist-get 'type spec)))
      (should (alist-get 'parameters (alist-get 'function spec))))))

(ert-deftest codetutor-dispatch-tool-unknown-and-cap ()
  (should (string-match-p "unknown tool"
                          (codetutor--dispatch-tool default-directory nil "nope" nil)))
  ;; output is capped to codetutor-tool-max-output-bytes
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-cap-" t)))
         (file (expand-file-name "big.txt" root)))
    (unwind-protect
        (progn
          (write-region (make-string 5000 ?x) nil file nil 'silent)
          (let ((codetutor-tool-max-output-bytes 200))
            (should (<= (string-bytes
                         (codetutor--dispatch-tool
                          root nil "read_file" '((path . "big.txt"))))
                        ;; cap plus the short truncation marker
                        400))))
      (delete-directory root t))))

(ert-deftest codetutor-build-symbol-table-reports-skips-without-grammar ()
  ;; With no installed grammars every file is skipped, but it must not error
  ;; and must report the skip count rather than silently dropping files.
  (let ((root (file-name-as-directory (make-temp-file "codetutor-symtab-" t))))
    (unwind-protect
        (cl-letf (((symbol-function 'codetutor--file-treesit-language)
                   (lambda (_file) nil)))
          (write-region "x" nil (expand-file-name "a.py" root) nil 'silent)
          (write-region "y" nil (expand-file-name "b.py" root) nil 'silent)
          (let ((table (codetutor--build-symbol-table root)))
            (should (= 2 (plist-get table :skipped)))
            (should (= 0 (plist-get table :symbol-files)))
            (should (string-match-p "No symbols found"
                                    (codetutor--render-symbol-table table nil)))))
      (delete-directory root t))))

(ert-deftest codetutor-symbol-table-filter-matches-names ()
  (let ((table (list :entries '(("a.el" "  L1  defun  foo-bar" "  L8  defun  baz")
                                ("b.el" "  L1  defun  other"))
                     :scanned 2 :total 2 :symbol-files 2 :skipped 0)))
    (let ((rendered (codetutor--render-symbol-table table "foo")))
      (should (string-match-p "foo-bar" rendered))
      (should-not (string-match-p "baz" rendered))
      (should-not (string-match-p "other" rendered)))))

(ert-deftest codetutor-normalize-tool-calls-produces-clean-vector ()
  (let* ((parsed '(((id . "call_1")
                    (type . "function")
                    (function . ((name . "read_file")
                                 (arguments . "{\"path\":\"x.el\"}"))))))
         (norm (codetutor--normalize-tool-calls parsed)))
    (should (vectorp norm))
    (should (equal "call_1" (alist-get 'id (aref norm 0))))
    (should (equal "read_file"
                   (alist-get 'name (alist-get 'function (aref norm 0)))))
    ;; round-trips through json-serialize without error
    (should (stringp (json-serialize norm)))))

(ert-deftest codetutor-agent-body-includes-messages-and-tools ()
  (let* ((body (codetutor--fireworks-agent-body
                "accounts/fireworks/models/test"
                (list '((role . "system") (content . "S"))
                      '((role . "user") (content . "U")))
                "auto"))
         (data (json-parse-string body :object-type 'alist :array-type 'list)))
    (should (equal "auto" (alist-get 'tool_choice data)))
    (should (= 2 (length (alist-get 'messages data))))
    (should (alist-get 'tools data))))

(ert-deftest codetutor-agent-run-tools-appends-results-and-loops ()
  ;; Stub the network step: capture state instead of spawning curl.
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-loop-" t)))
         (file (expand-file-name "x.txt" root))
         (captured nil))
    (unwind-protect
        (cl-letf (((symbol-function 'codetutor--fireworks-agent-step)
                   (lambda (state) (setq captured state) 'stepped))
                  ((symbol-function 'codetutor--render-agent-status)
                   (lambda (&rest _) nil)))
          (write-region "hello\n" nil file nil 'silent)
          (let* ((state (list :root root :messages nil :iteration 0
                              :tool-calls 0 :ctx nil
                              :title "T" :panel nil))
                 (message '((role . "assistant") (content . :null)
                            (tool_calls . nil)))
                 (tool-calls '(((id . "call_1")
                                (function . ((name . "read_file")
                                             (arguments . "{\"path\":\"x.txt\"}")))))))
            (codetutor--fireworks-agent-run-tools state message tool-calls)
            ;; iteration advanced and the loop continued
            (should (eq captured state))
            (should (= 1 (plist-get state :iteration)))
            (should (= 1 (plist-get state :tool-calls)))
            ;; messages now hold an assistant tool_calls msg + a tool result
            (let* ((msgs (plist-get state :messages))
                   (tool-msg (car (last msgs))))
              (should (= 2 (length msgs)))
              (should (equal "tool" (alist-get 'role tool-msg)))
              (should (equal "call_1" (alist-get 'tool_call_id tool-msg)))
              (should (string-match-p "hello" (alist-get 'content tool-msg))))))
      (delete-directory root t))))

(ert-deftest codetutor-format-cost-tokens-only-and-priced ()
  (let ((codetutor-fireworks-cost-input-per-million nil)
        (codetutor-fireworks-cost-output-per-million nil))
    (let ((line (codetutor--format-cost 8901 6311 3 8901 6311)))
      (should (string-match-p "15,212 tokens" line))
      (should (string-match-p "3 tool calls" line))
      (should-not (string-match-p "\\$" line))))
  (let ((codetutor-fireworks-cost-input-per-million 1.0)
        (codetutor-fireworks-cost-output-per-million 1.0))
    (should (string-match-p "\\$0\\.0152"
                            (codetutor--format-cost 8901 6311 3 8901 6311)))))

(ert-deftest codetutor-report-cost-accumulates-session-total ()
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-cost-" t)))
         (session (codetutor--session root))
         (codetutor-show-cost t)
         (codetutor-fireworks-cost-input-per-million nil)
         (codetutor-fireworks-cost-output-per-million nil))
    (unwind-protect
        (progn
          (codetutor--report-cost session 100 50 1)
          (codetutor--report-cost session 200 100 2)
          ;; two requests sum rather than overwrite
          (should (= 300 (plist-get session :cost-prompt-tokens)))
          (should (= 150 (plist-get session :cost-completion-tokens))))
      (remhash root codetutor--sessions)
      (delete-directory root t))))

;;; Spec development mode ----------------------------------------------------

(ert-deftest codetutor-spec-slug-normalizes-name ()
  (should (equal "my-cool-feature.md" (codetutor--spec-slug "My Cool Feature!")))
  (should (equal "rate-limiter.md" (codetutor--spec-slug "  Rate   Limiter  ")))
  (should (equal "spec.md" (codetutor--spec-slug "***"))))

(ert-deftest codetutor-spec-template-has-teaching-sections ()
  (let ((doc (replace-regexp-in-string "{name}" "Demo" codetutor-spec-template nil t)))
    (let ((titles (mapcar #'car (codetutor--spec-sections doc))))
      (should (member "Problem / Why" titles))
      (should (member "Requirements (acceptance criteria)" titles))
      (should (member "Build plan (slices)" titles)))
    ;; the guiding comments teach what each section is for
    (should (string-match-p "<!--" doc))
    ;; a fresh template is entirely empty (only guiding comments)
    (should (= (length (codetutor--spec-sections doc))
               (length (codetutor--spec-empty-sections doc))))))

(ert-deftest codetutor-spec-section-at-maps-line ()
  (let ((doc "# T\n\n## Problem / Why\nsome text\n\n## Goals\nmore\n"))
    (should (equal "Problem / Why" (codetutor--spec-section-at doc 4)))
    (should (equal "Goals" (codetutor--spec-section-at doc 7)))
    (should (null (codetutor--spec-section-at doc 1)))))

(ert-deftest codetutor-spec-empty-sections-tracks-progress ()
  (let* ((doc (replace-regexp-in-string "{name}" "Demo" codetutor-spec-template nil t))
         (filled (replace-regexp-in-string
                  "## Problem / Why\n<!--[^>]*-->"
                  "## Problem / Why\nSolves slow startup for new users."
                  doc)))
    (should (member "Problem / Why" (codetutor--spec-empty-sections doc)))
    (should-not (member "Problem / Why" (codetutor--spec-empty-sections filled)))))

(ert-deftest codetutor-diff-touched-line-finds-added-line ()
  (should (= 11 (codetutor--diff-touched-line
                 "--- a\n+++ b\n@@ -10,2 +10,3 @@\n context\n+added\n more\n")))
  (should (null (codetutor--diff-touched-line "no hunks here"))))

(ert-deftest codetutor-spec-file-p-detects-spec-dir ()
  (let ((root "/proj/"))
    (should (codetutor--spec-file-p "/proj/spec/feature.md" root))
    (should-not (codetutor--spec-file-p "/proj/src/main.el" root))))

(ert-deftest codetutor-save-kind-dispatches-by-file-and-active-spec ()
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-savekind-" t)))
         (spec (expand-file-name "spec/demo.md" root))
         (code (expand-file-name "main.el" root)))
    (unwind-protect
        (progn
          ;; no active spec
          (should (eq 'save (codetutor--save-kind code root)))
          (should (eq 'spec (codetutor--save-kind spec root)))
          ;; activate a spec -> code saves become build reviews
          (codetutor--set-active-spec root spec)
          (should (eq 'spec-implement (codetutor--save-kind code root)))
          (should (eq 'spec (codetutor--save-kind spec root))))
      (remhash (file-name-as-directory (expand-file-name root)) codetutor--sessions)
      (delete-directory root t))))

(ert-deftest codetutor-build-prompt-includes-spec-context-and-posture ()
  (let* ((root (file-name-as-directory (make-temp-file "codetutor-specprompt-" t)))
         (spec (expand-file-name "spec/demo.md" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "spec" root))
          (write-region (replace-regexp-in-string "{name}" "Demo" codetutor-spec-template nil t)
                        nil spec nil 'silent)
          (codetutor--set-active-spec root spec)
          (let ((prompt (codetutor--build-prompt
                         'spec :root root :user-request "review"
                         :diff "@@ -3,1 +3,1 @@\n+Solves X.\n")))
            (should (string-match-p "SPEC STATUS" prompt))
            (should (string-match-p "ACTIVE SPEC: spec/demo.md" prompt))
            (should (string-match-p "SPEC MODE (teach-only)" prompt))
            (should (string-match-p "never write the spec body" prompt)))
          ;; build posture for code-while-active
          (let ((prompt (codetutor--build-prompt 'spec-implement :root root)))
            (should (string-match-p "BUILD MODE (teach-only)" prompt))
            (should (string-match-p "never write the code" prompt)))
          ;; no spec context leaks into a normal request when none is active
          (codetutor--set-active-spec root nil)
          (should-not (string-match-p
                       "SPEC STATUS"
                       (codetutor--build-prompt 'ask :root root :user-request "hi"))))
      (remhash (file-name-as-directory (expand-file-name root)) codetutor--sessions)
      (delete-directory root t))))

;;; codetutor-test.el ends here
