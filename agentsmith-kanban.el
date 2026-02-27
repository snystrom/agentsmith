;;; agentsmith-kanban.el --- Kanban board persistence for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools

;; This file is part of AgentSmith.

;;; Commentary:

;; Persistence and pure data operations for organizing workspaces into
;; kanban-style columns.  The backing store is a plain org file
;; (`kanban.org') where headings are columns and list items are workspace
;; names.  Users can rearrange things manually in org-mode.

;;; Code:

(require 'agentsmith-workspace)

;;; Customization

(defcustom agentsmith-kanban-file
  (expand-file-name "kanban.org" agentsmith-workspace-directory)
  "Path to the kanban org file.
Headings are columns, list items are workspace names."
  :type 'file
  :group 'agentsmith-workspace)

;;; Reading

(defun agentsmith-kanban-read ()
  "Parse `agentsmith-kanban-file' and return an alist of columns.
Each entry is (COLUMN-NAME . (WORKSPACE-NAMES...)).
Returns nil if the file does not exist."
  (when (file-readable-p agentsmith-kanban-file)
    (with-temp-buffer
      (insert-file-contents agentsmith-kanban-file)
      (let ((columns nil)
            (current-col nil)
            (current-items nil))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (cond
             ((string-match "^\\* \\(.+\\)" line)
              ;; Flush previous column
              (when current-col
                (push (cons current-col (nreverse current-items)) columns))
              (setq current-col (match-string 1 line)
                    current-items nil))
             ((string-match "^- \\(.+\\)" line)
              (when current-col
                (push (string-trim (match-string 1 line)) current-items)))))
          (forward-line 1))
        ;; Flush last column
        (when current-col
          (push (cons current-col (nreverse current-items)) columns))
        (nreverse columns)))))

;;; Writing

