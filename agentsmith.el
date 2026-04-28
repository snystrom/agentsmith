;;; agentsmith.el --- Manage coding agent workflows across projects  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0.0") (transient "0.5.0"))
;; Keywords: tools, processes, vc
;; URL: https://github.com/snystrom/agentsmith

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; AgentSmith is an Emacs major mode for managing coding agent workflows
;; across multiple projects and repositories.
;;
;; Core concepts:
;; - Workspace: a directory bundling git/jj worktrees from multiple repos
;; - Worktree: a git worktree or jj workspace within an agentsmith workspace
;; - Agent session: a running coding agent (e.g., claude-code-ide) attached
;;   to a workspace or worktree
;;
;; The main buffer displays a hierarchical view:
;;   Workspace
;;     Worktree (with agent status)
;;     Worktree (with agent status)
;;
;; Features:
;; - Create workspaces that bundle worktrees from multiple repos
;; - Autodetect git vs jujutsu and use appropriate worktree commands
;; - Pluggable agent backend protocol (ships with claude-code-ide)
;; - Section-based navigation with magit-section
;; - Transient popup menus for all operations
;; - Fully extensible keybindings, agent backends, and behaviors
;;
;; Usage:
;;   M-x agentsmith          -- Open the AgentSmith status buffer
;;   M-x agentsmith-create-workspace -- Create a new workspace
;;
;; Extensibility:
;; - Register agent backends via `agentsmith-agent-backends'
;; - Customize open behavior via `agentsmith-worktree-open-function'
;; - Override keybindings via `agentsmith-mode-map' and section maps
;; - Extend transient menus via `transient-append-suffix'
;; - Hook into workspace creation via `agentsmith-after-workspace-create-hook'

;;; Code:

(require 'agentsmith-workspace)
(require 'agentsmith-worktree)
(require 'agentsmith-agent)
(require 'agentsmith-kanban)
(require 'agentsmith-buffer)
(require 'agentsmith-transient)

;;; Customization Group (top-level)

(defgroup agentsmith nil
  "Manage coding agent workflows across projects."
  :group 'tools
  :prefix "agentsmith-")

;;; Buffer Name

(defcustom agentsmith-buffer-name "*agentsmith*"
  "Name of the AgentSmith status buffer."
  :type 'string
  :group 'agentsmith)

;;; Entry Points

;;;###autoload
(defun agentsmith ()
  "Open the AgentSmith status buffer.
Creates the buffer if it doesn't exist, loads all registered workspaces,
and displays the hierarchical workspace/worktree view."
  (interactive)
  (let ((buf (get-buffer-create agentsmith-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'agentsmith-mode)
        (agentsmith-mode))
      (setq agentsmith--workspaces (agentsmith-workspace-load-all))
      (agentsmith-buffer-refresh))
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun agentsmith-create-workspace ()
  "Interactively create a new workspace and refresh the buffer."
  (interactive)
  (let ((ws (call-interactively #'agentsmith-workspace-create-interactive)))
    (when ws
      ;; If we're in the agentsmith buffer, add and refresh
      (when-let* ((buf (get-buffer agentsmith-buffer-name)))
        (with-current-buffer buf
          (push ws agentsmith--workspaces)
          (agentsmith-buffer-refresh)))
      ;; Open the agentsmith buffer if not already open
      (unless (get-buffer-window agentsmith-buffer-name)
        (agentsmith)))))

;;; Global Agent Commands

;;;###autoload
(defun agentsmith-worktree-open-agent ()
  "Open the agent for the worktree containing the current directory.
Cascades: show existing session → autodetect → start new agent.
Can be called from any buffer."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (match (agentsmith-worktree-find-by-directory dir)))
    (unless match
      (user-error "Current directory is not inside a registered worktree"))
    (agentsmith-agent-popup-for-worktree (cdr match))))

;;;###autoload
(defun agentsmith-workspace-open-agent ()
  "Open the agent for the workspace containing the current directory.
Shows existing session or starts a new one.
Can be called from any buffer.
Tries worktree lookup first (more specific) to derive the workspace,
falling back to direct workspace lookup."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (agentsmith-agent-popup-for-workspace ws)))

;;;###autoload
(defun agentsmith-worktree-toggle-agent ()
  "Toggle the agent for the worktree containing the current directory.
If the agent buffer is visible, hide it.  Otherwise show or start it.
When the current directory is not inside a registered worktree, calls
`agentsmith-agent-toggle-outside-workspace' with the directory."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (match (agentsmith-worktree-find-by-directory dir)))
    (if match
        (let ((result (agentsmith-agent-toggle-buffer
                       (agentsmith-worktree-path (cdr match)))))
          (when (or result
                    (not (agentsmith-agent-detect-buffer-for-dir
                          (agentsmith-worktree-path (cdr match)))))
            (agentsmith-agent-popup-for-worktree (cdr match))))
      (funcall agentsmith-agent-toggle-outside-workspace dir))))

