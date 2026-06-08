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

;;; codetutor-test.el ends here