(defun agentsmith-kanban-write (columns)
  "Write COLUMNS alist to `agentsmith-kanban-file'.
COLUMNS is ((COLUMN-NAME . (WORKSPACE-NAMES...)) ...)."
  (let ((dir (file-name-directory agentsmith-kanban-file)))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  (with-temp-file agentsmith-kanban-file
    (dolist (col columns)
      (insert (format "* %s\n" (car col)))
      (dolist (name (cdr col))
        (insert (format "- %s\n" name))))))

;;; Column Operations
;; All functions take a COLUMNS alist and return a new alist.
;; Callers are responsible for writing back via `agentsmith-kanban-write'.

(defun agentsmith-kanban-add-column (columns name)
  "Return COLUMNS with a new empty column NAME appended."
  (append columns (list (cons name nil))))

(defun agentsmith-kanban-remove-column (columns name)
  "Return COLUMNS with column NAME removed.
Workspaces in that column become unsorted (caller handles)."
  (cl-remove name columns :key #'car :test #'string=))

(defun agentsmith-kanban-rename-column (columns old new)
  "Return COLUMNS with column OLD renamed to NEW."
  (mapcar (lambda (col)
            (if (string= (car col) old)
                (cons new (cdr col))
              col))
          columns))

(defun agentsmith-kanban-move-workspace (columns ws-name target-column)
  "Return COLUMNS with WS-NAME moved to TARGET-COLUMN.
Removes WS-NAME from its current column (if any) and appends to target."
  (let ((cleaned (mapcar (lambda (col)
                           (cons (car col)
                                 (cl-remove ws-name (cdr col)
                                            :test #'string=)))
                         columns)))
    (mapcar (lambda (col)
              (if (string= (car col) target-column)
                  (cons (car col) (append (cdr col) (list ws-name)))
                col))
            cleaned)))

;;; Workspace Shifting (vertical within/across columns)

(defun agentsmith-kanban-shift-workspace-down (columns ws-name)
  "Return COLUMNS with WS-NAME shifted one position down.
Within a column, swap with the next item.  At the bottom of a
column, move to the top of the next column.  Return nil if
WS-NAME is at the very end of the last column."
  (let ((col-idx nil)
        (item-idx nil))
    ;; Find ws-name
    (cl-loop for i from 0
             for col in columns
             do (let ((pos (cl-position ws-name (cdr col) :test #'string=)))
                  (when pos
                    (setq col-idx i item-idx pos)
                    (cl-return))))
    (unless col-idx (cl-return-from agentsmith-kanban-shift-workspace-down nil))
    (let* ((col (nth col-idx columns))
           (items (cdr col)))
      (cond
       ;; Not at end of column — swap with next item
       ((< item-idx (1- (length items)))
        (let ((new-items (copy-sequence items)))
          (cl-rotatef (nth item-idx new-items) (nth (1+ item-idx) new-items))
          (agentsmith-kanban--replace-column-items columns col-idx new-items)))
       ;; At end of column — move to top of next column
       ((< col-idx (1- (length columns)))
        (let* ((cleaned (agentsmith-kanban--remove-from-column columns col-idx ws-name))
               (next-idx (1+ col-idx))
               (next-col (nth next-idx cleaned))
               (new-items (cons ws-name (cdr next-col))))
          (agentsmith-kanban--replace-column-items cleaned next-idx new-items)))
       ;; At very end — no-op
       (t nil)))))

(defun agentsmith-kanban-shift-workspace-up (columns ws-name)
  "Return COLUMNS with WS-NAME shifted one position up.
Within a column, swap with the previous item.  At the top of a
column, move to the bottom of the previous column.  Return nil if
WS-NAME is at the very start of the first column."
  (let ((col-idx nil)
        (item-idx nil))
    (cl-loop for i from 0
             for col in columns
             do (let ((pos (cl-position ws-name (cdr col) :test #'string=)))
                  (when pos
                    (setq col-idx i item-idx pos)
                    (cl-return))))
    (unless col-idx (cl-return-from agentsmith-kanban-shift-workspace-up nil))
    (let* ((col (nth col-idx columns))
           (items (cdr col)))
      (cond
       ;; Not at top of column — swap with previous item
       ((> item-idx 0)
        (let ((new-items (copy-sequence items)))
          (cl-rotatef (nth item-idx new-items) (nth (1- item-idx) new-items))
          (agentsmith-kanban--replace-column-items columns col-idx new-items)))
       ;; At top of column — move to bottom of previous column
       ((> col-idx 0)
        (let* ((cleaned (agentsmith-kanban--remove-from-column columns col-idx ws-name))
               (prev-idx (1- col-idx))
               (prev-col (nth prev-idx cleaned))
               (new-items (append (cdr prev-col) (list ws-name))))
          (agentsmith-kanban--replace-column-items cleaned prev-idx new-items)))
       ;; At very start — no-op
       (t nil)))))

;;; Workspace Moving (horizontal between columns)

(defun agentsmith-kanban-move-workspace-to-next-column (columns ws-name)
  "Return COLUMNS with WS-NAME moved to the next column.
Appends to the end of the next column.  Return nil if already in
the last column or not found."
  (let ((col-idx nil))
    (cl-loop for i from 0
             for col in columns
             when (member ws-name (cdr col))
             do (setq col-idx i) (cl-return))
    (unless col-idx (cl-return-from agentsmith-kanban-move-workspace-to-next-column nil))
    (when (>= col-idx (1- (length columns)))
      (cl-return-from agentsmith-kanban-move-workspace-to-next-column nil))
    (let* ((cleaned (agentsmith-kanban--remove-from-column columns col-idx ws-name))
           (next-idx (1+ col-idx))
           (next-col (nth next-idx cleaned))
           (new-items (append (cdr next-col) (list ws-name))))
      (agentsmith-kanban--replace-column-items cleaned next-idx new-items))))

(defun agentsmith-kanban-move-workspace-to-prev-column (columns ws-name)
  "Return COLUMNS with WS-NAME moved to the previous column.
Appends to the end of the previous column.  Return nil if already
in the first column or not found."
  (let ((col-idx nil))
    (cl-loop for i from 0
             for col in columns
             when (member ws-name (cdr col))
             do (setq col-idx i) (cl-return))
    (unless col-idx (cl-return-from agentsmith-kanban-move-workspace-to-prev-column nil))
    (when (<= col-idx 0)
      (cl-return-from agentsmith-kanban-move-workspace-to-prev-column nil))
    (let* ((cleaned (agentsmith-kanban--remove-from-column columns col-idx ws-name))
           (prev-idx (1- col-idx))
           (prev-col (nth prev-idx cleaned))
           (new-items (append (cdr prev-col) (list ws-name))))
      (agentsmith-kanban--replace-column-items cleaned prev-idx new-items))))

;;; Column Reordering (vertical)

(defun agentsmith-kanban-shift-column-down (columns col-name)
  "Return COLUMNS with column COL-NAME swapped with the one below.
Return nil if COL-NAME is the last column or not found."
  (let ((idx (cl-position col-name columns :key #'car :test #'string=)))
    (unless idx (cl-return-from agentsmith-kanban-shift-column-down nil))
    (when (>= idx (1- (length columns)))
      (cl-return-from agentsmith-kanban-shift-column-down nil))
    (let ((new-cols (copy-sequence columns)))
      (cl-rotatef (nth idx new-cols) (nth (1+ idx) new-cols))
      new-cols)))

(defun agentsmith-kanban-shift-column-up (columns col-name)
  "Return COLUMNS with column COL-NAME swapped with the one above.
Return nil if COL-NAME is the first column or not found."
  (let ((idx (cl-position col-name columns :key #'car :test #'string=)))
    (unless idx (cl-return-from agentsmith-kanban-shift-column-up nil))
    (when (<= idx 0)
      (cl-return-from agentsmith-kanban-shift-column-up nil))
    (let ((new-cols (copy-sequence columns)))
      (cl-rotatef (nth idx new-cols) (nth (1- idx) new-cols))
      new-cols)))

;;; Helpers

(defun agentsmith-kanban--all-assigned-names (columns)
  "Return a flat list of all workspace names assigned to any column in COLUMNS."
  (apply #'append (mapcar #'cdr columns)))

(defun agentsmith-kanban--replace-column-items (columns col-idx new-items)
  "Return COLUMNS with column at COL-IDX having NEW-ITEMS as its items."
  (cl-loop for i from 0
           for col in columns
           collect (if (= i col-idx)
                       (cons (car col) new-items)
                     col)))

(defun agentsmith-kanban--remove-from-column (columns col-idx ws-name)
  "Return COLUMNS with WS-NAME removed from column at COL-IDX."
  (cl-loop for i from 0
           for col in columns
           collect (if (= i col-idx)
                       (cons (car col)
                             (cl-remove ws-name (cdr col) :test #'string=))
                     col)))

(provide 'agentsmith-kanban)
;;; agentsmith-kanban.el ends here
