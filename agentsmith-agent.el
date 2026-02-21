;;; agentsmith-agent.el --- Agent backend abstraction for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, processes

;; This file is part of AgentSmith.

;;; Commentary:

;; Pluggable agent backend protocol using cl-defgeneric.
;; Users register new backends by:
;;   1. Adding to `agentsmith-agent-backends'
;;   2. Defining cl-defmethod implementations for the four generic functions
;;
;; Ships with a `claude-code-ide' backend.

;;; Code:

(require 'cl-lib)
(require 'agentsmith-workspace)

;;; Customization

(defgroup agentsmith-agent nil
  "Agent backend settings for AgentSmith."
  :group 'agentsmith
  :prefix "agentsmith-agent-")

(defcustom agentsmith-default-agent-backend 'claude-code-ide
  "Default agent backend for new workspaces and worktrees."
  :type 'symbol
  :group 'agentsmith-agent)

(defcustom agentsmith-agent-popup-function #'agentsmith-agent-popup-default
  "Function to display an agent buffer as a popup.
Called with one argument: the buffer to display.
Users can customize this to control window placement and sizing."
  :type 'function
  :group 'agentsmith-agent)

;;; Backend Registry

(defvar agentsmith-agent-backends
  '((claude-code-ide . "Claude Code IDE"))
  "Alist of registered agent backends.
Each entry is (SYMBOL . DESCRIPTION).
Users and packages add entries here to make backends available.

To register a new backend:
  (push \\='(my-backend . \"My Backend\") agentsmith-agent-backends)
Then define cl-defmethod implementations for:
  `agentsmith-agent-start', `agentsmith-agent-stop',
  `agentsmith-agent-status', `agentsmith-agent-get-buffer'")

;;; Generic Protocol

(cl-defgeneric agentsmith-agent-start (backend session)
  "Start an agent process for SESSION using BACKEND.
BACKEND is a symbol identifying the backend.
SESSION is an `agentsmith-agent-session' struct.
Implementations must set the session's `buffer' and `status' slots.
Returns the session.")

(cl-defgeneric agentsmith-agent-stop (backend session)
  "Stop the agent process for SESSION using BACKEND.
Should kill or disconnect the process and set status to \\='stopped.")

(cl-defgeneric agentsmith-agent-status (backend session)
  "Return the current status symbol for SESSION.
Returns one of: \\='stopped, \\='ready, or \\='thinking.
BACKEND is a symbol identifying the backend.")

(cl-defgeneric agentsmith-agent-get-buffer (backend session)
  "Return the buffer displaying the agent for SESSION.
BACKEND is a symbol identifying the backend.
Used to pop up the agent view.")

;;; Default Popup Display

(defun agentsmith-agent-popup-default (buffer)
  "Display agent BUFFER in a side window."
  (display-buffer buffer
                  '((display-buffer-in-side-window)
                    (side . right)
                    (window-width . 0.4))))

;;; Convenience Functions

(defun agentsmith-agent--read-backend ()
  "Prompt user to select an agent backend. Returns the backend symbol."
  (let* ((choices (mapcar (lambda (entry)
                            (cons (format "%s (%s)" (car entry) (cdr entry))
                                  (car entry)))
                          agentsmith-agent-backends))
         (choice (completing-read "Agent backend: " choices nil t)))
    (cdr (assoc choice choices))))

(defun agentsmith-agent-start-for-worktree (worktree &optional backend)
  "Start an agent session for WORKTREE.
BACKEND defaults to `agentsmith-default-agent-backend'.
Sets the agent-session slot on WORKTREE. Returns the session."
  (let* ((backend (or backend agentsmith-default-agent-backend))
         (session (make-agentsmith-agent-session
                   :backend backend
                   :status 'stopped
                   :worktree-path (agentsmith-worktree-path worktree))))
    (agentsmith-agent-start backend session)
    (setf (agentsmith-worktree-agent-session worktree) session)
    session))

(defun agentsmith-agent-start-for-workspace (workspace &optional backend)
  "Start a top-level agent session for WORKSPACE.
BACKEND defaults to the workspace's `default-agent-backend'.
Sets the agent-session slot on WORKSPACE. Returns the session."
  (let* ((backend (or backend
                      (agentsmith-workspace-default-agent-backend workspace)))
         (session (make-agentsmith-agent-session
                   :backend backend
                   :status 'stopped
                   :worktree-path (agentsmith-workspace-directory workspace))))
    (agentsmith-agent-start backend session)
    (setf (agentsmith-workspace-agent-session workspace) session)
    session))

(defun agentsmith-agent-stop-session (session)
  "Stop the agent SESSION if it is running."
  (when (and session
             (not (eq (agentsmith-agent-session-status session) 'stopped)))
    (agentsmith-agent-stop (agentsmith-agent-session-backend session) session)))

(defun agentsmith-agent-show-buffer (session)
  "Display the agent buffer for SESSION using `agentsmith-agent-popup-function'."
  (when-let* ((buf (agentsmith-agent-get-buffer
                    (agentsmith-agent-session-backend session) session)))
    (if (buffer-live-p buf)
        (funcall agentsmith-agent-popup-function buf)
      (user-error "Agent buffer no longer exists"))))

;;; Claude Code IDE Backend

;; Declare external functions to avoid byte-compile warnings
(declare-function claude-code-ide "claude-code-ide" ())
(declare-function claude-code-ide-stop "claude-code-ide" ())
(declare-function claude-code-ide-switch-to-buffer "claude-code-ide" ())

(cl-defmethod agentsmith-agent-start ((_backend (eql claude-code-ide)) session)
  "Start a claude-code-ide session.
Uses `default-directory' to determine the project context."
  (let ((default-directory (agentsmith-agent-session-worktree-path session)))
    ;; claude-code-ide uses default-directory to determine the project
    (claude-code-ide)
    ;; Try to find the buffer it created
    ;; claude-code-ide names buffers based on the project directory
    (let ((buf (seq-find
                (lambda (b)
                  (and (string-match-p "\\*claude-code" (buffer-name b))
                       (with-current-buffer b
                         (string= (expand-file-name default-directory)
                                  (expand-file-name
                                   (agentsmith-agent-session-worktree-path session))))))
                (buffer-list))))
      (setf (agentsmith-agent-session-buffer session) buf)
      (setf (agentsmith-agent-session-status session) 'ready)))
  session)

(cl-defmethod agentsmith-agent-stop ((_backend (eql claude-code-ide)) session)
  "Stop a claude-code-ide session."
  (let ((default-directory (agentsmith-agent-session-worktree-path session)))
    (condition-case nil
        (claude-code-ide-stop)
      (error nil)))
  (setf (agentsmith-agent-session-status session) 'stopped)
  (setf (agentsmith-agent-session-buffer session) nil))

(cl-defmethod agentsmith-agent-status ((_backend (eql claude-code-ide)) session)
  "Check claude-code-ide session status.
For v1, checks if the buffer and its process are alive."
  (let ((buf (agentsmith-agent-session-buffer session)))
    (if (and buf (buffer-live-p buf))
        (if (get-buffer-process buf)
            'ready
          'stopped)
      'stopped)))

(cl-defmethod agentsmith-agent-get-buffer ((_backend (eql claude-code-ide)) session)
  "Return the claude-code-ide buffer for SESSION."
  (agentsmith-agent-session-buffer session))

(provide 'agentsmith-agent)
;;; agentsmith-agent.el ends here
