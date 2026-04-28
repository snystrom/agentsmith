;;; agentsmith-buffer.el --- Status buffer for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, processes

;; This file is part of AgentSmith.

;;; Commentary:

;; The main AgentSmith status buffer, derived from `magit-section-mode'.
;; Displays a hierarchical view of workspaces and their worktrees,
;; with agent status indicators and section-specific keybindings.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'agentsmith-workspace)
(require 'agentsmith-worktree)
(require 'agentsmith-agent)
(require 'agentsmith-kanban)

;;; Customization

(defgroup agentsmith-buffer nil
  "Buffer display settings for AgentSmith."
  :group 'agentsmith
  :prefix "agentsmith-buffer-")

(defcustom agentsmith-status-indicators
  '((stopped  . ("--" . shadow))
    (ready    . ("OK" . success))
    (thinking . (".." . warning)))
  "Alist mapping agent status symbols to (STRING . FACE) display specs.
Customize this to change how agent status is shown in the buffer."
  :type '(alist :key-type symbol
                :value-type (cons string face))
  :group 'agentsmith-buffer)

(defcustom agentsmith-worktree-open-function #'agentsmith-worktree-open-default
  "Function called to open a worktree.
Receives one argument: the `agentsmith-worktree' struct.
Default switches to the worktree as a projectile project.
Override to customize behavior, e.g. for project.el integration."
  :type 'function
  :group 'agentsmith-buffer)

(defcustom agentsmith-workspace-open-function #'agentsmith-workspace-open-default
  "Function called to open a workspace.
Receives one argument: the `agentsmith-workspace' struct.
Default switches to the workspace as a projectile project.
Override to customize behavior, e.g. for project.el integration."
  :type 'function
  :group 'agentsmith-buffer)

(defcustom agentsmith-switch-to-existing-project-function
  #'agentsmith--switch-to-existing-project-default
  "Function to switch to an already-open project.
Called with one argument: the project directory (with trailing slash).
Should return non-nil if it successfully switched to the project,
nil if the project is not already open.
When this returns nil, `projectile-switch-project-action' is called
instead to do a full project switch with file selection.

Doom Emacs users who want workspace tab switching can set this to
`agentsmith-switch-to-existing-project-doom-workspace'."
  :type 'function
  :group 'agentsmith-buffer)

(defun agentsmith-switch-to-existing-project-doom-workspace (dir)
  "Switch to an existing Doom workspace tab for DIR.
For use as `agentsmith-switch-to-existing-project-function' with
Doom Emacs's `ui/workspaces' module."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (when (and (fboundp '+workspace-exists-p)
               (+workspace-exists-p name))
      (+workspace-switch name)
      ;; Return nil if no file-visiting buffers exist, so the caller
      ;; falls through to projectile-switch-project-action for file selection.
      (cl-some (lambda (buf)
                 (when-let* ((f (buffer-file-name buf)))
                   (file-in-directory-p f dir)))
               (buffer-list)))))

(declare-function persp-names "perspective")
(declare-function persp-switch "perspective")

(defun agentsmith-switch-to-existing-project-perspective (dir)
  "Switch to an existing perspective.el perspective for DIR.
For use as `agentsmith-switch-to-existing-project-function' with the
`perspective' (and `persp-projectile') package.  The perspective name
is the basename of DIR, matching how `persp-projectile' names them.
Returns non-nil if file-visiting buffers belong to DIR, so the caller
skips the new-project file finder."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (when (and (fboundp 'persp-names)
               (fboundp 'persp-switch)
               (member name (persp-names)))
      (persp-switch name)
      (cl-some (lambda (buf)
                 (when-let* ((f (buffer-file-name buf)))
                   (file-in-directory-p f dir)))
               (buffer-list)))))

(defcustom agentsmith-create-project-function
  #'agentsmith--create-project-default
  "Function to create / switch to a perspective for a new project.
Called with one argument: the project directory (with trailing slash).
Runs after `agentsmith-switch-to-existing-project-function' returns
nil (i.e. the project is not already open).  Should ensure that any
perspective / workspace tab for the project exists and is active.
Return value is ignored.

Bundled helpers:
- `agentsmith-create-project-doom-workspace' (Doom Emacs `ui/workspaces')
- `agentsmith-create-project-perspective'    (perspective.el)"
  :type 'function
  :group 'agentsmith-buffer)

(defun agentsmith--create-project-default (_dir)
  "No-op default for `agentsmith-create-project-function'."
  nil)

(declare-function +workspace-new "ext:workspaces")
(declare-function +workspace-switch "ext:workspaces")
(declare-function +workspace-exists-p "ext:workspaces")

(defun agentsmith-create-project-doom-workspace (dir)
  "Ensure a Doom workspace tab exists for DIR and switch to it.
For use as `agentsmith-create-project-function' with Doom Emacs's
`ui/workspaces' module."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (when (fboundp '+workspace-switch)
      (unless (and (fboundp '+workspace-exists-p)
                   (+workspace-exists-p name))
        (when (fboundp '+workspace-new)
          (+workspace-new name)))
      (+workspace-switch name))))

