;;; agentsmith-agent.el --- Agent backend abstraction for AgentSmith  -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: Spencer Nystrom
;; Keywords: tools, processes

;; This file is part of AgentSmith.

;;; Commentary:

;; Config-based agent backend registry.  Each backend is an entry in
;; `agentsmith-agent-configs' mapping operation symbols to functions.
;;
;; To register a new backend:
;;
;;   (push '(my-backend
;;           (name          . "My Agent")
;;           (start         . my-agent-start)     ; fn(directory)
;;           (stop          . my-agent-stop)       ; fn(directory)
;;           (open          . my-agent-open)       ; fn(directory)
;;           (detect-buffer . my-agent-find-buf)   ; fn(directory) -> buffer|nil
;;           (status        . my-agent-status))    ; fn(directory) -> symbol
;;         agentsmith-agent-configs)
;;
;; All operation functions take a single DIRECTORY argument.
;; Ships with a `claude-code-ide' config.

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

;;; Config Registry

(defvar agentsmith-agent-configs
  `((claude-code-ide
     (name          . "Claude Code IDE")
     (start         . agentsmith--claude-code-ide-start)
     (stop          . agentsmith--claude-code-ide-stop)
     (open          . agentsmith--claude-code-ide-start)  ; same fn — it toggles
     (detect-buffer . agentsmith--claude-code-ide-detect-buffer)
     (status        . agentsmith--claude-code-ide-status)))
  "Alist of agent backend configurations.
Each entry is (BACKEND-SYMBOL . CONFIG-ALIST).

CONFIG-ALIST maps operation symbols to functions.  All operation
functions take a single DIRECTORY argument (the worktree or workspace
path).  This keeps configs decoupled from agentsmith internals.

Required operations:
  name          - string, display name for the backend
  start         - fn(directory), start the agent in DIRECTORY
  stop          - fn(directory), stop the agent in DIRECTORY
  open          - fn(directory), open/focus agent for DIRECTORY
  detect-buffer - fn(directory) -> buffer-or-nil, find existing agent buffer
  status        - fn(directory) -> symbol, one of \\='stopped \\='ready \\='thinking")

;;; Config Lookup

(defun agentsmith-agent--get-config (backend)
  "Return the config alist for BACKEND, or error if not found."
  (or (alist-get backend agentsmith-agent-configs)
      (error "Unknown agent backend: %s" backend)))

(defun agentsmith-agent--call (backend op directory)
  "Call operation OP for BACKEND in DIRECTORY.
OP is a symbol (start, stop, open, detect-buffer, status).
DIRECTORY is the working directory for the operation."
  (let* ((config (agentsmith-agent--get-config backend))
         (fn (alist-get op config)))
    (unless fn
      (error "Backend %s does not support operation: %s" backend op))
    (let ((default-directory (expand-file-name directory)))
      (funcall fn default-directory))))

(defun agentsmith-agent--config-name (backend)
  "Return the display name for BACKEND."
  (alist-get 'name (agentsmith-agent--get-config backend)))

;;; Default Popup Display

(defun agentsmith-agent-popup-default (buffer)
  "Display agent BUFFER in a side window."
  (display-buffer buffer
                  '((display-buffer-in-side-window)
                    (side . right)
                    (window-width . 0.4))))

;;; Convenience Functions

(defun agentsmith-agent--read-backend ()
  "Prompt user to select an agent backend.  Returns the backend symbol."
  (let* ((choices (mapcar (lambda (entry)
                            (let ((sym (car entry))
                                  (name (alist-get 'name (cdr entry))))
                              (cons (format "%s (%s)" sym (or name ""))
                                    sym)))
                          agentsmith-agent-configs))
         (choice (completing-read "Agent backend: " choices nil t)))
    (cdr (assoc choice choices))))

(defun agentsmith-agent-start-for-worktree (worktree &optional backend)
  "Start an agent session for WORKTREE.
BACKEND defaults to `agentsmith-default-agent-backend'.
Sets the agent-session slot on WORKTREE.  Returns the session."
  (let* ((backend (or backend agentsmith-default-agent-backend))
         (dir (agentsmith-worktree-path worktree))
         (session (make-agentsmith-agent-session
                   :backend backend
                   :status 'stopped
                   :worktree-path dir)))
    (agentsmith-agent--call backend 'start dir)
    ;; Detect the buffer the start function created
    (setf (agentsmith-agent-session-buffer session)
          (agentsmith-agent--call backend 'detect-buffer dir))
    (setf (agentsmith-agent-session-status session)
          (agentsmith-agent--call backend 'status dir))
    (setf (agentsmith-worktree-agent-session worktree) session)
    session))

(defun agentsmith-agent-start-for-workspace (workspace &optional backend)
  "Start a top-level agent session for WORKSPACE.
BACKEND defaults to the workspace's `default-agent-backend'.
Sets the agent-session slot on WORKSPACE.  Returns the session."
  (let* ((backend (or backend
                      (agentsmith-workspace-default-agent-backend workspace)))
         (dir (agentsmith-workspace-directory workspace))
         (session (make-agentsmith-agent-session
                   :backend backend
                   :status 'stopped
                   :worktree-path dir)))
    (agentsmith-agent--call backend 'start dir)
    (setf (agentsmith-agent-session-buffer session)
          (agentsmith-agent--call backend 'detect-buffer dir))
    (setf (agentsmith-agent-session-status session)
          (agentsmith-agent--call backend 'status dir))
    (setf (agentsmith-workspace-agent-session workspace) session)
    session))

(defun agentsmith-agent-stop-session (session)
  "Stop the agent SESSION if it is running."
  (when (and session
             (not (eq (agentsmith-agent-session-status session) 'stopped)))
    (agentsmith-agent--call (agentsmith-agent-session-backend session)
                            'stop
                            (agentsmith-agent-session-worktree-path session))
    (setf (agentsmith-agent-session-status session) 'stopped)
    (setf (agentsmith-agent-session-buffer session) nil)))

(defun agentsmith-agent-show-buffer (session)
  "Display the agent buffer for SESSION using `agentsmith-agent-popup-function'."
  (let* ((backend (agentsmith-agent-session-backend session))
         (dir (agentsmith-agent-session-worktree-path session))
         (buf (or (let ((b (agentsmith-agent-session-buffer session)))
                    (and b (buffer-live-p b) b))
                  ;; Re-detect in case buffer was recreated or not tracked
                  (agentsmith-agent--call backend 'detect-buffer dir))))
    ;; Update the session's buffer slot
    (when buf
      (setf (agentsmith-agent-session-buffer session) buf))
    (if (and buf (buffer-live-p buf))
        (funcall agentsmith-agent-popup-function buf)
      (user-error "No agent buffer found"))))

(defun agentsmith-agent-detect-buffer-for-dir (directory &optional backend)
  "Try to detect an existing agent buffer for DIRECTORY.
Uses BACKEND (defaults to `agentsmith-default-agent-backend').
Returns the buffer or nil."
  (let ((backend (or backend agentsmith-default-agent-backend)))
    (condition-case nil
        (agentsmith-agent--call backend 'detect-buffer directory)
      (error nil))))

(defun agentsmith-agent-status-for-dir (directory &optional backend)
  "Get agent status for DIRECTORY without requiring a session struct.
Uses BACKEND (defaults to `agentsmith-default-agent-backend').
Returns a status symbol."
  (let ((backend (or backend agentsmith-default-agent-backend)))
    (condition-case nil
        (agentsmith-agent--call backend 'status directory)
      (error 'stopped))))

;;; Agent Popup Logic

(defun agentsmith-agent-popup-for-worktree (worktree)
  "Show/start agent for WORKTREE with cascading detection.
1. Show existing tracked session buffer
2. Auto-detect externally started agent buffer
3. Start a new agent and show its buffer"
  (let ((session (agentsmith-worktree-agent-session worktree)))
    (cond
     ;; 1. Existing tracked session
     (session
      (agentsmith-agent-show-buffer session))
     ;; 2. Auto-detect externally started buffer
     ((let ((buf (agentsmith-agent-detect-buffer-for-dir
                  (agentsmith-worktree-path worktree))))
        (when (and buf (buffer-live-p buf))
          (funcall agentsmith-agent-popup-function buf)
          t)))
     ;; 3. Nothing found — start a new agent and show it
     (t
      (let ((new-session (agentsmith-agent-start-for-worktree worktree)))
        (agentsmith-agent-show-buffer new-session))))))

(defun agentsmith-agent-popup-for-workspace (workspace)
  "Show/start agent for WORKSPACE.
Shows existing session buffer or starts a new one."
  (if-let* ((session (agentsmith-workspace-agent-session workspace)))
      (agentsmith-agent-show-buffer session)
    (let ((new-session (agentsmith-agent-start-for-workspace workspace)))
      (agentsmith-agent-show-buffer new-session))))

;;; Claude Code IDE Backend Helpers

;; claude-code-ide keys its process hash table via `project-root', which
;; returns paths WITH a trailing slash (e.g. "/path/repo-a/").  We must
;; use `file-name-as-directory' when setting `default-directory' so that
;; `project-current' resolves from the correct directory — without it,
;; `file-name-directory' strips the last component and project detection
;; starts from the PARENT directory.
;;
;; Functions are called WITHOUT args so they use their own
;; `project-current'-based resolution via `claude-code-ide--get-working-directory',
;; avoiding format mismatches with hash table keys.

(declare-function claude-code-ide--get-buffer-name "claude-code-ide" (&optional directory))
(declare-function claude-code-ide--get-process "claude-code-ide" (&optional directory))

(defun agentsmith--claude-code-ide-start (directory)
  "Start or toggle a claude-code-ide session in DIRECTORY.
Uses `default-directory' which is set by the dispatch caller."
  (let ((default-directory (file-name-as-directory directory)))
    (if (fboundp 'claude-code-ide)
        (claude-code-ide)
      (user-error "claude-code-ide is not installed"))))

(defun agentsmith--claude-code-ide-stop (directory)
  "Stop the claude-code-ide session in DIRECTORY."
  (let ((default-directory (file-name-as-directory directory)))
    (if (fboundp 'claude-code-ide-stop)
        (condition-case nil
            (claude-code-ide-stop)
          (error nil))
      (user-error "claude-code-ide is not installed"))))

(defun agentsmith--claude-code-ide-detect-buffer (directory)
  "Find the claude-code-ide buffer for DIRECTORY.
Calls claude-code-ide functions without args so they resolve via
`project-current' using `default-directory' (set by the dispatch caller).
This avoids trailing-slash mismatches with the process hash table."
  (let ((default-directory (file-name-as-directory (expand-file-name directory))))
    (or (when (fboundp 'claude-code-ide--get-process)
          (when-let* ((proc (claude-code-ide--get-process)))
            (process-buffer proc)))
        (when (fboundp 'claude-code-ide--get-buffer-name)
          (get-buffer (claude-code-ide--get-buffer-name))))))

(defun agentsmith--claude-code-ide-status (directory)
  "Return status of claude-code-ide in DIRECTORY.
Uses `default-directory' for path resolution to match process table keys."
  (let ((default-directory (file-name-as-directory (expand-file-name directory))))
    (if (and (fboundp 'claude-code-ide--get-process)
             (claude-code-ide--get-process))
        'ready
      (if-let* ((buf (agentsmith--claude-code-ide-detect-buffer directory)))
          (if (get-buffer-process buf) 'ready 'stopped)
        'stopped))))

(provide 'agentsmith-agent)
;;; agentsmith-agent.el ends here
