;;; agentsmith-transient.el --- Transient menus for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, transient

;; This file is part of AgentSmith.

;;; Commentary:

;; Transient popup menus for AgentSmith operations.
;; All menus are extensible via `transient-append-suffix'.
;;
;; Example -- add a custom action to the dispatch menu:
;;   (transient-append-suffix 'agentsmith-dispatch "g"
;;     '("x" "My custom action" my-custom-command))

;;; Code:

(require 'transient)
(require 'agentsmith-workspace)
(require 'agentsmith-agent)

;; Forward declarations for buffer commands
(declare-function agentsmith-buffer-refresh "agentsmith-buffer" ())
(declare-function agentsmith--workspace-at-point "agentsmith-buffer" ())
(declare-function agentsmith--worktree-at-point "agentsmith-buffer" ())
(declare-function agentsmith-workspace-add-worktree-interactive "agentsmith-buffer"
                  (workspace))
(declare-function agentsmith-create-workspace "agentsmith" ())

;;; Dispatch Menu

;;;###autoload (autoload 'agentsmith-dispatch "agentsmith-transient" nil t)
(transient-define-prefix agentsmith-dispatch ()
  "AgentSmith dispatch menu."
  ["Workspace"
   ("c" "Create workspace"  agentsmith-create-workspace)
   ("o" "Open workspace"    agentsmith-workspace-open-interactive)
   ("k" "Delete workspace"  agentsmith-workspace-delete-interactive)]
  ["Worktree"
   ("w" "Add worktree"      agentsmith-dispatch--add-worktree)
   ("W" "Remove worktree"   agentsmith-dispatch--remove-worktree)]
  ["Agent"
   ("a" "Start agent"       agentsmith-dispatch--start-agent)
   ("s" "Stop agent"        agentsmith-dispatch--stop-agent)
   ("b" "Show agent buffer" agentsmith-dispatch--show-agent)]
  ["Buffer"
   ("g" "Refresh"           agentsmith-buffer-refresh)])

;;; Workspace Agent Menu

;;;###autoload (autoload 'agentsmith-transient-workspace-agent "agentsmith-transient" nil t)
(transient-define-prefix agentsmith-transient-workspace-agent ()
  "Agent actions for the workspace at point."
  :transient-suffix 'transient--do-return
  ["Workspace Agent"
   ("a" "Start agent"       agentsmith-transient--ws-start-agent)
   ("s" "Stop agent"        agentsmith-transient--ws-stop-agent)
   ("b" "Show agent buffer" agentsmith-transient--ws-show-agent)
   ("B" "Select backend"    agentsmith-transient--ws-select-backend)])

;;; Worktree Agent Menu

;;;###autoload (autoload 'agentsmith-transient-worktree-agent "agentsmith-transient" nil t)
(transient-define-prefix agentsmith-transient-worktree-agent ()
  "Agent actions for the worktree at point."
  :transient-suffix 'transient--do-return
  ["Worktree Agent"
   ("a" "Start agent"       agentsmith-transient--wt-start-agent)
   ("s" "Stop agent"        agentsmith-transient--wt-stop-agent)
   ("b" "Show agent buffer" agentsmith-transient--wt-show-agent)
   ("B" "Select backend"    agentsmith-transient--wt-select-backend)])

;;; Dispatch Helpers
;; These commands operate on whatever is at point (workspace or worktree).

(defun agentsmith-dispatch--add-worktree ()
  "Add a worktree to the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (agentsmith-workspace-add-worktree-interactive ws)
    (user-error "Place cursor on a workspace first")))

(defun agentsmith-dispatch--remove-worktree ()
  "Remove the worktree at point."
  (interactive)
  (if (fboundp 'agentsmith-worktree-remove-at-point)
      (call-interactively #'agentsmith-worktree-remove-at-point)
    (user-error "Place cursor on a worktree first")))

(defun agentsmith-dispatch--start-agent ()
  "Start an agent for the item at point (workspace or worktree)."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point)
    (let ((wt (agentsmith--worktree-at-point)))
      (agentsmith-agent-start-for-worktree wt)
      (agentsmith-buffer-refresh)
      (message "Started agent for worktree: %s" (agentsmith-worktree-name wt))))
   ((agentsmith--workspace-at-point)
    (let ((ws (agentsmith--workspace-at-point)))
      (agentsmith-agent-start-for-workspace ws)
      (agentsmith-buffer-refresh)
      (message "Started agent for workspace: %s" (agentsmith-workspace-name ws))))
   (t (user-error "Place cursor on a workspace or worktree"))))

(defun agentsmith-dispatch--stop-agent ()
  "Stop the agent for the item at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point)
    (let ((wt (agentsmith--worktree-at-point)))
      (if-let* ((session (agentsmith-worktree-agent-session wt)))
          (progn
            (agentsmith-agent-stop-session session)
            (agentsmith-buffer-refresh)
            (message "Stopped agent for worktree: %s"
                     (agentsmith-worktree-name wt)))
        (user-error "No agent running for this worktree"))))
   ((agentsmith--workspace-at-point)
    (let ((ws (agentsmith--workspace-at-point)))
      (if-let* ((session (agentsmith-workspace-agent-session ws)))
          (progn
            (agentsmith-agent-stop-session session)
            (agentsmith-buffer-refresh)
            (message "Stopped agent for workspace: %s"
                     (agentsmith-workspace-name ws)))
        (user-error "No agent running for this workspace"))))
   (t (user-error "Place cursor on a workspace or worktree"))))

(defun agentsmith-dispatch--show-agent ()
  "Show the agent buffer for the item at point."
  (interactive)
  (cond
   ((agentsmith--worktree-at-point)
    (let ((wt (agentsmith--worktree-at-point)))
      (if-let* ((session (agentsmith-worktree-agent-session wt)))
          (agentsmith-agent-show-buffer session)
        (user-error "No agent running for this worktree"))))
   ((agentsmith--workspace-at-point)
    (let ((ws (agentsmith--workspace-at-point)))
      (if-let* ((session (agentsmith-workspace-agent-session ws)))
          (agentsmith-agent-show-buffer session)
        (user-error "No agent running for this workspace"))))
   (t (user-error "Place cursor on a workspace or worktree"))))

;;; Workspace Agent Commands

(defun agentsmith-transient--ws-start-agent ()
  "Start the top-level agent for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (progn
        (agentsmith-agent-start-for-workspace ws)
        (agentsmith-buffer-refresh)
        (message "Started agent for workspace: %s"
                 (agentsmith-workspace-name ws)))
    (user-error "No workspace at point")))

(defun agentsmith-transient--ws-stop-agent ()
  "Stop the top-level agent for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (if-let* ((session (agentsmith-workspace-agent-session ws)))
          (progn
            (agentsmith-agent-stop-session session)
            (agentsmith-buffer-refresh)
            (message "Stopped agent for workspace: %s"
                     (agentsmith-workspace-name ws)))
        (user-error "No agent running for this workspace"))
    (user-error "No workspace at point")))

(defun agentsmith-transient--ws-show-agent ()
  "Show the agent buffer for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (if-let* ((session (agentsmith-workspace-agent-session ws)))
          (agentsmith-agent-show-buffer session)
        (user-error "No agent running for this workspace"))
    (user-error "No workspace at point")))

(defun agentsmith-transient--ws-select-backend ()
  "Change the default agent backend for the workspace at point."
  (interactive)
  (if-let* ((ws (agentsmith--workspace-at-point)))
      (let ((backend (agentsmith-agent--read-backend)))
        (setf (agentsmith-workspace-default-agent-backend ws) backend)
        (agentsmith-workspace-save ws)
        (message "Set backend to %s for workspace: %s"
                 backend (agentsmith-workspace-name ws)))
    (user-error "No workspace at point")))

;;; Worktree Agent Commands

(defun agentsmith-transient--wt-start-agent ()
  "Start an agent for the worktree at point."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (progn
        (agentsmith-agent-start-for-worktree wt)
        (agentsmith-buffer-refresh)
        (message "Started agent for worktree: %s"
                 (agentsmith-worktree-name wt)))
    (user-error "No worktree at point")))

(defun agentsmith-transient--wt-stop-agent ()
  "Stop the agent for the worktree at point."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (if-let* ((session (agentsmith-worktree-agent-session wt)))
          (progn
            (agentsmith-agent-stop-session session)
            (agentsmith-buffer-refresh)
            (message "Stopped agent for worktree: %s"
                     (agentsmith-worktree-name wt)))
        (user-error "No agent running for this worktree"))
    (user-error "No worktree at point")))

(defun agentsmith-transient--wt-show-agent ()
  "Show the agent buffer for the worktree at point."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (if-let* ((session (agentsmith-worktree-agent-session wt)))
          (agentsmith-agent-show-buffer session)
        (user-error "No agent running for this worktree"))
    (user-error "No worktree at point")))

(defun agentsmith-transient--wt-select-backend ()
  "Change the agent backend for the worktree at point.
Starts a new session with the selected backend."
  (interactive)
  (if-let* ((wt (agentsmith--worktree-at-point)))
      (let ((backend (agentsmith-agent--read-backend)))
        ;; Stop existing session if any
        (when-let* ((session (agentsmith-worktree-agent-session wt)))
          (agentsmith-agent-stop-session session))
        ;; Start new session with selected backend
        (agentsmith-agent-start-for-worktree wt backend)
        (agentsmith-buffer-refresh)
        (message "Started %s agent for worktree: %s"
                 backend (agentsmith-worktree-name wt)))
    (user-error "No worktree at point")))

(provide 'agentsmith-transient)
;;; agentsmith-transient.el ends here
