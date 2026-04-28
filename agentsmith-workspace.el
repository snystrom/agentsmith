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

(defcustom agentsmith-default-repo-parent "~/repos/"
  "Default directory shown when prompting for a repository to add as a worktree."
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
  "Delete WORKSPACE. Deregisters but does NOT remove files from disk."
  (agentsmith-workspace-deregister (agentsmith-workspace-directory workspace))
  (when (fboundp 'projectile-remove-known-project)
    (projectile-remove-known-project
     (file-name-as-directory (agentsmith-workspace-directory workspace))))
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

(declare-function agentsmith-worktree-detect-vcs "agentsmith-worktree" (repo-path))
(declare-function agentsmith-worktree-branch-info "agentsmith-worktree" (vcs worktree-path))
(declare-function agentsmith-worktree-doctor "agentsmith-worktree" (vcs worktree-path &optional repo-path))
(declare-function agentsmith-worktree-repair "agentsmith-worktree" (vcs worktree-path &optional repo-path))
(declare-function agentsmith-buffer-refresh "agentsmith-buffer" (&optional _ignore-auto _noconfirm))
(defvar agentsmith-buffer-name)
(defvar agentsmith--workspaces)

(defun agentsmith-workspace--refresh-buffer (workspace)
  "Add or replace WORKSPACE in the buffer state and refresh if the buffer exists.
Removes any existing entry whose name matches before pushing."
  (when-let* ((buf (and (boundp 'agentsmith-buffer-name)
                        (get-buffer agentsmith-buffer-name))))
    (with-current-buffer buf
      (setq agentsmith--workspaces
            (cl-remove (agentsmith-workspace-name workspace)
                       agentsmith--workspaces
                       :key #'agentsmith-workspace-name
                       :test #'string=))
      (push workspace agentsmith--workspaces)
      (agentsmith-buffer-refresh))))

(defun agentsmith-workspace--dir= (a b)
  "Return non-nil if directory paths A and B refer to the same directory."
  (string= (file-name-as-directory (expand-file-name a))
           (file-name-as-directory (expand-file-name b))))

(defun agentsmith-workspace--diagnose (ws actual-dir)
  "Return a list of issue plists for workspace WS located at ACTUAL-DIR.
Compares the struct's stored `:directory' against ACTUAL-DIR and runs
`agentsmith-worktree-doctor' on each worktree.  Does not load from
disk -- callers must provide the already-loaded workspace struct."
  (let (issues)
    (unless (agentsmith-workspace--dir= (agentsmith-workspace-directory ws)
                                        actual-dir)
      (push (list :type 'directory-mismatch
                  :stored (agentsmith-workspace-directory ws)
                  :actual actual-dir)
            issues))
    (dolist (wt (agentsmith-workspace-worktrees ws))
      (when-let* ((vcs (agentsmith-worktree-vcs wt))
                  (wt-issues (agentsmith-worktree-doctor
                              vcs
                              (agentsmith-worktree-path wt)
                              (agentsmith-worktree-source-repo wt))))
        (push (list :type 'worktree
                    :name (agentsmith-worktree-name wt)
                    :issues wt-issues)
              issues)))
    (nreverse issues)))

(defun agentsmith-workspace-doctor (directory)
  "Return a list of issue plists for the workspace at DIRECTORY.

Loads the .agentsmith.el config in DIRECTORY and reports problems.
Known issue types:
  `directory-mismatch' -- stored `:directory' differs from DIRECTORY
                          (fields: :stored, :actual)
  `worktree'           -- a worktree has issues (fields: :name, :issues)
                          where :issues is a list from
                          `agentsmith-worktree-doctor'

An empty list means the workspace is healthy.  When called
interactively, issues are displayed in the *agentsmith-doctor*
buffer."
  (interactive (list (read-directory-name "Diagnose workspace directory: ")))
  (let* ((dir (expand-file-name directory))
         (config-file (expand-file-name agentsmith-workspace--config-file dir)))
    (unless (file-readable-p config-file)
      (user-error "No agentsmith config found in: %s" dir))
    (let* ((ws (agentsmith-workspace-load dir))
           (issues (agentsmith-workspace--diagnose ws dir)))
      (when (called-interactively-p 'interactive)
        (agentsmith-workspace--doctor-display ws issues))
      issues)))

(defun agentsmith-workspace--doctor-display (ws issues)
  "Display ISSUES from `agentsmith-workspace-doctor' for workspace WS."
  (if (null issues)
      (message "Workspace %s: no issues found"
               (agentsmith-workspace-name ws))
    (let ((buf (get-buffer-create "*agentsmith-doctor*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Workspace: %s\n" (agentsmith-workspace-name ws)))
          (insert (format "Directory: %s\n\n"
                          (agentsmith-workspace-directory ws)))
          (dolist (issue issues)
            (pcase (plist-get issue :type)
              ('directory-mismatch
               (insert (format "* directory-mismatch\n    stored: %s\n    actual: %s\n"
                               (plist-get issue :stored)
                               (plist-get issue :actual))))
              ('worktree
               (insert (format "* worktree: %s\n" (plist-get issue :name)))
               (dolist (wi (plist-get issue :issues))
                 (insert (format "    - %s" (plist-get wi :type)))
                 (let ((extras (cl-loop for (k v) on wi by #'cddr
                                        unless (eq k :type)
                                        collect (format "%s=%s" k v))))
                   (when extras
                     (insert " (" (mapconcat #'identity extras ", ") ")")))
                 (insert "\n"))))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer buf))))

(defun agentsmith-workspace--worktree-needs-rewrite-p (wt-issues)
  "Return non-nil if WT-ISSUES indicates the worktree path should be rewritten."
  (cl-some (lambda (i) (memq (plist-get i :type) '(path-missing vcs-broken)))
           wt-issues))

(defun agentsmith-workspace--worktree-has-issue-p (type wt-issues)
  "Return non-nil if WT-ISSUES contains an issue of TYPE."
  (cl-some (lambda (i) (eq (plist-get i :type) type)) wt-issues))

(defun agentsmith-workspace-repair (directory)
  "Repair the workspace at DIRECTORY based on `agentsmith-workspace-doctor'.

Applies these fixes:
  - Stale `:directory' gets rewritten to DIRECTORY.
  - For each worktree whose path looks broken (missing on disk, or VCS
    metadata unusable), rewrites `:path' to DIRECTORY/<basename> and
    calls `agentsmith-worktree-repair' to fix VCS metadata.
  - Updates the global registry (adds DIRECTORY, drops the old path).

Failures in per-worktree VCS repair (e.g. jj, which upstream does not
support) are reported but do not abort the overall repair.  Missing
source-repo paths are reported but not auto-fixed.  After all repairs,
re-diagnoses the workspace to verify the outcome."
  (interactive (list (read-directory-name "Repaired workspace directory: ")))
  (let* ((new-dir (expand-file-name directory))
         (config-file (expand-file-name agentsmith-workspace--config-file new-dir)))
    (unless (file-readable-p config-file)
      (user-error "No agentsmith config found in: %s" new-dir))
    (let* ((ws (agentsmith-workspace-load new-dir))
           (old-dir (agentsmith-workspace-directory ws))
           (issues (agentsmith-workspace--diagnose ws new-dir))
           (dir-mismatch (not (agentsmith-workspace--dir= old-dir new-dir))))
      (if (null issues)
          (progn
            (agentsmith-workspace-register new-dir)
            (agentsmith-workspace--refresh-buffer ws)
            (message "Workspace %s: no issues found"
                     (agentsmith-workspace-name ws))
            ws)
        (when dir-mismatch
          (setf (agentsmith-workspace-directory ws) new-dir))
        ;; Rewrite :path only for worktrees that look broken.
        ;; Build an alist of worktree-name → doctor issues for the VCS
        ;; repair pass to consult.
        (let (wt-issue-alist)
          (dolist (issue issues)
            (when (eq (plist-get issue :type) 'worktree)
              (let* ((wt-name (plist-get issue :name))
                     (wt-issues (plist-get issue :issues))
                     (wt (cl-find wt-name (agentsmith-workspace-worktrees ws)
                                  :key #'agentsmith-worktree-name
                                  :test #'string=)))
                (when wt
                  (push (cons wt-name wt-issues) wt-issue-alist)
                  (when (agentsmith-workspace--worktree-needs-rewrite-p wt-issues)
                    (let ((basename (file-name-nondirectory
                                     (directory-file-name
                                      (agentsmith-worktree-path wt)))))
                      (setf (agentsmith-worktree-path wt)
                            (expand-file-name basename new-dir))))))))
          ;; VCS repair pass.  Skip worktrees whose source-repo is
          ;; missing (repair would fail on the missing path anyway).
          (let (unfixable)
            (dolist (wt (agentsmith-workspace-worktrees ws))
              (when-let* ((vcs (agentsmith-worktree-vcs wt))
                          (wt-doctor (cdr (assoc (agentsmith-worktree-name wt)
                                                 wt-issue-alist))))
                (if (agentsmith-workspace--worktree-has-issue-p
                     'source-repo-missing wt-doctor)
                    (push (cons (agentsmith-worktree-name wt)
                                (format "source repo missing: %s"
                                        (agentsmith-worktree-source-repo wt)))
                          unfixable)
                  (condition-case err
                      (agentsmith-worktree-repair
                       vcs
                       (agentsmith-worktree-path wt)
                       (agentsmith-worktree-source-repo wt))
                    (error (push (cons (agentsmith-worktree-name wt)
                                       (error-message-string err))
                                 unfixable))))))
            (agentsmith-workspace-save ws)
            (agentsmith-workspace-register new-dir)
            (when dir-mismatch
              (agentsmith-workspace-deregister old-dir))
            (when (fboundp 'projectile-add-known-project)
              (projectile-add-known-project new-dir))
            (agentsmith-workspace--refresh-buffer ws)
            ;; Re-diagnose to verify the outcome.
            (let ((remaining (agentsmith-workspace--diagnose ws new-dir)))
              (cond
               (unfixable
                (message "Repaired workspace %s; %d issue(s) remain: %s"
                         (agentsmith-workspace-name ws)
                         (length unfixable)
                         (mapconcat (lambda (c) (format "%s (%s)" (car c) (cdr c)))
                                    unfixable "; ")))
               (remaining
                (message "Repaired workspace %s; %d issue(s) still detected"
                         (agentsmith-workspace-name ws)
                         (length remaining)))
               (t
                (message "Repaired workspace: %s"
                         (agentsmith-workspace-name ws)))))
            ws))))))

(defun agentsmith-workspace-import (directory &optional name)
  "Import an existing directory as an agentsmith workspace.
If DIRECTORY already has an .agentsmith.el config, re-registers it.
If the config's stored `:directory' differs from DIRECTORY (because
the workspace was moved on disk), delegates to
`agentsmith-workspace-repair' to rewrite paths and repair VCS state.
Otherwise scans for git/jj repos in subdirectories and creates the
config.  NAME is only used for the fresh-scan case; when a config
already exists the persisted name is kept.  Imported workspaces get
metadata (:imported t)."
  (interactive
   (let* ((dir (read-directory-name "Import workspace directory: "))
          (config-file (expand-file-name agentsmith-workspace--config-file dir))
          (name (unless (file-readable-p config-file)
                  (read-string "Workspace name: "
                               (file-name-nondirectory
                                (directory-file-name dir))))))
     (list dir name)))
  (let* ((dir (expand-file-name directory))
         (config-file (expand-file-name agentsmith-workspace--config-file dir)))
    (if (file-readable-p config-file)
        (let* ((ws-peek (agentsmith-workspace-load dir))
               (stored-dir (agentsmith-workspace-directory ws-peek)))
          (if (agentsmith-workspace--dir= stored-dir dir)
              ;; Re-register existing config as-is.
              (let ((ws ws-peek))
                (agentsmith-workspace-register dir)
                (when (fboundp 'projectile-add-known-project)
                  (projectile-add-known-project dir))
                (agentsmith-workspace--refresh-buffer ws)
                (message "Re-registered workspace: %s"
                         (agentsmith-workspace-name ws))
                ws)
            ;; Directory mismatch -- workspace was moved.  Delegate.
            (agentsmith-workspace-repair dir)))
      ;; Scan subdirectories for repos
      (let ((worktrees nil)
            (name (or name
                      (read-string "Workspace name: "
                                   (file-name-nondirectory
                                    (directory-file-name dir))))))
        (dolist (subdir (directory-files dir t "\\`[^.]"))
          (when (file-directory-p subdir)
            (when-let* ((vcs (agentsmith-worktree-detect-vcs subdir)))
              (let ((branch (condition-case nil
                                (agentsmith-worktree-branch-info vcs subdir)
                              (error nil))))
                (push (make-agentsmith-worktree
                       :name (file-name-nondirectory subdir)
                       :path (expand-file-name subdir)
                       :source-repo nil
                       :vcs vcs
                       :branch branch)
                      worktrees)))))
        (let ((ws (make-agentsmith-workspace
                   :name name
                   :directory dir
                   :default-agent-backend 'claude-code-ide
                   :worktrees (nreverse worktrees)
                   :metadata '(:imported t))))
          (agentsmith-workspace-save ws)
          (agentsmith-workspace-register dir)
          (when (fboundp 'projectile-add-known-project)
            (projectile-add-known-project dir))
          (agentsmith-workspace--refresh-buffer ws)
          (message "Imported workspace: %s (%d repos found)"
                   name (length worktrees))
          ws)))))

(defun agentsmith-workspace-open-plans (workspace)
  "Open the plans directory for WORKSPACE in dired."
  (let ((plans-dir (expand-file-name "plans/"
                                     (agentsmith-workspace-directory workspace))))
    (unless (file-directory-p plans-dir)
      (make-directory plans-dir t))
    (dired plans-dir)))

(defcustom agentsmith-scratch-buffer-mode #'org-mode
  "Major mode function for scratch buffers.
Called once when a scratch buffer is first created."
  :type 'function
  :group 'agentsmith-workspace)

(defun agentsmith-workspace-open-scratch (workspace)
  "Open or switch to an ephemeral scratch buffer for WORKSPACE.
The buffer is named *agentsmith-scratch: <name>* and uses the
major mode specified by `agentsmith-scratch-buffer-mode'."
  (let* ((name (agentsmith-workspace-name workspace))
         (buf-name (format "*agentsmith-scratch: %s*" name))
         (buf (get-buffer buf-name)))
    (unless buf
      (setq buf (get-buffer-create buf-name))
      (with-current-buffer buf
        (funcall agentsmith-scratch-buffer-mode)
        (setq-local default-directory
                    (file-name-as-directory
                     (agentsmith-workspace-directory workspace)))))
    (pop-to-buffer buf)))

(defun agentsmith-workspace-create-plan (workspace name)
  "Create a new plan file NAME.org in WORKSPACE's plans directory.
Signals an error if the file already exists."
  (let* ((plans-dir (expand-file-name "plans/"
                                      (agentsmith-workspace-directory workspace)))
         (file (expand-file-name (concat name ".org") plans-dir)))
    (unless (file-directory-p plans-dir)
      (make-directory plans-dir t))
    (when (file-exists-p file)
      (user-error "Plan file already exists: %s" file))
    (find-file file)))

(defun agentsmith-workspace-find-plan (workspace)
  "Select and open an existing plan file in WORKSPACE.
Uses `completing-read' over .org files in the plans directory."
  (let* ((plans-dir (expand-file-name "plans/"
                                      (agentsmith-workspace-directory workspace)))
         (files (and (file-directory-p plans-dir)
                     (directory-files plans-dir nil "\\.org\\'"))))
    (unless files
      (user-error "No plan files found in %s" plans-dir))
    (let ((choice (completing-read "Plan: " files nil t)))
      (find-file (expand-file-name choice plans-dir)))))

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
