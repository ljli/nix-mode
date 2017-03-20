;; -*- lexical-binding: t -*-
;;; nix-mode.el --- Major mode for editing Nix expressions

;; Author: Eelco Dolstra
;; Maintainer: Matthew Bauer <mjbauer95@gmail.com>
;; Homepage: https://github.com/matthewbauer/nix-mode
;; Version: 1.1
;; Keywords: nix

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; A major mode for editing Nix expressions (.nix files).  See the Nix manual
;; for more information available at https://nixos.org/nix/manual/.

;;; Code:

(require 'flycheck)

;; Emacs 24.2 compatability
(unless (fboundp 'setq-local)
  (defmacro setq-local (var val)
    "Set variable VAR to value VAL in current buffer."
    `(set (make-local-variable ',var) ,val)))

;;; Syntax coloring

(defconst nix-keywords
  '("if" "then"
    "else" "with"
    "let" "in"
    "rec" "inherit"
    "or"
    ))

(defconst nix-builtins
  '("builtins" "baseNameOf"
    "derivation" "dirOf"
    "false" "fetchTarball"
    "import" "isNull"
    "map" "removeAttrs"
    "toString" "true"))

(defconst nix-warning-keywords
  '("assert" "abort" "throw"))

(defconst nix-re-file-path
  "[a-zA-Z0-9._\\+-]*\\(/[a-zA-Z0-9._\\+-]+\\)+")

(defconst nix-re-url
  "[a-zA-Z][a-zA-Z0-9\\+-\\.]*:[a-zA-Z0-9%/\\?:@&=\\+\\$,_\\.!~\\*'-]+")

(defconst nix-re-bracket-path
  "<[a-zA-Z0-9._\\+-]+\\(/[a-zA-Z0-9._\\+-]+\\)*>")

(defconst nix-re-variable-assign
  "\\<\\([a-zA-Z_][a-zA-Z0-9_'\-\.]*\\)[ \t]*=")

(defconst nix-font-lock-keywords
  `(
    (,(regexp-opt nix-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt nix-warning-keywords 'symbols) . font-lock-warning-face)
    (,(regexp-opt nix-builtins 'symbols) . font-lock-builtin-face)
    (,nix-re-url . font-lock-constant-face)
    (,nix-re-file-path . font-lock-constant-face)
    (,nix-re-variable-assign 1 font-lock-variable-name-face)
    (,nix-re-bracket-path . font-lock-constant-face))
  "Font lock keywords for nix.")

(defvar nix-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ ". 14" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?# "< b" table)
    (modify-syntax-entry ?\n "> b" table)
    ;; We handle strings
    (modify-syntax-entry ?\" "." table)
    ;; We handle escapes
    (modify-syntax-entry ?\\ "." table)
    table)
  "Syntax table for Nix mode.")

(defun nix--mark-string (pos string-type)
  (put-text-property pos (1+ pos)
                     'syntax-table (string-to-syntax "|"))
  (put-text-property pos (1+ pos)
                     'nix-string-type string-type))

(defconst nix--variable-char "[a-zA-Z0-9_'\-]")

(defun nix--get-parse-state (pos)
  (save-excursion (save-match-data (syntax-ppss pos))))

(defun nix--get-string-type (parse-state)
  (let ((string-start (nth 8 parse-state)))
    (and string-start (get-text-property string-start 'nix-string-type))))

(defun nix--open-brace-string-type (parse-state)
  (let ((open-brace (nth 1 parse-state)))
    (and open-brace (get-text-property open-brace 'nix-string-type))))

(defun nix--open-brace-antiquote-p (parse-state)
  (let ((open-brace (nth 1 parse-state)))
    (and open-brace (get-text-property open-brace 'nix-syntax-antiquote))))

(defun nix--single-quotes ()
  (let* ((start (match-beginning 0))
         (end (match-end 0))
         (context (nix--get-parse-state start))
         (string-type (nix--get-string-type context)))
    (unless (or (equal string-type ?\")
                (and (equal string-type nil)
                     (save-match-data
                       (string-match nix--variable-char
                                     (buffer-substring-no-properties (1- start) start)))))
      (when (equal string-type nil)
        (nix--mark-string start ?\')
        (setq start (+ 2 start)))
      (when (equal (mod (- end start) 3) 2)
        (let ((str-peek (buffer-substring-no-properties end (+ 2 end))))
          (if (equal str-peek "${")
              (put-text-property end (+ 2 end) 'nix-escaped t)
            (unless (member str-peek '("\\n" "\\r" "\\t"))
              (nix--mark-string (1- end) ?\'))))))))

(defun nix--escaped-antiquote-dq-style ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start))
         (string-type (nix--get-string-type ps)))
    (when (equal string-type ?\')
      (nix--antiquote-open-at (1+ start) ?\'))))

(defun nix--double-quotes ()
  (let* ((pos (match-beginning 0))
         (ps (nix--get-parse-state pos))
         (string-type (nix--get-string-type ps)))
    (unless (equal string-type ?\')
      (nix--mark-string pos ?\"))))

(defun nix--antiquote-open-at (pos string-type)
  (if (get-text-property pos 'nix-escaped)
      (remove-text-properties pos (+ 2 pos) '(nix-escaped nil))
    (put-text-property pos (1+ pos)
                       'syntax-table (string-to-syntax "|"))
    (put-text-property pos (+ 2 pos)
                       'nix-string-type string-type)
    (put-text-property (1+ pos) (+ 2 pos)
                       'nix-syntax-antiquote t)))

(defun nix--antiquote-open ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start))
         (string-type (nix--get-string-type ps)))
    (when string-type)
      (nix--antiquote-open-at start string-type)))

(defun nix--antiquote-close-open ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start)))
    (when (and (not (nix--get-string-type ps))
               (nix--open-brace-antiquote-p ps))
      (let ((string-type (nix--open-brace-string-type ps)))
        (put-text-property start (+ 3 start)
                           'nix-string-type string-type)
        (put-text-property start (1+ start)
                           'nix-syntax-antiquote t)
        (put-text-property (+ 2 start) (+ 3 start)
                           'nix-syntax-antiquote t)))))

(defun nix--antiquote-close-sq-end ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start)))
    (when (and (not (nix--get-string-type ps))
               (nix--open-brace-antiquote-p ps))
      (let ((string-type (nix--open-brace-string-type ps)))
        (pcase string-type
          (`?\'
           (put-text-property start (+ 3 start)
                              'nix-string-type string-type)
           (put-text-property start (1+ start)
                              'nix-syntax-antiquote t))
          (`?\" (nix--antiquote-close)))))))

(defun nix--antiquote-close-dq-end ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start)))
    (when (and (not (nix--get-string-type ps))
               (nix--open-brace-antiquote-p ps))
      (let ((string-type (nix--open-brace-string-type ps)))
        (pcase string-type
          (`?\"
           (put-text-property start (+ 2 start)
                              'nix-string-type string-type)
           (put-text-property start (1+ start)
                              'nix-syntax-antiquote t))
          (`?\' (nix--antiquote-close)))))))

(defun nix--antiquote-close ()
  (let* ((start (match-beginning 0))
         (ps (nix--get-parse-state start)))
    (when (and (not (nix--get-string-type ps))
               (nix--open-brace-antiquote-p ps))
      (let ((string-type (nix--open-brace-string-type ps)))
        (put-text-property start (+ 2 start)
                           'nix-string-type string-type)
        (put-text-property start (1+ start)
                           'nix-syntax-antiquote t)
        (put-text-property (1+ start) (+ 2 start)
                           'syntax-table (string-to-syntax "|"))))))

(defun nix-syntax-propertize (start end)
  "Special syntax properties for Nix from START to END."
  (goto-char start)
  (remove-text-properties start end
                          '(syntax-table nil nix-string-type nil nix-syntax-antiquote nil))
  (funcall
   (syntax-propertize-rules
    ("\\\\\\\\"
     (0 nil))
    ("\\\\\""
     (0 nil))
    ("\\\\\\${" (0 (ignore (nix--escaped-antiquote-dq-style))))
    ("'\\{2,\\}" (0 (ignore (nix--single-quotes))))
    ("}''\\([^\\$'\\\\]\\|\\$[^{]\\|\\\\[^nrt]\\)"
     (0 (ignore (nix--antiquote-close-sq-end))))
    ("}\""
     (0 (ignore (nix--antiquote-close-dq-end))))
    ("}\\${"
     (0 (ignore (nix--antiquote-close-open))))
    ("\\${"
     (0 (ignore (nix--antiquote-open))))
    ("}"
     (0 (ignore (nix--antiquote-close))))
    ("\""
     (0 (ignore (nix--double-quotes))))
    )
   start end))

;;; Flycheck

(defconst nix-err-msg-re
  "error: \\(.*\\) at \\(.*\\):\\([0-9]+\\):\\([0-9]+\\)")

(defun nix--parse-errors (output checker buffer)
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (let ((errs '()))
      (while (search-forward-regexp err-msg-re nil t 1)
        (let* ((file (match-string 2))
               (line (string-to-number (match-string 3)))
               (col (string-to-number (match-string 4)))
               (msg (match-string 1)))
          (setq errs
                (cons (flycheck-error-new-at
                       line col 'error msg
                       :filename (and (not (string= file "(string)")) file)
                       :checker checker
                       :buffer buffer)
                      errs))))
    errs)))

(flycheck-def-args-var flycheck-nix-args (nix))

(flycheck-define-checker nix
  "A syntax and evaluation checker for Nix using nix-instantiate."
  :command ("nix-instantiate" "--eval" "--strict" "--show-trace" (eval flycheck-nix-args) "-")
  :standard-input t
  :error-parser nix--parse-errors
  :modes (nix-mode)
  )

(add-to-list 'flycheck-checkers 'nix)

;;; REPL

(defvar nix-prompt-regexp "nix-repl> ")

(define-derived-mode nix-repl-mode comint-mode "Nix-REPL"
  "Interactive prompt for Nix."
  (setq-local comint-prompt-regexp nix-prompt-regexp)
  (setq-local comint-prompt-read-only t))

(defun nix-repl-show ()
  "Load the Nix-REPL."
  (interactive)
  (pop-to-buffer-same-window
   (get-buffer-create "*Nix-REPL*"))
  (unless (comint-check-proc (current-buffer))
    (nix--make-repl-in-buffer (current-buffer))
    (nix-repl-mode)))

(defun nix--make-repl-in-buffer (buffer)
  (make-comint-in-buffer "Nix-REPL" buffer "nix-repl"))

;;; Indentation

(defun nix-indent-level-parens ()
  "Find indent level based on parens."
  (save-excursion
    (beginning-of-line)

    (let ((p1 (point))
	  (p2 (nth 1 (syntax-ppss)))
	  (n 0))

      ;; prevent moving beyond buffer
      (if (eq p2 1)
	  (setq n (1+ n)))

      (while (and p2 (not (eq p2 1))) ;; make sure p2 > 1
	(goto-char p2)
	(backward-char)
	(let ((l1 (line-number-at-pos p1))
	      (l2 (line-number-at-pos p2)))
	  (if (not (eq l1 l2))
	      (setq n (1+ n))))
	(setq p1 p2)
	(setq p2 (nth 1 (syntax-ppss)))

	;; make sure we don't go beyond buffer
	(if (eq p2 1)
	    (setq n (1+ n))))

      n)))

(defun nix-indent-level-let ()
  "Get indent level based on # of let statements."
  (save-excursion
    (beginning-of-line)

    (let ((lets 0)
	  (ins 0))
      (while (not (eq (point) (point-min)))
	(forward-line -1)
	(cond
	 ((and
	   (or
	    (looking-at "[[:space:]]*let$")
	    (looking-at "[[:space:]]*let[[:space:]]")
	    (looking-at ".*[[:space:]]let$"))
	   (not
	    (or
	     (looking-at ".*[[:space:]]in$")
	     (looking-at ".*[[:space:]]in[[:space:]]"))))
	  (setq lets (1+ lets)))
	 ((or
	   (looking-at "^in$")
	   (looking-at "^in[[:space:]]")
	   (looking-at "[[:space:]]+in$")
	   (looking-at "[[:space:]]+in[[:space:]]"))
	  (setq ins (1+ ins)))))

      (- lets ins))))

(defun nix-indent-level-is-closing ()
  "Go forward from beginning of line."
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward "[:space:]")

    (or ;; any of these should -1 indent level
     (looking-at ")")
     (looking-at "}")
     (looking-at "]")
     (looking-at "''")
     (looking-at ",")
     (looking-at "in[[:space:]]")
     (looking-at "in$"))))

(defun nix-indent-level-is-hanging ()
  "Is hanging?"
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward "[:space:]")

    (forward-line -1)
    (end-of-line)
    (skip-chars-backward "\n[:space:]")

    ;; skip through any comments in the way
    (while (nth 4 (syntax-ppss))
      (goto-char (nth 8 (syntax-ppss)))
      (skip-chars-backward "\n[:space:]"))

    (or
     (looking-back "=" 1)
     (looking-back "+" 1)
     ;; (looking-back ":" 1)
     (looking-back "//" 1))))

(defun nix-indent-level ()
  "Get current indent level."
  (* tab-width (+
		(nix-indent-level-parens)
		(nix-indent-level-let)
		(if (nix-indent-level-is-closing) -1
		  (if (nix-indent-level-is-hanging) 1 0)))))

(defun nix-indent-line ()
  "Indent current line in a Nix expression."
  (interactive)
  (cond

   ;; comment
   ((save-excursion
      (beginning-of-line)
      (nth 4 (syntax-ppss))) nil)

   ;; string
   ((save-excursion
      (beginning-of-line)
      (nth 3 (syntax-ppss))) nil)

   ;; else
   (t
    (indent-line-to (nix-indent-level)))))

;; Visit file

(defun nix-visit-file ()
  "Go to file under cursor."
  (interactive)
  (save-excursion
    (forward-whitespace -1)
    (skip-chars-forward " \t")
    (if (looking-at nix-re-file-path)
	(find-file (match-string-no-properties 0)))))

;; Formatting

(defcustom nix-nixfmt-bin "nixfmt"
  "Path to nixfmt executable."
  :group 'nix
  :type 'string)

(defun nix--format-call (buf)
  "Format BUF using nixfmt."
  (with-current-buffer (get-buffer-create "*nixfmt*")
    (erase-buffer)
    (insert-buffer-substring buf)
    (if (zerop (call-process-region (point-min) (point-max) nix-nixfmt-bin t t nil))
        (progn
          (if (not (string= (buffer-string) (with-current-buffer buf (buffer-string))))
              (copy-to-buffer buf (point-min) (point-max)))
          (kill-buffer))
      (error "Nixfmt failed, see *nixfmt* buffer for details"))))

(defun nix-format-buffer ()
  "Format the current buffer using nixfmt."
  (interactive)
  (unless (executable-find nix-nixfmt-bin)
    (error "Could not locate executable \"%s\"" nix-nixfmt-bin))
  (nix--format-call (current-buffer))
  (message "Formatted buffer with rustfmt."))

;; Key maps

(defvar nix-mode-menu (make-sparse-keymap "Nix")
  "Menu for Nix mode.")

(defvar nix-mode-map (make-sparse-keymap)
  "Local keymap used for Nix mode.")

(defun nix-create-keymap ()
  "Create the keymap associated with the Nix mode."
  (define-key nix-mode-map "\C-c\C-f" 'nix-visit-file)
  (define-key nix-mode-map "\C-c\C-r" 'nix-format-buffer))

(defun nix-create-menu ()
  "Create the Nix menu as shown in the menu bar."
  (let ((m '("Nix"
	     ["Goto file" nix-visit-file t]
	     ["Format buffer" nix-format-buffer t])
	   ))
    (easy-menu-define ada-mode-menu nix-mode-map "Menu keymap for Nix mode" m)))

(nix-create-keymap)
(nix-create-menu)

;;;###autoload
(define-derived-mode nix-mode prog-mode "Nix"
  "Major mode for editing Nix expressions.

The following commands may be useful:

  '\\[newline-and-indent]'
    Insert a newline and move the cursor to align with the previous
    non-empty line.

  '\\[fill-paragraph]'
    Refill a paragraph so that all lines are at most `fill-column'
    lines long.  This should do the right thing for comments beginning
    with `#'.  However, this command doesn't work properly yet if the
    comment is adjacent to code (i.e., no intervening empty lines).
    In that case, select the text to be refilled and use
    `\\[fill-region]' instead.

The hook `nix-mode-hook' is run when Nix mode is started.

\\{nix-mode-map}
"
  :syntax-table nix-mode-syntax-table

  (setq-local case-fold-search nil)

  ;; Disable hard tabs and set tab to 2 spaces
  ;; Recommended by nixpkgs manual: https://nixos.org/nixpkgs/manual/#sec-syntax
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 2)

  ;; Font lock support.
  (setq-local font-lock-defaults '(nix-font-lock-keywords nil nil nil nil))

  ;; Special syntax properties for Nix
  (setq-local syntax-propertize-function 'nix-syntax-propertize)

  ;; Look at text properties when parsing
  (setq-local parse-sexp-lookup-properties t)

  ;; Automatic indentation [C-j]
  (setq-local indent-line-function 'nix-indent-line)

  ;; Indenting of comments
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(^\\|\\s-\\);?#+ *")
  (setq-local comment-multi-line t)

  ;; Filling of comments
  (setq-local adaptive-fill-mode t)
  (setq-local paragraph-start "[ \t]*\\(#+[ \t]*\\)?$")
  (setq-local paragraph-separate paragraph-start)

  (easy-menu-add nix-mode-menu nix-mode-map)

  ;; Flycheck
  (flycheck-select-checker 'nix)
  (flycheck-mode))

;;;###autoload
(progn
  (add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode))
  (add-to-list 'auto-mode-alist '("\\.nix.in\\'" . nix-mode)))

(defun nix-mode-reload ()
  "Reload Nix mode."
  (interactive)
  (unload-feature 'nix-mode)
  (require 'nix-mode)
  (nix-mode))

(provide 'nix-mode)

;;; nix-mode.el ends here
