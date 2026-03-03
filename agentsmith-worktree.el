;;; agentsmith-worktree.el --- VCS worktree operations for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, vc

;; This file is part of AgentSmith.

;;; Commentary:

;; VCS detection and worktree/workspace operations for git and jujutsu.
;; Uses cl-defgeneric dispatched on VCS symbol so users can add support
;; for additional VCS systems.

;;; Code:

(require 'cl-lib)

;;; Customization

(defgroup agentsmith-worktree nil
  "VCS worktree settings for AgentSmith."
  :group 'agentsmith
  :prefix "agentsmith-worktree-")

(defcustom agentsmith-git-executable "git"
  "Path to the git executable."
  :type 'string
  :group 'agentsmith-worktree)

(defcustom agentsmith-jj-executable "jj"
  "Path to the jj (jujutsu) executable."
  :type 'string
  :group 'agentsmith-worktree)

(defcustom agentsmith-worktree-vcs-mode-functions
  '((git . magit-status))
  "Alist mapping VCS symbols to functions that open a VCS interface.
Each function is called with no arguments and `default-directory'
already bound to the worktree path.
Git defaults to `magit-status'.  Jujutsu has no default; users must
configure it, e.g.: (jj . my-jj-status-function)"
  :type '(alist :key-type symbol :value-type function)
  :group 'agentsmith-worktree)

;;; VCS Detection

(defun agentsmith-worktree-detect-vcs (repo-path)
  "Detect whether REPO-PATH uses git or jj.
Returns \\='jj if .jj directory exists, \\='git if .git exists, nil otherwise.
Checks .jj first since jj repos also contain .git."
  (let ((path (expand-file-name repo-path)))
    (cond
     ((file-directory-p (expand-file-name ".jj" path)) 'jj)
     ((or (file-directory-p (expand-file-name ".git" path))
          (file-regular-p (expand-file-name ".git" path)))
      'git)
     (t nil))))

;;; Generic Protocol

(cl-defgeneric agentsmith-worktree-create (vcs repo-path target-dir name &optional branch)
  "Create a worktree from REPO-PATH at TARGET-DIR with NAME.
VCS is a symbol (\\='git or \\='jj) determining the backend.
BRANCH is an optional branch/bookmark name (defaults to NAME for git).")

(cl-defgeneric agentsmith-worktree-remove (vcs worktree-path &optional repo-path)
  "Remove the worktree at WORKTREE-PATH.
VCS is a symbol determining the backend.
REPO-PATH is the original repo path (needed for some VCS operations).")

(cl-defgeneric agentsmith-worktree-branch-info (vcs worktree-path)
  "Return a string describing the current branch/bookmark at WORKTREE-PATH.
VCS is a symbol determining the backend.")

;;; Git Implementation

(cl-defmethod agentsmith-worktree-create ((_vcs (eql git)) repo-path target-dir name &optional branch)
  "Create a git worktree from REPO-PATH at TARGET-DIR.
Creates a new branch named BRANCH (or NAME if not specified)."
  (let* ((branch (or branch name))
         (default-directory (expand-file-name repo-path))
         (target (expand-file-name target-dir)))
    (let ((exit-code
           (call-process agentsmith-git-executable nil nil nil
                         "worktree" "add" "-b" branch target)))
      (unless (zerop exit-code)
        ;; Branch might already exist, try without -b
        (let ((exit-code-2
               (call-process agentsmith-git-executable nil nil nil
                             "worktree" "add" target branch)))
          (unless (zerop exit-code-2)
            (error "Failed to create git worktree at %s" target))))
      target)))

(cl-defmethod agentsmith-worktree-remove ((_vcs (eql git)) worktree-path &optional repo-path)
  "Remove a git worktree at WORKTREE-PATH."
  (let ((default-directory (expand-file-name (or repo-path worktree-path))))
    (let ((exit-code
           (call-process agentsmith-git-executable nil nil nil
                         "worktree" "remove" (expand-file-name worktree-path))))
      (unless (zerop exit-code)
        (error "Failed to remove git worktree at %s" worktree-path)))))

(cl-defmethod agentsmith-worktree-branch-info ((_vcs (eql git)) worktree-path)
  "Return the current branch name for git worktree at WORKTREE-PATH."
  (let ((default-directory (expand-file-name worktree-path)))
    (string-trim
     (with-output-to-string
       (with-current-buffer standard-output
         (call-process agentsmith-git-executable nil t nil
                       "rev-parse" "--abbrev-ref" "HEAD"))))))

;;; Jujutsu Implementation

(cl-defmethod agentsmith-worktree-create ((_vcs (eql jj)) repo-path target-dir name &optional _branch)
  "Create a jj workspace from REPO-PATH at TARGET-DIR with NAME."
  (let ((default-directory (expand-file-name repo-path))
        (target (expand-file-name target-dir)))
    (let ((exit-code
           (call-process agentsmith-jj-executable nil nil nil
                         "workspace" "add" target "--name" name)))
      (unless (zerop exit-code)
        (error "Failed to create jj workspace at %s" target))
      target)))

(cl-defmethod agentsmith-worktree-remove ((_vcs (eql jj)) worktree-path &optional repo-path)
  "Remove a jj workspace.
WORKTREE-PATH identifies the workspace. REPO-PATH is the main repo."
  (let* ((default-directory (expand-file-name (or repo-path worktree-path)))
         (name (file-name-nondirectory (directory-file-name worktree-path))))
    (let ((exit-code
           (call-process agentsmith-jj-executable nil nil nil
                         "workspace" "forget" name)))
      (unless (zerop exit-code)
        (error "Failed to forget jj workspace: %s" name)))))

(cl-defmethod agentsmith-worktree-branch-info ((_vcs (eql jj)) worktree-path)
  "Return the current bookmark info for jj workspace at WORKTREE-PATH."
  (let ((default-directory (expand-file-name worktree-path)))
    (string-trim
     (with-output-to-string
       (with-current-buffer standard-output
         (call-process agentsmith-jj-executable nil t nil
                       "log" "-r" "@" "--no-graph" "-T" "bookmarks"))))))

;;; Utility

(defun agentsmith-worktree-exists-p (path)
  "Return non-nil if PATH looks like an existing worktree directory."
  (and (file-directory-p path)
       (or (agentsmith-worktree-detect-vcs path)
           ;; Git worktrees have a .git file (not directory) pointing to main repo
           (file-regular-p (expand-file-name ".git" path)))))

;;; VCS Interface

(declare-function projectile-add-known-project "projectile" (project-root))

(defun agentsmith--open-vcs-for-worktree (worktree)
  "Open the VCS interface for WORKTREE."
  (let ((vcs (agentsmith-worktree-vcs worktree)))
    (unless vcs
      (user-error "No VCS detected for worktree: %s"
                  (agentsmith-worktree-name worktree)))
    (agentsmith--open-vcs-for-directory
     (agentsmith-worktree-path worktree) vcs)))

(defun agentsmith--open-vcs-for-directory (directory &optional vcs)
  "Open the VCS interface for DIRECTORY.
VCS is a symbol; if nil, autodetects."
  (let* ((dir (expand-file-name directory))
         (vcs (or vcs (agentsmith-worktree-detect-vcs dir)))
         (fn (alist-get vcs agentsmith-worktree-vcs-mode-functions)))
    (unless vcs
      (user-error "No VCS repository found at: %s" dir))
    (unless fn
      (user-error "No VCS mode configured for `%s'.  \
Set `agentsmith-worktree-vcs-mode-functions'" vcs))
    (when (fboundp 'projectile-add-known-project)
      (projectile-add-known-project (file-name-as-directory dir)))
    (let ((default-directory (file-name-as-directory dir)))
      (funcall fn))))

(provide 'agentsmith-worktree)
;;; agentsmith-worktree.el ends here