(defun agentsmith-create-project-perspective (dir)
  "Ensure a perspective.el perspective exists for DIR and switch to it.
For use as `agentsmith-create-project-function' with the `perspective'
package.  `persp-switch' creates the perspective if it does not exist."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (when (fboundp 'persp-switch)
      (persp-switch name))))

;;; Faces

(defface agentsmith-workspace-heading
  '((t :inherit magit-section-heading :height 1.1))
  "Face for workspace names in the agentsmith buffer."
  :group 'agentsmith-buffer)

(defface agentsmith-worktree-name
  '((t :inherit magit-branch-local))
  "Face for worktree names in the agentsmith buffer."
  :group 'agentsmith-buffer)

(defface agentsmith-path
  '((t :inherit font-lock-comment-face))
  "Face for paths in the agentsmith buffer."
  :group 'agentsmith-buffer)

(defface agentsmith-branch
  '((t :inherit font-lock-string-face))
  "Face for branch/bookmark names in the agentsmith buffer."
  :group 'agentsmith-buffer)

(defface agentsmith-column-heading
  '((t :inherit magit-section-heading :weight bold))
  "Face for kanban column headings in the agentsmith buffer."
  :group 'agentsmith-buffer)

(defface agentsmith-column-unregistered
  '((t :inherit shadow))
  "Face for workspace names in kanban that are not in the registry."
  :group 'agentsmith-buffer)

;;; Section Classes

;; Define EIEIO section subclasses so we can set our own keymap
;; without depending on magit's hardcoded `magit-TYPENAME-section-map' naming.

(defclass agentsmith-root-section (magit-section) ()
  "Top-level root section for the agentsmith buffer.")

(defclass agentsmith-workspace-section (magit-section)
  ((keymap :initform 'agentsmith-workspace-section-map))
  "Section representing a workspace.")

(defclass agentsmith-worktree-section (magit-section)
  ((keymap :initform 'agentsmith-worktree-section-map))
  "Section representing a worktree within a workspace.")

(defclass agentsmith-column-section (magit-section)
  ((keymap :initform 'agentsmith-column-section-map))
  "Section representing a kanban column.")

;;; Section Keymaps

(defvar-keymap agentsmith-workspace-section-map
  :doc "Keymap for workspace sections in the agentsmith buffer.
Active when point is on a workspace heading."
  "RET"         #'agentsmith-workspace-open-at-point
  "D"           #'agentsmith-workspace-dired-at-point
  "V"           #'agentsmith-workspace-vcs-at-point
  "a"           #'agentsmith-workspace-agent-at-point
  "w"           #'agentsmith-workspace-add-worktree-at-point
  "x"           #'agentsmith-transient-delete
  "p"           #'agentsmith-transient-workspace-plans
  "m"           #'agentsmith-kanban-move-workspace-at-point
  "M-n"         #'agentsmith-kanban-shift-down-at-point
  "M-p"         #'agentsmith-kanban-shift-up-at-point)

(defvar-keymap agentsmith-worktree-section-map
  :doc "Keymap for worktree sections in the agentsmith buffer.
Active when point is on a worktree line."
  "RET"         #'agentsmith-worktree-open-at-point
  "D"           #'agentsmith-worktree-dired-at-point
  "V"           #'agentsmith-worktree-vcs-at-point
  "S-<return>"  #'agentsmith-worktree-agent-popup-at-point
  "a"           #'agentsmith-worktree-agent-at-point
  "x"           #'agentsmith-transient-delete)

(defvar-keymap agentsmith-column-section-map
  :doc "Keymap for column sections in the kanban view.
Active when point is on a column heading."
  "RET"         #'magit-section-toggle
  "c"           #'agentsmith-kanban-create-column
  "r"           #'agentsmith-kanban-rename-column-at-point
  "x"           #'agentsmith-kanban-delete-column-at-point
  "m"           #'agentsmith-kanban-move-workspace-at-point
  "M-n"         #'agentsmith-kanban-shift-down-at-point
  "M-p"         #'agentsmith-kanban-shift-up-at-point)

;;; Buffer State

(defvar-local agentsmith--workspaces nil
  "List of `agentsmith-workspace' structs displayed in this buffer.")

(defvar-local agentsmith--current-view 'workspaces
  "Current view mode: `workspaces' (flat list) or `kanban' (columns).")

(defvar-local agentsmith--kanban-columns nil
  "Cached parsed kanban columns alist from kanban.org.")

;;; Status Indicator

(defun agentsmith--status-indicator (status)
  "Return a propertized string for agent STATUS symbol."
  (let ((spec (alist-get status agentsmith-status-indicators
                         '("??" . font-lock-warning-face))))
    (propertize (format "[%s]" (car spec)) 'face (cdr spec))))

(defun agentsmith--get-agent-status (agent-session &optional directory)
  "Get the current status of AGENT-SESSION, or query backend for DIRECTORY.
If AGENT-SESSION is nil but DIRECTORY is provided, queries the default
backend directly (detects externally-started agents)."
  (cond
   (agent-session
    (agentsmith-agent-status-for-dir
     (agentsmith-agent-session-worktree-path agent-session)
     (agentsmith-agent-session-backend agent-session)))
   (directory
    (agentsmith-agent-status-for-dir directory))
   (t 'stopped)))

;;; Section Rendering

(defun agentsmith-buffer-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the agentsmith status buffer.
Dispatches to the appropriate renderer based on `agentsmith--current-view'."
  (interactive)
  (setq agentsmith--workspaces (agentsmith-workspace-load-all))
  (let ((inhibit-read-only t)
        (pos (point)))
    (erase-buffer)
    (magit-insert-section (agentsmith-root-section)
      (pcase agentsmith--current-view
        ('kanban (agentsmith--render-kanban-view))
        (_ (agentsmith--render-workspaces-view))))
    (goto-char (min pos (point-max)))))

(defun agentsmith--render-workspaces-view ()
  "Render the flat workspace list view."
  (insert (propertize "AgentSmith" 'face 'magit-section-heading) "\n")
  (if agentsmith--workspaces
      (dolist (ws agentsmith--workspaces)
        (agentsmith--insert-workspace-section ws))
    (insert "\n")
    (insert (propertize "  No workspaces. Press " 'face 'shadow))
    (insert (propertize "c" 'face 'transient-key))
    (insert (propertize " to create one, or " 'face 'shadow))
    (insert (propertize "?" 'face 'transient-key))
    (insert (propertize " for help.\n" 'face 'shadow))))

(defun agentsmith--insert-workspace-section (workspace &optional indent)
  "Insert a magit section for WORKSPACE.
Optional INDENT is a string prefix for visual nesting (e.g. in kanban view)."
  (let* ((indent (or indent ""))
         (name (agentsmith-workspace-name workspace))
         (dir (abbreviate-file-name (agentsmith-workspace-directory workspace)))
         (agent (agentsmith-workspace-agent-session workspace))
         (status (agentsmith--get-agent-status
                  agent (agentsmith-workspace-directory workspace))))
    (magit-insert-section (agentsmith-workspace-section workspace t)
      (magit-insert-heading
        (format "%s%s %s  %s\n"
                indent
                (agentsmith--status-indicator status)
                (propertize name 'face 'agentsmith-workspace-heading)
                (propertize dir 'face 'agentsmith-path)))
      ;; Insert worktree children
      (let ((worktrees (agentsmith-workspace-worktrees workspace)))
        (if worktrees
            (dolist (wt worktrees)
              (agentsmith--insert-worktree-section wt indent))
          (insert (propertize (format "%s    No worktrees. Press " indent) 'face 'shadow))
          (insert (propertize "w" 'face 'transient-key))
          (insert (propertize " to add one.\n" 'face 'shadow))))
      (insert "\n"))))

(defun agentsmith--insert-worktree-section (worktree &optional indent)
  "Insert a magit section for WORKTREE.
Optional INDENT is a string prefix for visual nesting (e.g. in kanban view)."
  (let* ((indent (or indent ""))
         (name (agentsmith-worktree-name worktree))
         (path (abbreviate-file-name (agentsmith-worktree-path worktree)))
         (agent (agentsmith-worktree-agent-session worktree))
         (status (agentsmith--get-agent-status
                  agent (agentsmith-worktree-path worktree)))
         (branch (or (agentsmith-worktree-branch worktree) "")))
    (magit-insert-section (agentsmith-worktree-section worktree)
      (magit-insert-heading
        (format "%s    %s %s  %s  %s\n"
                indent
                (agentsmith--status-indicator status)
                (propertize name 'face 'agentsmith-worktree-name)
                (propertize branch 'face 'agentsmith-branch)
                (propertize path 'face 'agentsmith-path))))))

;;; Kanban View Rendering

(defun agentsmith--render-kanban-view ()
  "Render the kanban column view."
  (setq agentsmith--kanban-columns (agentsmith-kanban-read))
  (insert (propertize "AgentSmith" 'face 'magit-section-heading)
          (propertize "  [kanban]" 'face 'shadow) "\n")
  (let* ((ws-by-name (make-hash-table :test #'equal))
         (all-names nil))
    ;; Build lookup table: workspace name → struct
    (dolist (ws agentsmith--workspaces)
      (let ((name (agentsmith-workspace-name ws)))
        (puthash name ws ws-by-name)
        (push name all-names)))
    (setq all-names (nreverse all-names))
    ;; Render each column
    (dolist (col agentsmith--kanban-columns)
      (agentsmith--insert-column-section
       (car col) (cdr col) ws-by-name))
    ;; Compute and render Unsorted
    (let* ((assigned (agentsmith-kanban--all-assigned-names
                      agentsmith--kanban-columns))
           (unsorted (cl-remove-if (lambda (n) (member n assigned))
                                   all-names)))
      (when unsorted
        (agentsmith--insert-column-section
         "Unsorted" unsorted ws-by-name)))))

(defun agentsmith--insert-column-section (name ws-names ws-by-name)
  "Insert a kanban column section.
NAME is the column heading.  WS-NAMES is the list of workspace name
strings.  WS-BY-NAME is a hash table mapping names to workspace structs."
  (magit-insert-section (agentsmith-column-section name t)
    (magit-insert-heading
      (format "%s\n" (propertize name 'face 'agentsmith-column-heading)))
    (if ws-names
        (dolist (ws-name ws-names)
          (let ((ws (gethash ws-name ws-by-name)))
            (if ws
                (agentsmith--insert-workspace-section ws "  ")
              ;; Workspace in kanban.org but not in registry
              (insert (propertize (format "    ? %s (not registered)\n" ws-name)
                                  'face 'agentsmith-column-unregistered)))))
      (insert (propertize "    (empty)\n" 'face 'shadow)))
    (insert "\n")))

;;; Kanban Interactive Commands

(defun agentsmith--column-at-point ()
  "Return the column name string at point, or nil."
  (when-let* ((section (magit-current-section)))
    (and (agentsmith-column-section-p section)
         (oref section value))))

(defun agentsmith-buffer-set-view (view)
  "Set the current view to VIEW and refresh.
VIEW is `workspaces' or `kanban'."
  (setq agentsmith--current-view view)
  (agentsmith-buffer-refresh))

(defun agentsmith-buffer-view-workspaces ()
  "Switch to the flat workspace list view."
  (interactive)
  (agentsmith-buffer-set-view 'workspaces))

(defun agentsmith-buffer-view-kanban ()
  "Switch to the kanban column view."
  (interactive)
  (agentsmith-buffer-set-view 'kanban))

(defun agentsmith-kanban-create-column ()
  "Create a new kanban column."
  (interactive)
  (let* ((name (read-string "Column name: "))
         (columns (or (agentsmith-kanban-read) nil)))
    (when (string-empty-p name)
      (user-error "Column name cannot be empty"))
    (when (assoc name columns)
      (user-error "Column '%s' already exists" name))
    (agentsmith-kanban-write (agentsmith-kanban-add-column columns name))
    (agentsmith-buffer-refresh)))

(defun agentsmith-kanban-rename-column-at-point ()
  "Rename the kanban column at point."
  (interactive)
  (let ((col-name (agentsmith--column-at-point)))
    (unless col-name
      (user-error "No column at point"))
    (when (string= col-name "Unsorted")
      (user-error "Cannot rename the Unsorted column"))
    (let* ((new-name (read-string (format "Rename '%s' to: " col-name)))
           (columns (agentsmith-kanban-read)))
      (when (string-empty-p new-name)
        (user-error "Column name cannot be empty"))
      (when (assoc new-name columns)
        (user-error "Column '%s' already exists" new-name))
      (agentsmith-kanban-write
       (agentsmith-kanban-rename-column columns col-name new-name))
      (agentsmith-buffer-refresh))))

(defun agentsmith-kanban-delete-column-at-point ()
  "Delete the kanban column at point.
Workspaces in this column become unsorted."
  (interactive)
  (let ((col-name (agentsmith--column-at-point)))
    (unless col-name
      (user-error "No column at point"))
    (when (string= col-name "Unsorted")
      (user-error "Cannot delete the Unsorted column"))
    (when (yes-or-no-p (format "Delete column '%s'? (workspaces become unsorted) "
                               col-name))
      (agentsmith-kanban-write
       (agentsmith-kanban-remove-column (agentsmith-kanban-read) col-name))
      (agentsmith-buffer-refresh))))

(defun agentsmith-kanban-move-workspace-at-point ()
  "Move the workspace at point to a different kanban column."
  (interactive)
  (unless (eq agentsmith--current-view 'kanban)
    (user-error "Only available in kanban view"))
  (let ((ws (agentsmith--workspace-at-point)))
    (unless ws
      (user-error "No workspace at point"))
    (let* ((columns (or (agentsmith-kanban-read) nil))
           (col-names (mapcar #'car columns))
           (ws-name (agentsmith-workspace-name ws))
           (target (completing-read
                    (format "Move '%s' to column: " ws-name)
                    col-names nil t)))
      (agentsmith-kanban-write
       (agentsmith-kanban-move-workspace columns ws-name target))
      (agentsmith-buffer-refresh)
      (agentsmith--goto-workspace-section ws-name))))

(defun agentsmith-kanban-edit-file ()
  "Open `agentsmith-kanban-file' in org-mode for manual editing."
  (interactive)
  (find-file agentsmith-kanban-file))

(defun agentsmith-kanban-clean ()
  "Remove workspace names from kanban.org that are not in the registry."
  (interactive)
  (let* ((columns (agentsmith-kanban-read))
         (registered (mapcar #'agentsmith-workspace-name
                             (agentsmith-workspace-load-all)))
         (cleaned (mapcar (lambda (col)
                            (cons (car col)
                                  (cl-remove-if-not
                                   (lambda (name) (member name registered))
                                   (cdr col))))
                          columns)))
    (agentsmith-kanban-write cleaned)
    (when (derived-mode-p 'agentsmith-mode)
      (agentsmith-buffer-refresh))
    (message "Kanban cleaned")))

;;; Kanban Point Restoration

(defun agentsmith--goto-workspace-section (ws-name)
  "Move point to the workspace section for WS-NAME after a refresh."
  (goto-char (point-min))
  (cl-labels
      ((walk (section)
         (when (and (agentsmith-workspace-section-p section)
                    (let ((val (oref section value)))
                      (and (agentsmith-workspace-p val)
                           (string= (agentsmith-workspace-name val) ws-name))))
           (goto-char (oref section start))
           (cl-return-from agentsmith--goto-workspace-section t))
         (dolist (child (oref section children))
           (walk child))))
    (when-let* ((root (magit-current-section)))
      (walk root))))

(defun agentsmith--goto-column-section (col-name)
  "Move point to the column section for COL-NAME after a refresh."
  (goto-char (point-min))
  (cl-labels
      ((walk (section)
         (when (and (agentsmith-column-section-p section)
                    (equal (oref section value) col-name))
           (goto-char (oref section start))
           (cl-return-from agentsmith--goto-column-section t))
         (dolist (child (oref section children))
           (walk child))))
    (when-let* ((root (magit-current-section)))
      (walk root))))

;;; Kanban Movement Commands

(defun agentsmith-kanban--ensure-kanban-view ()
  "Signal an error if not in kanban view."
  (unless (eq agentsmith--current-view 'kanban)
    (user-error "Only available in kanban view")))

(defun agentsmith-kanban--ws-name-at-point ()
  "Return the workspace name at point, checking for Unsorted column.
Signals user-error if workspace is in the Unsorted column."
  (let ((ws (agentsmith--workspace-at-point)))
    (unless ws (user-error "No workspace at point"))
    (let ((ws-name (agentsmith-workspace-name ws))
          (columns (agentsmith-kanban-read)))
      (unless (agentsmith-kanban--all-assigned-names columns)
        ;; All workspaces are unsorted
        (user-error "Workspace is unsorted; assign to a column first"))
      (unless (member ws-name (agentsmith-kanban--all-assigned-names columns))
        (user-error "Workspace is unsorted; assign to a column first"))
      ws-name)))

(defun agentsmith-kanban-shift-down-at-point ()
  "Context-sensitive shift down in kanban view.
On a workspace: shift it down within its column or wrap to next.
On a column heading: swap the column with the one below."
  (interactive)
  (agentsmith-kanban--ensure-kanban-view)
  (cond
   ((agentsmith--workspace-at-point)
    (let* ((ws-name (agentsmith-kanban--ws-name-at-point))
           (columns (agentsmith-kanban-read))
           (new-columns (agentsmith-kanban-shift-workspace-down columns ws-name)))
      (if new-columns
          (progn
            (agentsmith-kanban-write new-columns)
            (agentsmith-buffer-refresh)
            (agentsmith--goto-workspace-section ws-name))
        (message "Already at boundary"))))
   ((agentsmith--column-at-point)
    (let* ((col-name (agentsmith--column-at-point))
           (columns (agentsmith-kanban-read)))
      (when (string= col-name "Unsorted")
        (user-error "Cannot reorder the Unsorted column"))
      (let ((new-columns (agentsmith-kanban-shift-column-down columns col-name)))
        (if new-columns
            (progn
              (agentsmith-kanban-write new-columns)
              (agentsmith-buffer-refresh)
              (agentsmith--goto-column-section col-name))
          (message "Already at boundary")))))
   (t (user-error "No workspace or column at point"))))

(defun agentsmith-kanban-shift-up-at-point ()
  "Context-sensitive shift up in kanban view.
On a workspace: shift it up within its column or wrap to previous.
On a column heading: swap the column with the one above."
  (interactive)
  (agentsmith-kanban--ensure-kanban-view)
  (cond
   ((agentsmith--workspace-at-point)
    (let* ((ws-name (agentsmith-kanban--ws-name-at-point))
           (columns (agentsmith-kanban-read))
           (new-columns (agentsmith-kanban-shift-workspace-up columns ws-name)))
      (if new-columns
          (progn
            (agentsmith-kanban-write new-columns)
            (agentsmith-buffer-refresh)
            (agentsmith--goto-workspace-section ws-name))
        (message "Already at boundary"))))
   ((agentsmith--column-at-point)
    (let* ((col-name (agentsmith--column-at-point))
           (columns (agentsmith-kanban-read)))
      (when (string= col-name "Unsorted")
        (user-error "Cannot reorder the Unsorted column"))
      (let ((new-columns (agentsmith-kanban-shift-column-up columns col-name)))
        (if new-columns
            (progn
              (agentsmith-kanban-write new-columns)
              (agentsmith-buffer-refresh)
              (agentsmith--goto-column-section col-name))
          (message "Already at boundary")))))
   (t (user-error "No workspace or column at point"))))

(defun agentsmith-kanban-move-workspace-next-column-at-point ()
  "Move the workspace at point to the next kanban column."
  (interactive)
  (agentsmith-kanban--ensure-kanban-view)
  (let* ((ws-name (agentsmith-kanban--ws-name-at-point))
         (columns (agentsmith-kanban-read))
         (new-columns (agentsmith-kanban-move-workspace-to-next-column
                       columns ws-name)))
    (if new-columns
        (progn
          (agentsmith-kanban-write new-columns)
          (agentsmith-buffer-refresh)
          (agentsmith--goto-workspace-section ws-name))
      (message "Already at boundary"))))

(defun agentsmith-kanban-move-workspace-prev-column-at-point ()
  "Move the workspace at point to the previous kanban column."
  (interactive)
  (agentsmith-kanban--ensure-kanban-view)
  (let* ((ws-name (agentsmith-kanban--ws-name-at-point))
         (columns (agentsmith-kanban-read))
         (new-columns (agentsmith-kanban-move-workspace-to-prev-column
                       columns ws-name)))
    (if new-columns
        (progn
          (agentsmith-kanban-write new-columns)
          (agentsmith-buffer-refresh)
          (agentsmith--goto-workspace-section ws-name))
      (message "Already at boundary"))))

;;; Project Switching

(declare-function projectile-add-known-project "projectile" (project-root))
(declare-function projectile-project-files "projectile" (project-root))
(defvar projectile-switch-project-action)

(defun agentsmith--switch-to-existing-project-default (project-dir)
  "Switch to PROJECT-DIR if it has open file-visiting buffers.
Returns non-nil if switched, nil if no buffers found.
If a project buffer is visible in a window, selects that window.
Otherwise switches to the first project buffer.
Uses `file-in-directory-p' directly rather than projectile's buffer
detection, which can return stale results due to project root caching."
  (let ((bufs (cl-remove-if-not
               (lambda (buf)
                 (when-let* ((f (buffer-file-name buf)))
                   (file-in-directory-p f project-dir)))
               (buffer-list))))
    (when bufs
      (if-let* ((win (cl-some #'get-buffer-window bufs)))
          (select-window win)
        (switch-to-buffer (car bufs)))
      t)))

(defun agentsmith--find-file-in-worktree (ws wt)
  "Run a file finder scoped to worktree WT inside workspace WS.
Lists project files of WT, then `find-file's the choice with
`projectile-project-root' bound to WS's directory so the resulting
buffer is associated with the workspace project."
  (let* ((wt-dir (file-name-as-directory (agentsmith-worktree-path wt)))
         (ws-dir (file-name-as-directory
                  (agentsmith-workspace-directory ws)))
         (files (let ((projectile-project-root wt-dir))
                  (projectile-project-files wt-dir)))
         (choice (completing-read
                  (format "Find file [%s]: "
                          (agentsmith-worktree-name wt))
                  files nil t)))
    (let ((projectile-project-root ws-dir))
      (projectile-add-known-project ws-dir)
      (find-file (expand-file-name choice wt-dir)))))

(defun agentsmith--switch-to-project (directory &optional action)
  "Switch projectile to DIRECTORY's parent workspace, then run ACTION.
The workspace becomes the active projectile project so that perspective
integrations (Doom workspaces, persp-projectile, ...) hooked into
`projectile-before-switch-project-hook' /
`projectile-after-switch-project-hook' create or switch to a
perspective named after the workspace, not after a worktree.
If the project is already open, calls
`agentsmith-switch-to-existing-project-function' instead.
ACTION, if non-nil, is bound as `projectile-switch-project-action'
for the duration of the new-project switch."
  (when (derived-mode-p 'agentsmith-mode)
    (quit-window))
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (ws (agentsmith-workspace-find-by-directory dir))
         (project-dir (if ws
                          (file-name-as-directory
                           (agentsmith-workspace-directory ws))
                        dir)))
    (projectile-add-known-project project-dir)
    (unless (funcall agentsmith-switch-to-existing-project-function project-dir)
      ;; Workspace dirs aren't real projectile projects, so neither
      ;; `projectile-switch-project-by-name'-based bridges (Doom advice,
      ;; persp-projectile) nor projectile's switch hooks reliably fire
      ;; here.  Hand off to a user-configurable function that creates /
      ;; switches the perspective directly via the package's own API.
      (funcall agentsmith-create-project-function project-dir)
      (let ((default-directory project-dir))
        (funcall (or action projectile-switch-project-action))))))

;;; Default Open Functions

(defun agentsmith-worktree-open-default (worktree)
  "Default function to open WORKTREE.
Switches projectile to the parent workspace (so perspective
integrations create/switch the workspace's perspective via projectile's
hooks), then runs the worktree-scoped file finder."
  (let* ((wt-dir (agentsmith-worktree-path worktree))
         (ws (agentsmith-workspace-find-by-directory wt-dir)))
    (agentsmith--switch-to-project
     wt-dir
     (when ws (lambda () (agentsmith--find-file-in-worktree ws worktree))))))

(defun agentsmith-workspace-open-default (workspace)
  "Default function to open WORKSPACE -- switches to it as a project."
  (agentsmith--switch-to-project (agentsmith-workspace-directory workspace)))

;;; Section Commands -- Workspace

(defun agentsmith--workspace-at-point ()
  "Return the workspace struct at point, or nil."
  (when-let* ((section (magit-current-section)))
    (and (agentsmith-workspace-section-p section)
         (oref section value))))

(defun agentsmith--worktree-at-point ()
  "Return the worktree struct at point, or nil."
  (when-let* ((section (magit-current-section)))
    (and (agentsmith-worktree-section-p section)
         (oref section value))))

(defun agentsmith--workspace-for-worktree-at-point ()
  "Return the workspace containing the worktree at point."
  (when-let* ((section (magit-current-section))
              (parent (oref section parent)))
    (and (agentsmith-worktree-section-p section)
         (agentsmith-workspace-section-p parent)
         (oref parent value))))

(defun agentsmith-workspace-open-at-point ()
  "Open the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (funcall agentsmith-workspace-open-function ws)
    (user-error "No workspace at point")))

(defun agentsmith-workspace-agent-at-point ()
  "Manage agents for the workspace at point.
Dispatches to the workspace agent transient if available,
otherwise starts an agent directly."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (if (fboundp 'agentsmith-transient-workspace-agent)
          (agentsmith-transient-workspace-agent)
        ;; Fallback if transient not loaded
        (agentsmith-agent-start-for-workspace ws))
    (user-error "No workspace at point")))

(defun agentsmith-workspace-add-worktree-at-point ()
  "Add a worktree to the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith-workspace-add-worktree-interactive ws)
    (user-error "No workspace at point")))

(defun agentsmith-workspace-delete-at-point ()
  "Deregister the workspace at point (keep files on disk)."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (when (yes-or-no-p (format "Deregister workspace '%s'? (files kept on disk) "
                                 (agentsmith-workspace-name ws)))
        (agentsmith-workspace-delete ws)
        (setq agentsmith--workspaces
              (cl-remove ws agentsmith--workspaces :test #'eq))
        (agentsmith-buffer-refresh))
    (user-error "No workspace at point")))

(defun agentsmith-workspace-delete-from-disk-at-point ()
  "Delete the workspace at point, removing all files from disk."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (when (yes-or-no-p
             (format "PERMANENTLY delete workspace '%s' and ALL files in %s? "
                     (agentsmith-workspace-name ws)
                     (abbreviate-file-name (agentsmith-workspace-directory ws))))
        ;; Stop all agents
        (dolist (wt (agentsmith-workspace-worktrees ws))
          (when-let* ((session (agentsmith-worktree-agent-session wt)))
            (agentsmith-agent-stop-session session)))
        (when-let* ((session (agentsmith-workspace-agent-session ws)))
          (agentsmith-agent-stop-session session))
        ;; Remove each worktree via VCS
        (dolist (wt (agentsmith-workspace-worktrees ws))
          (condition-case err
              (agentsmith-worktree-remove
               (agentsmith-worktree-vcs wt)
               (agentsmith-worktree-path wt)
               (agentsmith-worktree-source-repo wt)
               (agentsmith-worktree-branch wt))
            (error (message "Warning: %s" (error-message-string err)))))
        ;; Delete workspace directory from disk
        (delete-directory (agentsmith-workspace-directory ws) t)
        ;; Deregister
        (agentsmith-workspace-delete ws)
        (setq agentsmith--workspaces
              (cl-remove ws agentsmith--workspaces :test #'eq))
        (agentsmith-buffer-refresh))
    (user-error "No workspace at point")))

(defun agentsmith-workspace-plans-at-point ()
  "Open plans directory for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith-workspace-open-plans ws)
    (user-error "No workspace at point")))

(defun agentsmith-workspace-scratch-at-point ()
  "Open scratch buffer for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith-workspace-open-scratch ws)
    (user-error "No workspace at point")))

(defun agentsmith-workspace-create-plan-at-point ()
  "Create a new plan file for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (let ((name (read-string "Plan name: ")))
        (agentsmith-workspace-create-plan ws name))
    (user-error "No workspace at point")))

(defun agentsmith-workspace-find-plan-at-point ()
  "Find an existing plan file for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith-workspace-find-plan ws)
    (user-error "No workspace at point")))

;;; Section Commands -- Worktree

(defun agentsmith-worktree-open-at-point ()
  "Open the worktree at point."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (funcall agentsmith-worktree-open-function wt)
    (user-error "No worktree at point")))

(defun agentsmith-worktree-agent-popup-at-point ()
  "Show the agent buffer for the worktree at point in a popup.
Cascading behavior:
1. Show existing agentsmith-tracked session buffer
2. Auto-detect externally started agent buffer
3. Start a new agent with the default backend, then show its buffer"
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (progn
        (agentsmith-agent-popup-for-worktree wt)
        (when (derived-mode-p 'agentsmith-mode)
          (agentsmith-buffer-refresh)))
    (user-error "No worktree at point")))

(defun agentsmith-worktree-agent-at-point ()
  "Manage agents for the worktree at point.
Dispatches to the worktree agent transient if available."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (if (fboundp 'agentsmith-transient-worktree-agent)
          (agentsmith-transient-worktree-agent)
        ;; Fallback if transient not loaded
        (agentsmith-agent-start-for-worktree wt))
    (user-error "No worktree at point")))

(defun agentsmith-worktree-remove-at-point ()
  "Deregister the worktree at point (keep files on disk)."
  (interactive)
  (let ((wt (agentsmith--worktree-at-point))
        (ws (agentsmith--workspace-for-worktree-at-point)))
    (unless wt (user-error "No worktree at point"))
    (unless ws (user-error "Cannot determine parent workspace"))
    (when (yes-or-no-p (format "Deregister worktree '%s'? (files kept on disk) "
                               (agentsmith-worktree-name wt)))
      (when-let* ((session (agentsmith-worktree-agent-session wt)))
        (agentsmith-agent-stop-session session))
      (agentsmith-workspace-remove-worktree ws wt)
      (agentsmith-buffer-refresh))))

(defun agentsmith-worktree-remove-from-disk-at-point ()
  "Remove the worktree at point from its workspace and disk."
  (interactive)
  (let ((wt (agentsmith--worktree-at-point))
        (ws (agentsmith--workspace-for-worktree-at-point)))
    (unless wt (user-error "No worktree at point"))
    (unless ws (user-error "Cannot determine parent workspace"))
    (when (yes-or-no-p (format "PERMANENTLY remove worktree '%s' from disk? "
                               (agentsmith-worktree-name wt)))
      ;; Stop agent if running
      (when-let* ((session (agentsmith-worktree-agent-session wt)))
        (agentsmith-agent-stop-session session))
      ;; Remove from disk via VCS
      (condition-case err
          (agentsmith-worktree-remove
           (agentsmith-worktree-vcs wt)
           (agentsmith-worktree-path wt)
           (agentsmith-worktree-source-repo wt)
           (agentsmith-worktree-branch wt))
        (error (message "Warning: failed to remove worktree from disk: %s"
                        (error-message-string err))))
      ;; Remove from workspace struct and save
      (agentsmith-workspace-remove-worktree ws wt)
      (agentsmith-buffer-refresh))))

;;; Interactive Add Worktree

(defun agentsmith-workspace-add-worktree-interactive (workspace)
  "Interactively add a worktree to WORKSPACE.
Prompts for repository path. Uses the workspace name as the VCS
worktree/branch name automatically. The display name in the UI
is derived from the repo basename for identification."
  (let* ((repo-path (read-directory-name "Repository path: "
                                         agentsmith-default-repo-parent))
         (vcs (agentsmith-worktree-detect-vcs repo-path))
         (ws-name (agentsmith-workspace-name workspace))
         (repo-basename (file-name-nondirectory (directory-file-name repo-path)))
         (target-dir (expand-file-name repo-basename
                                       (agentsmith-workspace-directory workspace))))
    (unless vcs
      (user-error "No git or jj repository found at: %s" repo-path))
    ;; Create the worktree on disk -- use workspace name for VCS name/branch
    (agentsmith-worktree-create vcs repo-path target-dir ws-name ws-name)
    ;; Build the struct and add to workspace
    (let ((wt (make-agentsmith-worktree
               :name repo-basename
               :path target-dir
               :source-repo (expand-file-name repo-path)
               :vcs vcs
               :branch ws-name)))
      (agentsmith-workspace-add-worktree workspace wt)
      (when (derived-mode-p 'agentsmith-mode)
        (agentsmith-buffer-refresh))
      (message "Added worktree: %s (%s)" repo-basename vcs)
      wt)))

;;; Unified Dispatch Commands
;; Context-sensitive commands that check workspace vs worktree at point.
;; Used by evil normal-state bindings and available for general use.

(defun agentsmith-open-at-point ()
  "Open the workspace or worktree at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-open-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-open-at-point))
   (t (user-error "Nothing at point"))))

(defun agentsmith-agent-at-point ()
  "Open agent transient for the workspace or worktree at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-agent-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-agent-at-point))
   (t (user-error "No workspace or worktree at point"))))

(defun agentsmith-delete-at-point ()
  "Deregister the workspace or worktree at point (keep files on disk)."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-remove-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-delete-at-point))
   (t (user-error "Nothing at point"))))

(defun agentsmith-delete-from-disk-at-point ()
  "Delete the workspace or worktree at point, removing files from disk."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-remove-from-disk-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-delete-from-disk-at-point))
   (t (user-error "Nothing at point"))))

(defun agentsmith-agent-popup-at-point ()
  "Show agent buffer for the workspace or worktree at point.
On a worktree, cascades: show existing → autodetect → start new.
On a workspace, starts or shows the workspace agent."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-agent-popup-at-point))
   ((agentsmith--workspace-at-point)
    (let ((ws (agentsmith--workspace-at-point)))
      (agentsmith-agent-popup-for-workspace ws)
      (when (derived-mode-p 'agentsmith-mode)
        (agentsmith-buffer-refresh))))
   (t (user-error "No workspace or worktree at point"))))

;;; Dired Commands

(defun agentsmith-workspace-dired-at-point ()
  "Open the workspace at point in dired."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (dired (agentsmith-workspace-directory ws))
    (user-error "No workspace at point")))

(defun agentsmith-worktree-dired-at-point ()
  "Open the worktree at point in dired."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (dired (agentsmith-worktree-path wt))
    (user-error "No worktree at point")))

(defun agentsmith-dired-at-point ()
  "Open the workspace or worktree at point in dired."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-dired-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-dired-at-point))
   (t (user-error "Nothing at point"))))

;;; VCS Commands

(defun agentsmith-worktree-vcs-at-point ()
  "Open the VCS interface for the worktree at point."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (agentsmith--open-vcs-for-worktree wt)
    (user-error "No worktree at point")))

(defun agentsmith-workspace-vcs-at-point ()
  "Open the VCS interface for the workspace directory at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith--open-vcs-for-directory
       (agentsmith-workspace-directory ws))
    (user-error "No workspace at point")))

