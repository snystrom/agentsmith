# AgentSmith

> We're not here because we're free... we're here because we're *not* free. There's no escaping reason, no denying purpose, because, as we both know, without purpose, we would not exist.

Emacs major mode for managing coding agent workflows across multiple projects and repositories.

## Overview

AgentSmith is born out of frustration coordinating cross-repo features with coding agents. 

I often work on features that require coordinated changes across repos. Usually I do this by making a new project with a worktree for each repo in scope for a feature. I'll launch 1 agent scoped to the whole project, let it cook, then drop into each worktree to review code, polish things up, or launch another agent with worktree scope to help with any of this. I find it works pretty well, but often get into clunky spots setting up the structure, and once configured, have to do stupid things to pop open the correct agent buffer. Finally, I don't like being locked into a single agent platform. I use `claude-code-ide` as my daily driver for now, but want to have a consistent interface for alternative platforms should I choose to switch, or give myself the option to use different agents at different times, etc.

More broadly, this also changes a bit how I want to work in my editor: I really want a "projectile" type interface for multi-repo workspaces rather than individual repos.

AgentSmith is designed to help with each of these issues:
- Automatic workspace & worktree creation
- Management of agents at the workspace and worktree level
- Helpers for swapping agent sessions within and between workspaces
- Register custom agent backends so each can be managed with the same helpers

### Workspaces & Worktrees

AgentSmith bundles git/jj worktrees from multiple repos into **workspaces**, each with its own agent sessions. The main buffer displays a hierarchical view:

```
[OK] my-workspace  ~/workspaces/my-workspace/
    [--] repo-a  feature-branch  ~/workspaces/my-workspace/repo-a/
    [OK] repo-b  feature-branch  ~/workspaces/my-workspace/repo-b/
```

Status indicators show agent state: `[OK]` ready, `[..]` thinking, `[--]` stopped. this actually doesn't work very well because the buffer doesn't auto-refresh, sorry. Eventually I'd like to get agent hooks working so live monitoring status is more seamless.

To create a workspace, users select a series of target repos, and AgentSmith automatically creates a git or jj worktree for you.

## Below is mostly correct AI slop

I'll get this moved into the agent config soon and replaced with actually useful docs.

## Requirements