;;;###autoload
(defun agentsmith-workspace-toggle-agent ()
  "Toggle the agent for the workspace containing the current directory.
If the agent buffer is visible, hide it.  Otherwise show or start it."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((result (agentsmith-agent-toggle-buffer
                   (agentsmith-workspace-directory ws))))
      (when (or result
                (not (agentsmith-agent-detect-buffer-for-dir
                      (agentsmith-workspace-directory ws))))
        (agentsmith-agent-popup-for-workspace ws)))))

(defun agentsmith--select-visible-agent-window (directory)
  "Select the window displaying an agent buffer for DIRECTORY, if any."
  (when-let* ((buf (agentsmith-agent-detect-buffer-for-dir
                    (expand-file-name directory)))
              (win (get-buffer-window buf t)))
    (select-window win)))

;;;###autoload
(defun agentsmith-worktree-toggle-agent-and-go ()
  "Like `agentsmith-worktree-toggle-agent' but select the agent window."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (match (agentsmith-worktree-find-by-directory dir)))
    (if match
        (progn
          (agentsmith-worktree-toggle-agent)
          (agentsmith--select-visible-agent-window
           (agentsmith-worktree-path (cdr match))))
      (funcall agentsmith-agent-toggle-outside-workspace-and-go dir))))

;;;###autoload
(defun agentsmith-workspace-toggle-agent-and-go ()
  "Like `agentsmith-workspace-toggle-agent' but select the agent window."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (agentsmith-workspace-toggle-agent)
    (agentsmith--select-visible-agent-window
     (agentsmith-workspace-directory ws))))

;;;###autoload
(defun agentsmith-workspace-select-worktree-agent ()
  "Interactively select a worktree in the current workspace and open its agent.
Lists all worktrees in the workspace containing `default-directory',
then opens the agent for the selected worktree using the cascade logic
\(show existing → autodetect → start new)."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((worktrees (agentsmith-workspace-worktrees ws)))
      (unless worktrees
        (user-error "Workspace '%s' has no worktrees"
                    (agentsmith-workspace-name ws)))
      (let* ((candidates
              (mapcar (lambda (wt)
                        (cons (format "%s  %s  %s"
                                      (agentsmith-worktree-name wt)
                                      (or (agentsmith-worktree-branch wt) "")
                                      (abbreviate-file-name
                                       (agentsmith-worktree-path wt)))
                              wt))
                      worktrees))
             (choice (completing-read
                      (format "Worktree [%s]: " (agentsmith-workspace-name ws))
                      candidates nil t))
             (wt (cdr (assoc choice candidates))))
        (agentsmith-agent-popup-for-worktree wt)))))

;;;###autoload
(defun agentsmith-workspace-list ()
  "Select a registered workspace and switch to it as a project.
Uses `completing-read' to list all registered workspaces, then
switches to the selected one via `projectile-switch-project-action'."
  (interactive)
  (let ((all-ws (agentsmith-workspace-load-all)))
    (unless all-ws
      (user-error "No registered workspaces found"))
    (let* ((candidates
            (mapcar (lambda (ws)
                      (cons (format "%s  %s"
                                    (agentsmith-workspace-name ws)
                                    (abbreviate-file-name
                                     (agentsmith-workspace-directory ws)))
                            ws))
                    all-ws))
           (choice (completing-read "Workspace: " candidates nil t))
           (ws (cdr (assoc choice candidates))))
      (agentsmith--switch-to-project (agentsmith-workspace-directory ws)))))

;;;###autoload
(defun agentsmith-worktree-find-file ()
  "Select a worktree in the current workspace and open its file finder."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((worktrees (agentsmith-workspace-worktrees ws)))
      (unless worktrees
        (user-error "Workspace '%s' has no worktrees"
                    (agentsmith-workspace-name ws)))
      (let* ((candidates
              (mapcar (lambda (wt)
                        (cons (format "%s  %s"
                                      (agentsmith-worktree-name wt)
                                      (abbreviate-file-name
                                       (agentsmith-worktree-path wt)))
                              wt))
                      worktrees))
             (choice (completing-read
                      (format "Worktree [%s]: " (agentsmith-workspace-name ws))
                      candidates nil t))
             (wt (cdr (assoc choice candidates))))
        (agentsmith--find-file-in-worktree ws wt)))))

;;;###autoload
(defun agentsmith-workspace-switch-buffer ()
  "Switch to a buffer belonging to the current workspace.
Calls `projectile-switch-to-buffer' scoped to the workspace directory."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((projectile-project-root
           (file-name-as-directory (agentsmith-workspace-directory ws))))
      (projectile-switch-to-buffer))))

