# AgentSmith

> We're not here because we're free... we're here because we're *not* free. There's no escaping reason, no denying purpose, because, as we both know, without purpose, we would not exist.

Emacs major mode for managing coding agent workflows across multiple projects and repositories.

## Overview

AgentSmith is born out of frustration coordinating cross-repo features with coding agents. 

I often work on features that require coordinated changes across repos. Usually I do this by making a new project with a worktree for each repo in scope for a feature. I'll launch 1 agent scoped to the whole project, let it cook, then drop into each worktree to review code, polish things up, or launch another agent with worktree scope to help with any of this. I find it works pretty well, but often get into clunky spots setting up the structure, and once configured, have to do stupid things to pop open the correct agent buffer. Finally, I don't like being locked into a single agent platform. I use `claude-code-ide` as my daily driver for now, but want to have a consistent interface for alternative platforms should I choose to switch, or give myself the option to use different agents at different times, etc.

More broadly, this also changes a bit how I want to work in my editor: I really want a "projectile" type interface for workspaces rather than repos.

AgentSmith is designed to help with each of these issues:
- Automatic workspace & worktree creation
- Management of agents at the workspace and worktree level
- Helpers for swapping agent sessions within and between workspaces
- AgentSmith allows registration of custom agent backends so each can be managed with the same helpers

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
| `M-x agentsmith-workspace-select-worktree-agent` | Select a worktree in the current workspace and open its agent |

## Keybindings

### Status Buffer

| Key | Context | Action |
|-----|---------|--------|
| `RET` | Workspace | Switch to workspace as projectile project |
| `RET` | Worktree | Switch to worktree as projectile project |
| `S-RET` | Worktree | Open agent buffer (cascade: show/detect/start) |
| `D` | Any | Open in dired |
| `a` | Workspace | Workspace agent transient menu |
| `a` | Worktree | Worktree agent transient menu |
| `w` | Workspace | Add a worktree |
| `d` | Any | Delete workspace / remove worktree |
| `p` | Workspace | Open plans directory |
| `c` | Global | Create workspace |
| `g` | Global | Refresh buffer |
| `q` | Global | Quit buffer |
| `?` | Global | Dispatch transient menu |

### Evil Mode

Evil normal-state bindings are set up automatically when evil is loaded. All the above keys work from normal state. `gr` refreshes (standard evil pattern).

## Configuration

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

### Switching to already-open projects

By default, if a project already has file-visiting buffers open, `RET` switches to the most recent buffer instead of showing the file finder. Customize this with `agentsmith-switch-to-existing-project-function` — it receives the project directory and should return non-nil if it handled the switch.

## Doom Emacs

AgentSmith works with Doom Emacs out of the box. Doom overrides `projectile-switch-project-action` to use its own workspace/file selection system, so `RET` in the AgentSmith buffer will automatically use Doom's project switching behavior (e.g., `+ivy/projectile-find-file` or the vertico equivalent).

If you use Doom's `ui/workspaces` module, you can configure AgentSmith to switch to existing workspace tabs instead of opening the file finder:

```elisp
;; Doom config.el
(use-package! agentsmith
  :commands (agentsmith agentsmith-workspace-list)
  :config
  ;; Switch to existing Doom workspace tab if open
  (setq agentsmith-switch-to-existing-project-function
        (lambda (dir)
          (let ((name (file-name-nondirectory (directory-file-name dir))))
            (when (+workspace-exists-p name)
              (+workspace-switch name)
              t)))))
```
