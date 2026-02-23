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

;;; Section Keymaps

(defvar-keymap agentsmith-workspace-section-map
  :doc "Keymap for workspace sections in the agentsmith buffer.
Active when point is on a workspace heading."
  "RET"         #'agentsmith-workspace-open-at-point
  "D"           #'agentsmith-workspace-dired-at-point
  "a"           #'agentsmith-workspace-agent-at-point
  "w"           #'agentsmith-workspace-add-worktree-at-point
  "d"           #'agentsmith-workspace-delete-at-point
  "p"           #'agentsmith-workspace-plans-at-point)

(defvar-keymap agentsmith-worktree-section-map
  :doc "Keymap for worktree sections in the agentsmith buffer.
Active when point is on a worktree line."
  "RET"         #'agentsmith-worktree-open-at-point
  "D"           #'agentsmith-worktree-dired-at-point
  "S-<return>"  #'agentsmith-worktree-agent-popup-at-point
  "a"           #'agentsmith-worktree-agent-at-point
  "d"           #'agentsmith-worktree-remove-at-point)

;;; Buffer State

(defvar-local agentsmith--workspaces nil
  "List of `agentsmith-workspace' structs displayed in this buffer.")

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
  "Refresh the agentsmith status buffer."
  (interactive)
  (let ((inhibit-read-only t)
        (pos (point)))
    (erase-buffer)
    (magit-insert-section (agentsmith-root-section)
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
    (goto-char (min pos (point-max)))))

(defun agentsmith--insert-workspace-section (workspace)
  "Insert a magit section for WORKSPACE."
  (let* ((name (agentsmith-workspace-name workspace))
         (dir (abbreviate-file-name (agentsmith-workspace-directory workspace)))
         (agent (agentsmith-workspace-agent-session workspace))
         (status (agentsmith--get-agent-status
                  agent (agentsmith-workspace-directory workspace))))
    (magit-insert-section (agentsmith-workspace-section workspace t)
      (magit-insert-heading
        (format "%s %s  %s\n"
                (agentsmith--status-indicator status)
                (propertize name 'face 'agentsmith-workspace-heading)
                (propertize dir 'face 'agentsmith-path)))
      ;; Insert worktree children
      (let ((worktrees (agentsmith-workspace-worktrees workspace)))
        (if worktrees
            (dolist (wt worktrees)
              (agentsmith--insert-worktree-section wt))
          (insert (propertize "    No worktrees. Press "  'face 'shadow))
          (insert (propertize "w" 'face 'transient-key))
          (insert (propertize " to add one.\n" 'face 'shadow))))
      (insert "\n"))))

(defun agentsmith--insert-worktree-section (worktree)
  "Insert a magit section for WORKTREE."
  (let* ((name (agentsmith-worktree-name worktree))
         (path (abbreviate-file-name (agentsmith-worktree-path worktree)))
         (agent (agentsmith-worktree-agent-session worktree))
         (status (agentsmith--get-agent-status
                  agent (agentsmith-worktree-path worktree)))
         (branch (or (agentsmith-worktree-branch worktree) "")))
    (magit-insert-section (agentsmith-worktree-section worktree)
      (magit-insert-heading
        (format "    %s %s  %s  %s\n"
                (agentsmith--status-indicator status)
                (propertize name 'face 'agentsmith-worktree-name)
                (propertize branch 'face 'agentsmith-branch)
                (propertize path 'face 'agentsmith-path))))))

;;; Project Switching

(declare-function projectile-add-known-project "projectile" (project-root))

(defun agentsmith--switch-to-existing-project-default (project-dir)
  "Switch to PROJECT-DIR if it has open file-visiting buffers.
Returns non-nil if switched, nil if no buffers found.
Uses `file-in-directory-p' directly rather than projectile's buffer
detection, which can return stale results due to project root caching."
  (let ((bufs (cl-remove-if-not
               (lambda (buf)
                 (when-let* ((f (buffer-file-name buf)))
                   (file-in-directory-p f project-dir)))
               (buffer-list))))
    (when bufs
      (switch-to-buffer (car bufs))
      t)))

(defun agentsmith--switch-to-project (directory)
  "Switch to DIRECTORY, using its parent workspace as the projectile project.
If the project is already open (has file-visiting buffers), switches to
it via `agentsmith-switch-to-existing-project-function' instead of
showing the file finder.  Falls back to `projectile-switch-project-action'
for new projects."
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (ws (agentsmith-workspace-find-by-directory dir))
         (project-dir (if ws
                          (file-name-as-directory
                           (agentsmith-workspace-directory ws))
                        dir)))
    (projectile-add-known-project project-dir)
    (let ((projectile-project-root project-dir))
      (unless (funcall agentsmith-switch-to-existing-project-function project-dir)
        (let ((default-directory dir))
          (funcall projectile-switch-project-action))))))

;;; Default Open Functions

(defun agentsmith-worktree-open-default (worktree)
  "Default function to open WORKTREE -- switches to it as a project."
  (agentsmith--switch-to-project (agentsmith-worktree-path worktree)))

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
  "Delete the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (when (yes-or-no-p (format "Delete workspace '%s'? (files kept on disk) "
                                 (agentsmith-workspace-name ws)))
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
  "Remove the worktree at point from its workspace and disk."
  (interactive)
  (let ((wt (agentsmith--worktree-at-point))
        (ws (agentsmith--workspace-for-worktree-at-point)))
    (unless wt (user-error "No worktree at point"))
    (unless ws (user-error "Cannot determine parent workspace"))
    (when (yes-or-no-p (format "Remove worktree '%s'? "
                               (agentsmith-worktree-name wt)))
      ;; Stop agent if running
      (when-let* ((session (agentsmith-worktree-agent-session wt)))
        (agentsmith-agent-stop-session session))
      ;; Remove from disk
      (condition-case err
          (agentsmith-worktree-remove
           (agentsmith-worktree-vcs wt)
           (agentsmith-worktree-path wt)
           (agentsmith-worktree-source-repo wt))
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
  (let* ((repo-path (read-directory-name "Repository path: "))
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
  "Delete the workspace or remove the worktree at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point) (agentsmith-worktree-remove-at-point))
   ((agentsmith--workspace-at-point) (agentsmith-workspace-delete-at-point))
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

;;; Mode Definition

(defvar-keymap agentsmith-mode-map
  :doc "Keymap for `agentsmith-mode'.
Users can override bindings with `keymap-set'."
  :parent magit-section-mode-map
  "g"           #'agentsmith-buffer-refresh
  "c"           #'agentsmith-create-workspace
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
    (kbd "RET")          #'agentsmith-open-at-point
    (kbd "S-<return>")   #'agentsmith-agent-popup-at-point
    "a"                  #'agentsmith-agent-at-point
    "d"                  #'agentsmith-delete-at-point
    "D"                  #'agentsmith-dired-at-point
    "q"                  #'quit-window)
  (add-hook 'agentsmith-mode-hook #'evil-normalize-keymaps))

(provide 'agentsmith-buffer)
;;; agentsmith-buffer.el ends here
