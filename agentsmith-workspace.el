;;; agentsmith-workspace.el --- Workspace management for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, processes

;; This file is part of AgentSmith.

;;; Commentary:

;; Workspace CRUD operations, persistence, and global registry.
;; A workspace is a directory containing worktrees from multiple repos,
;; along with agent sessions and plans.

;;; Code:

(require 'cl-lib)

;;; Data Structures

(cl-defstruct (agentsmith-workspace (:copier nil))
  "A workspace containing worktrees and agent sessions."
  (name nil :type (or string null))
  (directory nil :type (or string null))
  (worktrees nil :type list)
  (default-agent-backend 'claude-code-ide :type symbol)
  (agent-session nil)
  (metadata nil :type list))

(cl-defstruct (agentsmith-worktree (:copier nil))
  "A single worktree within a workspace."
  (name nil :type (or string null))
  (path nil :type (or string null))
  (source-repo nil :type (or string null))
  (vcs nil :type (or symbol null))
  (branch nil :type (or string null))
  (agent-session nil)
  (metadata nil :type list))

(cl-defstruct (agentsmith-agent-session (:copier nil))
  "Tracks a running agent session."
  (backend nil :type (or symbol null))
  (buffer nil)
  (status 'stopped :type symbol)
  (worktree-path nil :type (or string null))
  (metadata nil :type list))

;;; Customization

(defgroup agentsmith-workspace nil
  "Workspace settings for AgentSmith."
  :group 'agentsmith
  :prefix "agentsmith-workspace-")

(defcustom agentsmith-default-workspace-parent "~/workspaces/"
  "Default parent directory for new workspaces."
  :type 'directory
  :group 'agentsmith-workspace)

(defcustom agentsmith-workspace-directory
  (expand-file-name "agentsmith" user-emacs-directory)
  "Directory for agentsmith global state (registry, etc)."
  :type 'directory
  :group 'agentsmith-workspace)

(defcustom agentsmith-after-workspace-create-hook nil
  "Hook run after a workspace is created.
Each function receives the workspace struct as its argument."
  :type 'hook
  :group 'agentsmith-workspace)

(defcustom agentsmith-after-workspace-delete-hook nil
  "Hook run after a workspace is deleted.
Each function receives the workspace struct as its argument."
  :type 'hook
  :group 'agentsmith-workspace)

;;; Serialization

(defun agentsmith-workspace--serialize-worktree (wt)
  "Serialize worktree WT to a plist."
  (list :name (agentsmith-worktree-name wt)
        :path (agentsmith-worktree-path wt)
        :source-repo (agentsmith-worktree-source-repo wt)
        :vcs (agentsmith-worktree-vcs wt)
        :branch (agentsmith-worktree-branch wt)
        :metadata (agentsmith-worktree-metadata wt)))

(defun agentsmith-workspace--deserialize-worktree (plist)
  "Deserialize PLIST into an `agentsmith-worktree' struct."
  (make-agentsmith-worktree
   :name (plist-get plist :name)
   :path (plist-get plist :path)
   :source-repo (plist-get plist :source-repo)
   :vcs (plist-get plist :vcs)
   :branch (plist-get plist :branch)
   :metadata (plist-get plist :metadata)))

(defun agentsmith-workspace--serialize (ws)
  "Serialize workspace WS to a plist (excludes runtime state)."
  (list :name (agentsmith-workspace-name ws)
        :directory (agentsmith-workspace-directory ws)
        :default-agent-backend (agentsmith-workspace-default-agent-backend ws)
        :worktrees (mapcar #'agentsmith-workspace--serialize-worktree
                           (agentsmith-workspace-worktrees ws))
        :metadata (agentsmith-workspace-metadata ws)))

(defun agentsmith-workspace--deserialize (plist)
  "Deserialize PLIST into an `agentsmith-workspace' struct."
  (make-agentsmith-workspace
   :name (plist-get plist :name)
   :directory (plist-get plist :directory)
   :default-agent-backend (or (plist-get plist :default-agent-backend)
                              'claude-code-ide)
   :worktrees (mapcar #'agentsmith-workspace--deserialize-worktree
                       (plist-get plist :worktrees))
   :metadata (plist-get plist :metadata)))

;;; Persistence

(defconst agentsmith-workspace--config-file ".agentsmith.el"
  "Name of the workspace config file within each workspace directory.")

(defun agentsmith-workspace-save (workspace)
  "Persist WORKSPACE to its directory's .agentsmith.el file."
  (let* ((dir (agentsmith-workspace-directory workspace))
         (file (expand-file-name agentsmith-workspace--config-file dir)))
    (unless (file-directory-p dir)
      (error "Workspace directory does not exist: %s" dir))
    (with-temp-file file
      (insert ";; -*- mode: emacs-lisp; -*-\n")
      (insert ";; AgentSmith workspace config -- do not edit by hand\n\n")
      (let ((print-level nil)
            (print-length nil))
        (pp (agentsmith-workspace--serialize workspace) (current-buffer))))
    workspace))

(defun agentsmith-workspace-load (directory)
  "Load and return the workspace struct from DIRECTORY's .agentsmith.el."
  (let ((file (expand-file-name agentsmith-workspace--config-file directory)))
    (unless (file-readable-p file)
      (error "No agentsmith config found in: %s" directory))
    (with-temp-buffer
      (insert-file-contents file)
      (agentsmith-workspace--deserialize (read (current-buffer))))))

;;; Global Registry

(defun agentsmith-workspace--registry-file ()
  "Return the path to the global workspace registry file."
  (expand-file-name "registry.el" agentsmith-workspace-directory))

(defun agentsmith-workspace--ensure-state-dir ()
  "Ensure the agentsmith state directory exists."
  (unless (file-directory-p agentsmith-workspace-directory)
    (make-directory agentsmith-workspace-directory t)))

(defun agentsmith-workspace-registry-load ()
  "Load and return the list of registered workspace directories."
  (let ((file (agentsmith-workspace--registry-file)))
    (if (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))
      nil)))

(defun agentsmith-workspace-registry-save (directories)
  "Save DIRECTORIES list to the global registry."
  (agentsmith-workspace--ensure-state-dir)
  (with-temp-file (agentsmith-workspace--registry-file)
    (insert ";; -*- mode: emacs-lisp; -*-\n")
    (insert ";; AgentSmith workspace registry\n\n")
    (let ((print-level nil)
          (print-length nil))
      (pp directories (current-buffer)))))

(defun agentsmith-workspace-register (directory)
  "Add DIRECTORY to the global workspace registry."
  (let* ((dir (expand-file-name directory))
         (current (agentsmith-workspace-registry-load)))
    (unless (member dir current)
      (agentsmith-workspace-registry-save (cons dir current)))))

(defun agentsmith-workspace-deregister (directory)
  "Remove DIRECTORY from the global workspace registry."
  (let* ((dir (expand-file-name directory))
         (current (agentsmith-workspace-registry-load)))
    (agentsmith-workspace-registry-save (delete dir current))))

(defun agentsmith-workspace-list-registered ()
  "Return list of registered workspace directories that still exist."
  (cl-remove-if-not #'file-directory-p
                     (agentsmith-workspace-registry-load)))

(defun agentsmith-workspace-load-all ()
  "Load all registered workspaces. Returns list of workspace structs.
Skips workspaces that fail to load."
  (let (workspaces)
    (dolist (dir (agentsmith-workspace-list-registered))
      (condition-case err
          (push (agentsmith-workspace-load dir) workspaces)
        (error (message "AgentSmith: failed to load workspace at %s: %s"
                        dir (error-message-string err)))))
    (nreverse workspaces)))

;;; Workspace CRUD

(defun agentsmith-workspace-create (name directory &optional default-backend)
  "Create a new workspace named NAME at DIRECTORY.
DEFAULT-BACKEND specifies the agent backend (defaults to `claude-code-ide').
Returns the new workspace struct."
  (let* ((dir (expand-file-name directory))
         (plans-dir (expand-file-name "plans/" dir))
         (ws (make-agentsmith-workspace
              :name name
              :directory dir
              :default-agent-backend (or default-backend 'claude-code-ide)
              :worktrees nil
              :metadata nil)))
    ;; Create directories
    (make-directory dir t)
    (make-directory plans-dir t)
    ;; Save config and register
    (agentsmith-workspace-save ws)
    (agentsmith-workspace-register dir)
    ;; Register with projectile if available
    (when (fboundp 'projectile-add-known-project)
      (projectile-add-known-project dir))
    ;; Run hooks
    (run-hook-with-args 'agentsmith-after-workspace-create-hook ws)
    ws))

(defun agentsmith-workspace-add-worktree (workspace worktree)
  "Add WORKTREE struct to WORKSPACE. Saves the workspace config."
  (setf (agentsmith-workspace-worktrees workspace)
        (append (agentsmith-workspace-worktrees workspace) (list worktree)))
  (agentsmith-workspace-save workspace)
  workspace)

(defun agentsmith-workspace-remove-worktree (workspace worktree)
  "Remove WORKTREE from WORKSPACE. Saves the workspace config.
Does NOT remove the worktree from disk -- caller is responsible for that."
  (setf (agentsmith-workspace-worktrees workspace)
        (cl-remove worktree (agentsmith-workspace-worktrees workspace)
                   :test #'equal))
  (agentsmith-workspace-save workspace)
  workspace)

(defun agentsmith-workspace-delete (workspace)
  "Delete WORKSPACE. Deregisters but does NOT remove files from disk.
Prompts for confirmation in interactive use."
  (agentsmith-workspace-deregister (agentsmith-workspace-directory workspace))
  (run-hook-with-args 'agentsmith-after-workspace-delete-hook workspace))

;;; Interactive Commands

(defun agentsmith-workspace-create-interactive (name directory)
  "Interactively create a new workspace.
Prompts for NAME and DIRECTORY."
  (interactive
   (let* ((name (read-string "Workspace name: "))
          (default-dir (expand-file-name name agentsmith-default-workspace-parent))
          (directory (read-directory-name "Workspace directory: " default-dir default-dir)))
     (list name directory)))
  (let ((ws (agentsmith-workspace-create name directory)))
    (message "Created workspace: %s at %s"
             (agentsmith-workspace-name ws)
             (agentsmith-workspace-directory ws))
    ws))

(defun agentsmith-workspace-open-interactive ()
  "Interactively select and open a registered workspace."
  (interactive)
  (let* ((dirs (agentsmith-workspace-list-registered))
         (workspaces (mapcar (lambda (dir)
                               (condition-case nil
                                   (cons (agentsmith-workspace-name
                                          (agentsmith-workspace-load dir))
                                         dir)
                                 (error (cons (abbreviate-file-name dir) dir))))
                             dirs)))
    (unless workspaces
      (user-error "No registered workspaces found"))
    (let* ((choice (completing-read "Open workspace: " workspaces nil t))
           (dir (cdr (assoc choice workspaces))))
      (agentsmith-workspace-load dir))))

(defun agentsmith-workspace-delete-interactive ()
  "Interactively select and delete a workspace."
  (interactive)
  (let ((ws (agentsmith-workspace-open-interactive)))
    (when (yes-or-no-p (format "Delete workspace '%s'? (files kept on disk) "
                               (agentsmith-workspace-name ws)))
      (agentsmith-workspace-delete ws)
      (message "Deleted workspace: %s" (agentsmith-workspace-name ws)))))

(defun agentsmith-workspace-open-plans (workspace)
  "Open the plans directory for WORKSPACE in dired."
  (let ((plans-dir (expand-file-name "plans/"
                                     (agentsmith-workspace-directory workspace))))
    (unless (file-directory-p plans-dir)
      (make-directory plans-dir t))
    (dired plans-dir)))

;;; Directory Lookup

(defun agentsmith-workspace-find-by-directory (dir)
  "Find the registered workspace containing DIR.
When multiple workspaces match, returns the one with the deepest
\(most specific) directory path to avoid ambiguity."
  (let ((dir (expand-file-name dir))
        (best nil)
        (best-len 0))
    (dolist (ws (agentsmith-workspace-load-all))
      (let ((ws-dir (agentsmith-workspace-directory ws)))
        (when (and (file-in-directory-p dir ws-dir)
                   (> (length ws-dir) best-len))
          (setq best ws
                best-len (length ws-dir)))))
    best))

(defun agentsmith-worktree-find-by-directory (dir)
  "Find the registered worktree containing DIR.
Returns a (WORKSPACE . WORKTREE) cons or nil."
  (let ((dir (expand-file-name dir)))
    (cl-block nil
      (dolist (ws (agentsmith-workspace-load-all))
        (dolist (wt (agentsmith-workspace-worktrees ws))
          (when (file-in-directory-p dir (agentsmith-worktree-path wt))
            (cl-return (cons ws wt))))))))

(provide 'agentsmith-workspace)
;;; agentsmith-workspace.el ends here
