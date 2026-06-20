;;; codetutor-tools.el --- Read-only tools for the CodeTutor agent -*- lexical-binding: t; -*-

;; This file is part of CodeTutor; see codetutor.el for the package header.

;;; Commentary:

;; The read-only, project-root-sandboxed tools exposed to the Fireworks
;; agentic backend (read_file, list_directory, read_project_context,
;; read_current_file, project_symbol_table, search_project), the tool
;; registry and dispatcher, and the tree-sitter project symbol table.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'codetutor-vars)
(require 'treesit nil t)

;; Defined in the umbrella core (codetutor.el); declared here because tools
;; sit below the core in the dependency graph and must not require it back.
(declare-function codetutor--project-context "codetutor")
(declare-function codetutor--project-files "codetutor")
(declare-function codetutor--session "codetutor")
(declare-function codetutor--truncate "codetutor")
(declare-function codetutor--place-tip "codetutor-inline-tips")
(declare-function codetutor--treesit-child-name "codetutor")

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

(defun codetutor--tool-annotate-line (_root ctx args)
  "Tool: place a teaching tip on a line of the target buffer (side effect).
Reads the target buffer, its file, and its modified tick from CTX.  No-ops
with an error string -- never throws -- when the buffer is dead, the file no
longer matches, the buffer was edited since the request began, the line is
not an integer or is out of range, or the tip is blank.  On success calls
`codetutor--place-tip' and returns a short confirmation."
  (let ((buffer (plist-get ctx :target-buffer))
        (target-file (plist-get ctx :target-file))
        (target-tick (plist-get ctx :target-tick))
        (line (alist-get 'line args))
        (tip (alist-get 'tip args)))
    (cond
     ((not (and (bufferp buffer) (buffer-live-p buffer)))
      "Error: no live target buffer for this request; cannot annotate.")
     ((not (integerp line))
      "Error: annotate_line requires an integer \"line\".")
     ((not (codetutor--nonempty-string tip))
      "Error: annotate_line requires a non-empty \"tip\".")
     (t
      (with-current-buffer buffer
        (cond
         ((not (equal buffer-file-name target-file))
          "Error: the target buffer's file changed; annotations were skipped.")
         ((and target-tick (not (equal (buffer-chars-modified-tick) target-tick)))
          "Error: the buffer was edited since this request began; line numbers are stale.")
         (t
          (let ((max-line (line-number-at-pos (point-max))))
            (cond
             ((or (< line 1) (> line max-line))
              (format "Error: line %d is out of range (%s has %d lines)."
                      line (buffer-name buffer) max-line))
             ((codetutor--place-tip line (string-trim tip))
              (format "Placed tip on line %d." line))
             (t
              (format "Tip not placed: inline tips are disabled or the %d-tip cap was reached."
                      codetutor-inline-tip-max)))))))))))

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
     :handler codetutor--tool-search-project)
    (:name "annotate_line"
     :kinds (inline-tips)
     :description "Place a short teaching annotation on a specific 1-based line of the file the user is currently editing. Call once per teaching point. Keep the tip to 1-3 sentences."
     :schema ((type . "object")
              (properties
               (line (type . "integer")
                     (description . "1-based line number in the current file."))
               (tip (type . "string")
                    (description . "The teaching annotation (1-3 sentences).")))
              (required . ["line" "tip"]))
     :handler codetutor--tool-annotate-line))
  "Read-only tools exposed to the Fireworks agentic backend.
Each entry is a plist: :name :description :schema :handler, plus an optional
:kinds list restricting the request kinds the tool is offered for.")

(defconst codetutor--inline-tips-tool-names '("read_current_file" "annotate_line")
  "Tool names offered for the `inline-tips' request kind.
That kind only inspects the focused buffer and annotates it, so the broad
project-wide read tools are withheld to keep the model focused.")

(defun codetutor--tool-offered-p (tool kind)
  "Return non-nil when TOOL should be advertised for request KIND.
For the `inline-tips' kind, only `codetutor--inline-tips-tool-names' are
offered.  For every other kind, only tools without a :kinds restriction are
offered, so kind-restricted tools (e.g. `annotate_line') never leak out."
  (if (eq kind 'inline-tips)
      (member (plist-get tool :name) codetutor--inline-tips-tool-names)
    (null (plist-get tool :kinds))))

(defun codetutor--tool-specs (&optional kind)
  "Return the tools array (vector of function specs) for request KIND.
Tools are filtered by `codetutor--tool-offered-p'."
  (vconcat
   (delq
    nil
    (mapcar
     (lambda (tool)
       (when (codetutor--tool-offered-p tool kind)
         `((type . "function")
           (function . ((name . ,(plist-get tool :name))
                        (description . ,(plist-get tool :description))
                        (parameters . ,(plist-get tool :schema)))))))
     codetutor--tools))))

(defun codetutor--project-mtime-token (root)
  "Return a token that changes when ROOT's project files change.

Used to invalidate the cached project symbol table without re-parsing."
  (let ((root-dir (file-name-as-directory (expand-file-name root))))
    (sxhash-equal
     (mapcar (lambda (rel)
               (let ((attrs (file-attributes (expand-file-name rel root-dir))))
                 (cons rel (and attrs (file-attribute-modification-time attrs)))))
             (codetutor--project-files root-dir)))))

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

The parsed table is cached on the session plist as (TOKEN . TABLE) and rebuilt
only when the project's files change (or when `codetutor-cache-tool-results' is
nil, or `codetutor-refresh-architecture-memory' clears the cache)."
  (let* ((session (codetutor--session root))
         (token (and codetutor-cache-tool-results
                     (codetutor--project-mtime-token root)))
         (cached (plist-get session :symbol-table))
         (table (if (and cached token (equal (car cached) token))
                    (cdr cached)
                  (let ((built (codetutor--build-symbol-table root)))
                    (setf (plist-get session :symbol-table) (cons token built))
                    built))))
    (codetutor--render-symbol-table table name-filter)))

(provide 'codetutor-tools)

;;; codetutor-tools.el ends here