(defun agentsmith-vcs-at-point ()
  "Open the VCS interface for the workspace or worktree at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-vcs-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-vcs-at-point))
   (t (user-error "Nothing at point"))))

;;; Mode Definition

(defvar-keymap agentsmith-mode-map
  :doc "Keymap for `agentsmith-mode'.
Users can override bindings with `keymap-set'."
  :parent magit-section-mode-map
  "g"           #'agentsmith-buffer-refresh
  "c"           #'agentsmith-create-workspace
  "i"           #'agentsmith-workspace-import
  "v"           #'agentsmith-transient-view
  "q"           #'quit-window
  "?"           #'agentsmith-dispatch)

(define-derived-mode agentsmith-mode magit-section-mode "AgentSmith"
  "Major mode for managing agentsmith workspaces and agent sessions.

\\{agentsmith-mode-map}"
  :group 'agentsmith
  (setq-local revert-buffer-function #'agentsmith-buffer-refresh)
  (setq-local bookmark-make-record-function #'agentsmith--bookmark-make-record))

;;; Bookmark Support

(defun agentsmith--bookmark-make-record ()
  "Create a bookmark record for the agentsmith buffer."
  `(,(format "agentsmith")
    (handler . agentsmith--bookmark-handler)))

(defun agentsmith--bookmark-handler (_record)
  "Handle an agentsmith bookmark RECORD."
  (agentsmith))

