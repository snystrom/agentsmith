# AgentSmith

Emacs major mode for managing coding agent workflows across projects/repos.

## Architecture

Seven elisp modules, dependency flows downward:

```
agentsmith.el                  -- Entry point, autoloads, M-x agentsmith
  ├── agentsmith-buffer.el     -- magit-section-mode status buffer, keymaps, rendering
  ├── agentsmith-transient.el  -- Transient popup menus (?, a on sections, etc.)
  ├── agentsmith-agent.el      -- Config-based agent backend registry + dispatch
  ├── agentsmith-kanban.el     -- Kanban column persistence (org file read/write)
  ├── agentsmith-workspace.el  -- Workspace/worktree/session structs, persistence, CRUD
  └── agentsmith-worktree.el   -- VCS detection, git worktree / jj workspace operations
```

## Core Concepts

- **Workspace**: directory bundling git/jj worktrees from multiple repos. Persisted as `.agentsmith.el` (plist sexp) plus global registry at `~/.emacs.d/agentsmith/registry.el`.
- **Worktree**: a git worktree or jj workspace inside a workspace dir. VCS autodetected (.jj first, then .git).
- **Agent session**: runtime state tracking a running agent (buffer, status, backend symbol). NOT persisted.

## Data Structures (agentsmith-workspace.el)

Three `cl-defstruct`s:
- `agentsmith-workspace` — name, directory, worktrees list, default-agent-backend, agent-session, metadata
- `agentsmith-worktree` — name, path, source-repo, vcs, branch, agent-session, metadata
- `agentsmith-agent-session` — backend, buffer, status, worktree-path, metadata

## Agent Backend System (agentsmith-agent.el)

**Config-based, NOT cl-defgeneric.** Backends register in `agentsmith-agent-configs`:

```elisp
(defvar agentsmith-agent-configs
  `((claude-code-ide
     (name          . "Claude Code IDE")
     (start         . agentsmith--claude-code-ide-start)   ; fn(directory) — start process
     (stop          . agentsmith--claude-code-ide-stop)
     (open          . agentsmith--claude-code-ide-open)    ; fn(directory) — start + show, idempotent
     (detect-buffer . agentsmith--claude-code-ide-detect-buffer)
     (status        . agentsmith--claude-code-ide-status))))
```

All operation functions take a single DIRECTORY argument. Dispatch via `agentsmith-agent--call` which sets `default-directory` then `funcall`s.

`open` is optional. When provided, agentsmith routes user-facing "show the agent" requests through it so the backend's own window rules (e.g. `claude-code-ide-use-side-window`) win, rather than wrapping the buffer with `agentsmith-agent-popup-function`. When omitted, agentsmith falls back to `start` followed by `agentsmith-agent-popup-function`.

### claude-code-ide integration gotchas

- `claude-code-ide--get-process` hash table is keyed by `project-root` output (trailing slash: `/path/dir/`). Our worktree paths use `expand-file-name` (no trailing slash: `/path/dir`). **Always call `claude-code-ide--get-process` and `claude-code-ide--get-buffer-name` without args** so they use their own `claude-code-ide--get-working-directory` path resolution via `project-current`. The `agentsmith-agent--call` dispatch already sets `default-directory`.
- `claude-code-ide--get-buffer-name` uses only the directory basename (`*claude-code[repo-a]*`), so two different directories with the same basename collide. Use process-table lookup as primary, buffer-name as fallback with directory verification.

## Buffer (agentsmith-buffer.el)

Derived from `magit-section-mode`. Four EIEIO section classes (needed because magit hardcodes `magit-TYPENAME-section-map` keymap lookup):
- `agentsmith-root-section`
- `agentsmith-workspace-section` (keymap: `agentsmith-workspace-section-map`)
- `agentsmith-worktree-section` (keymap: `agentsmith-worktree-section-map`)
- `agentsmith-column-section` (keymap: `agentsmith-column-section-map`) — kanban view only

Two views controlled by `agentsmith--current-view` buffer-local var:
- `workspaces` (default) — flat list of all workspaces
- `kanban` — workspaces grouped into user-defined columns from `kanban.org`

Status detection falls back to querying the backend's `status` operation when no `agentsmith-agent-session` exists on the struct (handles externally-started agents).

## VCS Operations (agentsmith-worktree.el)

Uses `cl-defgeneric` dispatched on VCS symbol (`'git` or `'jj`). Users can add new VCS types by defining `cl-defmethod` implementations.

Worktree creation: workspace name is used as the git branch / jj workspace name. Display name in UI = repo basename.

## Extensibility Points

- **Agent backends**: push to `agentsmith-agent-configs`, define 5 operation functions
- **Keybinds**: override via `keymap-set` on section maps or `agentsmith-mode-map`
- **Open behavior**: `agentsmith-worktree-open-function`, `agentsmith-workspace-open-function`
- **Agent popup display**: `agentsmith-agent-popup-function`
- **Hooks**: `agentsmith-after-workspace-create-hook`, `agentsmith-after-workspace-delete-hook`
- **Transient menus**: appendable via `transient-append-suffix`
- **Status indicators**: `agentsmith-status-indicators` defcustom
- **VCS types**: `cl-defmethod` on VCS symbol for create/remove/branch-info

## Dependencies

- `magit-section` (from magit) — section-based buffer UI
- `transient` — popup menus
- `cl-lib` — structs, generics
- `claude-code-ide` (optional, runtime) — default agent backend
- `projectile` (optional) — workspace registration
