;;; codetutor-inline-tips.el --- Inline teaching tips for CodeTutor -*- lexical-binding: t; -*-

;; This file is part of CodeTutor; see codetutor.el for the package header.

;;; Commentary:

;; Inline tips: CodeTutor reads the focused code buffer and places short
;; teaching annotations on specific lines.  Each tip is a zero-length
;; overlay rendered via `after-string'/`before-string', so it is display
;; only -- never editable, never written to disk, and never marks the
;; buffer modified.  The model chooses the lines and text by calling the
;; `annotate_line' tool (see codetutor-tools.el), which delegates here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'codetutor-vars)

;; This module only paints overlays; the `codetutor-inline-tips' command that
;; drives the agent lives in the umbrella (codetutor.el) so its dependency on
;; the request machinery is satisfied without a load cycle.

;;; Overlay display ---------------------------------------------------------

(defun codetutor--line-to-pos (line &optional where)
  "Return a buffer position for 1-based LINE in the current buffer.
LINE is clamped into the range [1, last line] as a safety net.  WHERE
selects the position on that line: `eol' for end of line, `bol' (or nil)
for beginning of line."
  (save-excursion
    (goto-char (point-min))
    (let* ((total (line-number-at-pos (point-max)))
           (target (max 1 (min (or line 1) total))))
      (forward-line (1- target))
      (if (eq where 'eol) (line-end-position) (line-beginning-position)))))

(defun codetutor--line-indentation (line)
  "Return the leading-whitespace string of 1-based LINE in the current buffer."
  (save-excursion
    (goto-char (codetutor--line-to-pos line 'bol))
    (buffer-substring-no-properties
     (point)
     (progn (skip-chars-forward " \t") (point)))))

(defun codetutor--inline-tip-string (text indent)
  "Build a propertized inline-tip display string for TEXT.
TEXT may contain newlines for a multi-line tip.  INDENT is whitespace
copied from the target code line so the tip aligns under it.  The first
visual line carries `codetutor-inline-tip-prefix'; continuation lines are
indented to match.  The returned string has no leading or trailing
newline -- the caller adds the newline that turns it into its own line."
  (let* ((cont (make-string (string-width codetutor-inline-tip-prefix) ?\s))
         (lines (split-string (string-trim-right text) "\n"))
         (body (cl-loop for ln in lines
                        for first = t then nil
                        concat (concat indent
                                       (if first codetutor-inline-tip-prefix cont)
                                       ln "\n"))))
    (propertize (substring body 0 (max 0 (1- (length body))))
                'face 'codetutor-inline-tip-face
                'cursor-intangible t
                'rear-nonsticky t
                'cursor t)))

(defun codetutor--inline-tips-clear-on-edit (&rest _)
  "Clear inline tips in the current buffer, then remove this hook.
Armed as a buffer-local one-shot on `after-change-functions' so the
user's first real edit wipes tips whose line numbers are now stale."
  (codetutor-clear-inline-tips)
  (remove-hook 'after-change-functions
               #'codetutor--inline-tips-clear-on-edit t))

(defun codetutor--place-tip (line text)
  "Render a non-editable inline tip with TEXT attached to 1-based LINE.
Operates on the current buffer.  Returns the overlay, or nil when inline
tips are disabled or the per-run cap is reached.  The overlay is
zero-length, anchored at the target line's edge, and renders TEXT as a
virtual line above or below per `codetutor-inline-tip-placement'.  No
buffer text is inserted and the buffer is not marked modified."
  (when (and codetutor-inline-tips-enable
             (< (length codetutor--inline-tip-overlays)
                codetutor-inline-tip-max))
    (let* ((below (eq codetutor-inline-tip-placement 'below))
           (anchor (codetutor--line-to-pos line (if below 'eol 'bol)))
           (indent (codetutor--line-indentation line))
           (tip (codetutor--inline-tip-string text indent))
           ;; Below: advance both ends so the tip stays at end-of-line when the
           ;; user types there.  Above: keep the anchor fixed at line start.
           (ov (if below
                   (make-overlay anchor anchor nil t t)
                 (make-overlay anchor anchor nil nil nil))))
      (overlay-put ov 'codetutor-inline-tip t)
      (overlay-put ov 'category 'codetutor-inline-tip)
      (overlay-put ov 'evaporate nil)
      ;; Below: newline first so the tip becomes the next visual line.
      ;; Above: newline last so the tip precedes the target line.
      (overlay-put ov (if below 'after-string 'before-string)
                   (if below (concat "\n" tip) (concat tip "\n")))
      (push ov codetutor--inline-tip-overlays)
      (when codetutor-inline-tip-clear-on-edit
        (add-hook 'after-change-functions
                  #'codetutor--inline-tips-clear-on-edit nil t))
      ov)))

;;;###autoload
(defun codetutor-clear-inline-tips (&optional buffer)
  "Remove all CodeTutor inline-tip overlays from BUFFER (default current).
Clears overlays both by their `codetutor-inline-tip' tag and via the
buffer-local tracking list.  Does not modify buffer text."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (remove-overlays (point-min) (point-max) 'codetutor-inline-tip t)
    (mapc (lambda (ov) (when (overlayp ov) (delete-overlay ov)))
          codetutor--inline-tip-overlays)
    (setq codetutor--inline-tip-overlays nil)))

(provide 'codetutor-inline-tips)

;;; codetutor-inline-tips.el ends here