;;; Evil Integration

(with-eval-after-load 'evil
  (evil-set-initial-state 'agentsmith-mode 'normal)
  (evil-define-key* 'normal agentsmith-mode-map
    "?"                  #'agentsmith-dispatch
    "gr"                 #'agentsmith-buffer-refresh
    "c"                  #'agentsmith-create-workspace
    "i"                  #'agentsmith-workspace-import
    "v"                  #'agentsmith-transient-view
    (kbd "RET")          #'agentsmith-open-at-point
    (kbd "S-<return>")   #'agentsmith-agent-popup-at-point
    "a"                  #'agentsmith-agent-at-point
    "x"                  #'agentsmith-transient-delete
    "D"                  #'agentsmith-dired-at-point
    "V"                  #'agentsmith-vcs-at-point
    "q"                  #'quit-window
    ;; Kanban movement (J/K/H/L/m)
    "J"                  #'agentsmith-kanban-shift-down-at-point
    "K"                  #'agentsmith-kanban-shift-up-at-point
    "H"                  #'agentsmith-kanban-move-workspace-prev-column-at-point
    "L"                  #'agentsmith-kanban-move-workspace-next-column-at-point
    "m"                  #'agentsmith-kanban-move-workspace-at-point)
  (add-hook 'agentsmith-mode-hook #'evil-normalize-keymaps))

(provide 'agentsmith-buffer)
;;; agentsmith-buffer.el ends here
