Emacs major mode for managing coding agents across projects / repos / etc

### Main workflow
1. Create a new workspace: 
 - creates a new directory (user defined)
 - select git repositories to include, create git worktrees within the workspace dir (name the worktrees after the workspace) (autodetect whether it's a .jj repo or a .git only to determine whether to use `jj workspace` or `git worktree` to create)
 - organize the workspace as a projectile project in emacs
 - help user manage a top-level agent buffer (default is `claude-code-ide`, but user should be allowed to configure and select active agent mode heirarchically within a workspace)
 - user may also spawn individual agent buffers within each worktree beneath a workspace. The idea here is that users can coordinate large changes cross-repo and planning in the toplevel agent buffer, then can dig down individually in worktrees as they need to make edits and run tests
 - in the toplevel workspace, allow storing plans and content as org files, etc for reusable agent context.

The agentsmith buffer uses a heirarchical structure:

```
 - Workspace
   - Worktree
   - Worktree
   - Worktree
```
The user can move the cursor around in emacs, press Enter to open that worktree in the IDE.

The view should also include some kind of live indicator of agent progress, if it's ready for user input or still thinking about a job. Users can press a hotkey (shift+enter) to open the agent buffer in a popout instead.

This probably all uses `transient` mode that ships with magit to build UIs.


### Features
