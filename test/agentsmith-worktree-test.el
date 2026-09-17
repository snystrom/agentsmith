;;; agentsmith-worktree-test.el --- Tests for agentsmith-worktree.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l ert -l test/agentsmith-worktree-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agentsmith-worktree)

(defun agentsmith-worktree-test--git (dir &rest args)
  "Run git with ARGS in DIR, failing the test on a nonzero exit."
  (let ((default-directory dir))
    (should (zerop (apply #'call-process agentsmith-git-executable nil nil nil
                          "-c" "user.email=test@example.com"
                          "-c" "user.name=Test"
                          args)))))

(defun agentsmith-worktree-test--make-dirty-git-worktree ()
  "Create a temp git repo with a worktree containing an uncommitted change.
Return (REPO-DIR . WORKTREE-DIR)."
  (let* ((repo (make-temp-file "agentsmith-worktree-test-repo" t))
         (wt (expand-file-name "wt" repo)))
    (agentsmith-worktree-test--git repo "init" "-q")
    (agentsmith-worktree-test--git repo "commit" "--allow-empty" "-q" "-m" "init")
    (agentsmith-worktree-test--git repo "worktree" "add" "-b" "feature" wt)
    (with-temp-file (expand-file-name "dirty.txt" wt) (insert "uncommitted change"))
    (cons repo wt)))

(ert-deftest agentsmith-worktree-remove-git-surfaces-underlying-error ()
  "Removing a path that is not a git worktree should raise git's own
error text, not just a generic \"Failed to remove\" message."
  (let* ((repo (make-temp-file "agentsmith-worktree-test-repo" t))
         (not-a-worktree (expand-file-name "not-a-worktree" repo)))
    (unwind-protect
        (progn
          (agentsmith-worktree-test--git repo "init" "-q")
          (agentsmith-worktree-test--git repo "commit" "--allow-empty" "-q" "-m" "init")
          (make-directory not-a-worktree)
          (let ((err (should-error (agentsmith-worktree-remove 'git not-a-worktree repo))))
            (should (string-match-p "is not a working tree"
                                    (error-message-string err)))))
      (delete-directory repo t))))

(ert-deftest agentsmith-worktree-remove-git-force-removes-dirty-worktree ()
  "Removing a dirty git worktree should succeed.
Agent worktrees routinely have uncommitted or untracked changes, so
removal must force past git's dirty-worktree guard rather than
erroring on the common case."
  (let* ((dirs (agentsmith-worktree-test--make-dirty-git-worktree))
         (repo (car dirs))
         (wt (cdr dirs)))
    (unwind-protect
        (progn
          (agentsmith-worktree-remove 'git wt repo)
          (should-not (file-exists-p wt)))
      (delete-directory repo t))))

(provide 'agentsmith-worktree-test)
;;; agentsmith-worktree-test.el ends here