;;; Plans & Scratch

;;;###autoload
(defun agentsmith-open-scratch ()
  "Open a scratch buffer for the workspace containing `default-directory'."
  (interactive)
  (let ((ws (agentsmith-workspace-find-by-directory default-directory)))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (agentsmith-workspace-open-scratch ws)))

;;;###autoload
(defun agentsmith-create-plan ()
  "Create a new plan file in the workspace containing `default-directory'."
  (interactive)
  (let ((ws (agentsmith-workspace-find-by-directory default-directory)))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((name (read-string "Plan name: ")))
      (agentsmith-workspace-create-plan ws name))))

;;;###autoload
(defun agentsmith-find-plan ()
  "Find an existing plan file in the workspace containing `default-directory'."
  (interactive)
  (let ((ws (agentsmith-workspace-find-by-directory default-directory)))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (agentsmith-workspace-find-plan ws)))

;;; VCS Interface Commands

;;;###autoload
(defun agentsmith-worktree-open-vcs ()
  "Open the VCS interface for the worktree at `default-directory'.
Can be called from any buffer. Falls back to opening VCS for
the directory directly if not inside a registered worktree."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (match (agentsmith-worktree-find-by-directory dir)))
    (if match
        (agentsmith--open-vcs-for-worktree (cdr match))
      (agentsmith--open-vcs-for-directory dir))))

;;;###autoload
(defun agentsmith-workspace-select-worktree-vcs ()
  "Select a worktree in the current workspace and open its VCS interface.
Uses `completing-read' to list all worktrees, then opens the VCS
mode for the selected worktree.  Can be called from any buffer."
  (interactive)
  (let* ((dir (expand-file-name default-directory))
         (ws (or (car (agentsmith-worktree-find-by-directory dir))
                 (agentsmith-workspace-find-by-directory dir))))
    (unless ws
      (user-error "Current directory is not inside a registered workspace"))
    (let ((worktrees (agentsmith-workspace-worktrees ws)))
      (unless worktrees
        (user-error "Workspace '%s' has no worktrees"
                    (agentsmith-workspace-name ws)))
      (let* ((candidates
              (mapcar (lambda (wt)
                        (cons (format "%s  [%s]  %s"
                                      (agentsmith-worktree-name wt)
                                      (or (agentsmith-worktree-vcs wt) "?")
                                      (abbreviate-file-name
                                       (agentsmith-worktree-path wt)))
                              wt))
                      worktrees))
             (choice (completing-read
                      (format "Open VCS [%s]: "
                              (agentsmith-workspace-name ws))
                      candidates nil t))
             (wt (cdr (assoc choice candidates))))
        (agentsmith--open-vcs-for-worktree wt)))))

(provide 'agentsmith)
;;; agentsmith.el ends here