- Emacs 29.1+
- [magit-section](https://github.com/magit/magit) 4.0.0+
- [transient](https://github.com/magit/transient) 0.5.0+
- [projectile](https://github.com/bbatsov/projectile)
- An agent backend (ships with [claude-code-ide](https://github.com/anthropics/claude-code) support)

## Installation

Clone the repo and add to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/agentsmith")
(require 'agentsmith)
```

With `use-package` and `straight.el`:

```elisp
(use-package agentsmith
  :straight (:host github :repo "snystrom/agentsmith")
  :commands (agentsmith agentsmith-workspace-list))
```

Doom Emacs

```elisp
;; Doom packages.el
(package! agentsmith :recipe (:host github :repo "snystrom/agentsmith"))
```

## Usage

| Command | Description |
|---------|-------------|
| `M-x agentsmith` | Open the AgentSmith status buffer |
| `M-x agentsmith-create-workspace` | Create a new workspace |
| `M-x agentsmith-workspace-list` | Select a workspace and switch to it |
| `M-x agentsmith-worktree-open-agent` | Open agent for the current worktree (from any buffer) |
| `M-x agentsmith-workspace-open-agent` | Open agent for the current workspace (from any buffer) |
| `M-x agentsmith-worktree-toggle-agent` | Toggle agent popup for the current worktree (works outside workspaces too) |
| `M-x agentsmith-worktree-toggle-agent-and-go` | Toggle agent popup and move cursor into it |
| `M-x agentsmith-workspace-toggle-agent` | Toggle agent popup for the current workspace |
| `M-x agentsmith-workspace-toggle-agent-and-go` | Toggle agent popup for workspace and move cursor into it |
| `M-x agentsmith-workspace-select-worktree-agent` | Select a worktree in the current workspace and open its agent |
| `M-x agentsmith-worktree-find-file` | Select a worktree, then find a file in it (opens under workspace project) |
| `M-x agentsmith-workspace-switch-buffer` | Switch to an open buffer belonging to the current workspace |
| `M-x agentsmith-worktree-open-vcs` | Open VCS interface (magit/jj) for the current worktree (from any buffer) |
| `M-x agentsmith-workspace-select-worktree-vcs` | Select a worktree and open its VCS interface |
| `M-x agentsmith-workspace-import` | Import an existing directory as a workspace |
| `M-x agentsmith-workspace-doctor` | Diagnose a workspace and report any issues |
| `M-x agentsmith-workspace-repair` | Repair a workspace that has been moved on disk |

## Keybindings

### Status Buffer

| Key | Context | Action |
|-----|---------|--------|
| `RET` | Workspace | Switch to workspace as projectile project |
| `RET` | Worktree | Switch to worktree as projectile project |
| `S-RET` | Worktree | Open agent buffer (cascade: show/detect/start) |
| `V` | Worktree | Open VCS interface (magit, jj mode, etc.) |
| `V` | Workspace | Open VCS interface for workspace directory |
| `D` | Any | Open in dired |
| `a` | Workspace | Workspace agent transient menu |
| `a` | Worktree | Worktree agent transient menu |
| `w` | Workspace | Add a worktree |
| `x` | Any | Delete menu (`d` deregister, `D` delete from disk) |
| `p` | Workspace | Open plans directory |
| `c` | Global | Create workspace |
| `i` | Global | Import workspace |
| `g` | Global | Refresh buffer |
| `q` | Global | Quit buffer |
| `?` | Global | Dispatch transient menu |

### Evil Mode

Evil normal-state bindings are set up automatically when evil is loaded. All the above keys work from normal state. `gr` refreshes (standard evil pattern).

### Doom Emacs

I use something kinda like this in my config...
``` elisp
(map! :leader
      :desc "agentsmith"
      "a a" #'agentsmith
      "a w" #'agentsmith-workspace-toggle-agent
      "a W" #'agentsmith-workspace-toggle-agent-and-go
      "a t" #'agentsmith-worktree-toggle-agent
      "a T" #'agentsmith-worktree-toggle-agent-and-go
      "a s" #'agentsmith-workspace-select-worktree-agent
      "a p" #'agentsmith-workspace-list
      "a f" #'agentsmith-worktree-find-file
      "a b" #'agentsmith-workspace-switch-buffer
      "a v" #'agentsmith-workspace-select-worktree-vcs
      )
```

## Configuration

### Default paths

AgentSmith uses three directory settings:

- `agentsmith-default-workspace-parent` — where new workspaces are created (default: `~/workspaces/`)
- `agentsmith-default-repo-parent` — default directory when prompting for repos to add as worktrees (default: `~/repos/`)
- `agentsmith-workspace-directory` — where AgentSmith stores its global registry (default: `<user-emacs-directory>/agentsmith/`)

```elisp
;; Standard Emacs
(setq agentsmith-default-workspace-parent "~/projects/workspaces/")
(setq agentsmith-default-repo-parent "~/projects/repos/")
(setq agentsmith-workspace-directory "~/.emacs.d/agentsmith/")
```

```elisp
;; Doom Emacs (config.el)
(after! agentsmith
  (setq agentsmith-default-workspace-parent "~/projects/workspaces/")
  (setq agentsmith-default-repo-parent "~/projects/repos/")
  ;; Doom sets user-emacs-directory to ~/.config/emacs/, so the default is
  ;; ~/.config/emacs/agentsmith/ — override if you prefer a different location
  (setq agentsmith-workspace-directory "~/.config/emacs/.local/agentsmith/"))
```

### Open behavior

When you press `RET` on a workspace or worktree, AgentSmith calls `projectile-switch-project-action` in that directory. This means your projectile configuration controls what happens — whether that's `projectile-find-file`, a Doom-specific action, or something custom.

To override the open behavior entirely:

```elisp
;; Custom worktree open function
(setq agentsmith-worktree-open-function
      (lambda (wt)
        (dired (agentsmith-worktree-path wt))))

;; Custom workspace open function
(setq agentsmith-workspace-open-function
      (lambda (ws)
        (dired (agentsmith-workspace-directory ws))))
```

### VCS interface

Press `V` on a worktree to open its VCS interface, or use `M-x agentsmith-worktree-open-vcs` from any buffer inside a worktree. The function called is controlled by `agentsmith-worktree-vcs-mode-functions`, an alist mapping VCS symbols to functions.

Git defaults to `magit-status`. Jujutsu has no default — you must configure it:

```elisp
;; Standard Emacs
(setq agentsmith-worktree-vcs-mode-functions
      '((git . magit-status)
        (jj  . jj-log)))
```

```elisp
;; Doom Emacs (config.el)
(after! agentsmith
  (setq agentsmith-worktree-vcs-mode-functions
        '((git . magit-status)
          (jj  . jj-log))))
```

To select a worktree and open its VCS interface from anywhere in a workspace, use `M-x agentsmith-workspace-select-worktree-vcs`.

### Agent popup display

Control how agent buffers are displayed:

```elisp
;; Default: right side window at 40% width
(setq agentsmith-agent-popup-function #'agentsmith-agent-popup-default)

;; Custom: bottom window
(setq agentsmith-agent-popup-function
      (lambda (buf)
        (display-buffer buf
                        '((display-buffer-in-side-window)
                          (side . bottom)
                          (window-height . 0.3)))))
```

### Using toggle commands outside workspaces

By default, `agentsmith-worktree-toggle-agent` (and the `-and-go` variant) work as a generic agent launcher in any project — not just inside registered workspaces. This makes them useful as global keybindings for your agent backend.

```elisp
;; Example: bind toggle-and-go globally
(keymap-global-set "C-c a" #'agentsmith-worktree-toggle-agent-and-go)
```

The fallback behavior is controlled by function-valued defcustoms, so you can customize or disable it:

```elisp
;; Disable: error when not in a workspace (old behavior)
(setq agentsmith-agent-toggle-outside-workspace
      #'agentsmith-agent-toggle-outside-workspace-error)
(setq agentsmith-agent-toggle-outside-workspace-and-go
      #'agentsmith-agent-toggle-outside-workspace-error)
```

### Importing workspaces

You can import an existing directory as a workspace with `M-x agentsmith-workspace-import` or `i` in the status buffer. This handles three cases:

1. **Re-registering a soft-deleted workspace**: If the directory has an existing `.agentsmith.el` config (e.g. from a previous workspace that was deregistered), it re-registers it directly.
2. **Re-importing a moved workspace**: If the config's stored `:directory` differs from the directory being imported (because the workspace was relocated on disk), AgentSmith delegates to `agentsmith-workspace-repair` — see [Repairing a moved workspace](#repairing-a-moved-workspace).
3. **Importing a manually-created directory**: If there's no config, AgentSmith scans immediate subdirectories for git/jj repos and builds the workspace config automatically. Imported workspaces are tagged with `(:imported t)` in their metadata. No worktrees are created in the detected repos, we use the existing branch or commit as-is.

### Repairing a moved workspace

If you move a workspace directory on disk (e.g. `~/projects/my-workspace/` → `~/workspaces/my-workspace/`), the `.agentsmith.el` config and the git worktrees inside still point at the old location. AgentSmith provides a diagnose/repair pair to fix this up.

- **`M-x agentsmith-workspace-doctor`** — prompts for a workspace directory and reports any issues without making changes. Issue types include:
  - `directory-mismatch` — the stored `:directory` differs from where `.agentsmith.el` actually lives
  - `path-missing` — a worktree's recorded `:path` no longer exists
  - `vcs-broken` — VCS metadata is unusable (e.g. stale gitdir pointer)
  - `source-repo-missing` — a worktree's `:source-repo` no longer exists on disk

- **`M-x agentsmith-workspace-repair`** — runs `doctor`, then:
  - Rewrites the workspace `:directory` to the current location.
  - For each broken worktree, rewrites `:path` to `<workspace-dir>/<basename>` and runs `git worktree repair` from the source repo to fix the gitdir pointers on both sides.
  - Updates the global registry (adds the new path, drops the old one).
  - Reports any issues it couldn't auto-fix (e.g. missing source repos) without aborting.

Invoking `agentsmith-workspace-import` on a moved workspace delegates to `agentsmith-workspace-repair` automatically when it detects a directory mismatch, so re-import is usually all you need.

**jj caveat:** moving a jj workspace is officially [unsupported upstream](https://github.com/jj-vcs/jj/issues/7113). AgentSmith's repair for jj worktrees will signal an error; other worktrees in the same workspace still get repaired. Until jj adds support, moved jj workspaces need to be re-created manually (`jj workspace forget` + `jj workspace add` at the new location).

### Deleting workspaces and worktrees

Pressing `x` on a workspace or worktree opens the delete menu:

- **`x d`** — **Deregister** (soft delete): removes from AgentSmith's registry but keeps all files on disk. The `.agentsmith.el` config remains, so you can re-import later.
- **`x D`** — **Delete from disk** (hard delete): permanently removes all files including the workspace directory. For worktrees, this also calls `git worktree remove` / `jj workspace forget`.

Both options stop any running agents and deregister from projectile.

### Agent backends

AgentSmith ships with `claude-code-ide` as the default backend. Register custom backends:

```elisp
(push '(my-agent
        (name          . "My Agent")
        (start         . my-agent-start)
        (stop          . my-agent-stop)
        (open          . my-agent-open)
        (detect-buffer . my-agent-detect)
        (status        . my-agent-status))
      agentsmith-agent-configs)
```

### Extending transient menus

Add custom actions to the dispatch menu:

```elisp
(transient-append-suffix 'agentsmith-dispatch "g"
  '("x" "My custom action" my-custom-command))
```

### Perspectives and workspaces

When you press `RET` on a worktree, AgentSmith treats the **workspace** as the project for perspective/workspace-tab purposes — so `persp-projectile`, Doom workspaces, etc. name the perspective after the workspace rather than the worktree. This avoids cross-workspace collisions when two workspaces contain worktrees with the same basename. The find-file prompt that follows is still scoped to the worktree you clicked.

Workspace dirs aren't real projectile projects (no `.git` / `.projectile` marker — by design, otherwise every tool that walks up looking for a project root would resolve worktrees up to the workspace). Because of that, the projectile-based bridges in `persp-projectile` and Doom's `+workspaces` module don't fire on their own. AgentSmith provides two defcustoms to wire the perspective handoff explicitly:

- `agentsmith-switch-to-existing-project-function` — runs first; if it returns non-nil ("project is already open"), the find-file step is skipped.
- `agentsmith-create-project-function` — runs next on first-open; creates and switches to the perspective/workspace tab.

Configure both as a matched pair:

```elisp
;; Doom Emacs workspaces
(setq agentsmith-switch-to-existing-project-function
      #'agentsmith-switch-to-existing-project-doom-workspace
      agentsmith-create-project-function
      #'agentsmith-create-project-doom-workspace)

;; perspective.el (e.g. with persp-projectile)
(setq agentsmith-switch-to-existing-project-function
      #'agentsmith-switch-to-existing-project-perspective
      agentsmith-create-project-function
      #'agentsmith-create-project-perspective)
```

The defaults are no-ops on the perspective side (just buffer selection), so users without a perspective package see no change.

## Doom Emacs

AgentSmith works with Doom Emacs out of the box. Doom overrides `projectile-switch-project-action` to use its own workspace/file selection system, so `RET` in the AgentSmith buffer will automatically use Doom's project switching behavior (e.g., `+ivy/projectile-find-file` or the vertico equivalent).

If you use Doom's `ui/workspaces` module, configure both the existing-project and create-project hooks so AgentSmith opens worktrees inside the right workspace tab:

```elisp
;; Doom config.el
(use-package! agentsmith
  :commands (agentsmith agentsmith-workspace-list)
  :config
  (setq agentsmith-switch-to-existing-project-function
        #'agentsmith-switch-to-existing-project-doom-workspace
        agentsmith-create-project-function
        #'agentsmith-create-project-doom-workspace))
```
