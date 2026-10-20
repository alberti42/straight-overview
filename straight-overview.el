;;; straight-overview.el --- Selective upgrade UI for straight.el packages -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, vc
;; URL: https://github.com/alberti42/straight-overview
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `straight-overview' is a read-only overview and selective-upgrade UI for
;; packages managed by straight.el.  It answers the question "which of my
;; packages have newer commits upstream, and how far behind am I?" and lets
;; you upgrade only the ones you choose -- instead of the all-or-nothing
;; `straight-pull-all'.
;;
;; `M-x straight-overview' opens a `tabulated-list-mode' buffer with one row
;; per git-managed package:
;;
;;   Pin | Package | Installed | Branch | Behind | Tag | Remote
;;
;; The "Behind" column shows `(<commits>; <time>)' -- how many commits and how
;; much wall-clock time the installed checkout is behind the tracked upstream
;; branch.  By default only outdated packages are shown.
;;
;; The list is built from local git refs (no network), running git for all
;; packages in parallel.  The displayed "behind" figures reflect the last
;; time each remote was fetched; press `G' to fetch all remotes in parallel
;; and refresh.
;;
;; Packages are marked dired-style and acted on in a batch:
;;
;;   m   mark for update          x   pull marked (+ rebuild if enabled)
;;   u   unmark                   c   show changelog (HEAD..upstream)
;;   U   unmark all               o / RET  open repo in browser
;;   M   mark all outdated        a   toggle outdated-only / all
;;   g   re-scan (local, no fetch)
;;   G   fetch all remotes in the background, then re-scan
;;   X   pull marked, also those whose dependencies are not met
;;
;; Packages can also be pinned (held), which marks them in the Pin column,
;; fades the row, and makes them un-markable:
;;
;;   P   pin at the current commit       R   restore to the pinned commit
;;   F   free (unpin)
;;
;; Pins persist to `straight-overview-pinned-file' when set.
;;
;; Customize `straight-overview-fetch-on-open', `straight-overview-show',
;; `straight-overview-build-on-pull' and `straight-overview-pinned-file' to
;; taste.
;;
;; Requires a working straight.el installation (https://github.com/radian-software/straight.el).
;; straight.el is not distributed through a package archive, so it cannot be
;; expressed as a normal package dependency; it is assumed to be already
;; loaded.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'straight)
;; For the `dired-mark' / `dired-marked' faces that the mark styling inherits.
(require 'dired)
;; For reading `Package-Requires' and checking built-in versions.
(require 'lisp-mnt)
(require 'package)

;; Optional integration: `straight-overview-changelog' uses Magit when it is
;; available, but Magit is not a hard dependency.
(declare-function magit-log-setup-buffer "magit-log"
                  (revs args files &optional locked focus))
;; Special, so `straight-overview-changelog' binds it dynamically.
(defvar magit-display-buffer-function)

(defgroup straight-overview nil
  "Overview of straight.el packages and their upstream status."
  :group 'straight)

(defcustom straight-overview-fetch-on-open nil
  "Whether to fetch all remotes when opening the overview.
The fetch runs in the background; the overview opens from local refs
and refreshes when the fetch ends.  nil does not fetch (press G later)."
  :type '(choice (const :tag "Never (open from local refs; refresh with G)" nil)
                 (const :tag "Ask each time" ask)
                 (const :tag "Always fetch" t))
  :group 'straight-overview)

(defcustom straight-overview-show 'outdated
  "Which packages to display by default."
  :type '(choice (const :tag "Only outdated" outdated)
                 (const :tag "All" all))
  :group 'straight-overview)

(defcustom straight-overview-hl-line t
  "When non-nil, highlight the current row with `hl-line-mode'."
  :type 'boolean
  :group 'straight-overview)

(defcustom straight-overview-changelog-use-magit t
  "Whether `straight-overview-changelog' uses Magit when it is available.
When non-nil (the default) and Magit is loaded, the changelog opens in a
`magit-log' buffer so each commit is actionable.  When nil, always use
the plain `git log' listing even if Magit is installed (useful for
debugging the built-in path)."
  :type 'boolean
  :group 'straight-overview)

(defcustom straight-overview-build-on-pull nil
  "When non-nil, also rebuild each package immediately after pulling.
When nil, straight rebuilds the modified repos on the next Emacs
restart (the merge registers a repo modification).
Also governs whether `straight-overview-restore' rebuilds in-session."
  :type 'boolean
  :group 'straight-overview)

(defcustom straight-overview-jobs nil
  "Maximum number of git processes to run at once while scanning local refs.
nil uses the number of processors (`num-processors')."
  :type '(choice (const :tag "Number of processors" nil)
                 (natnum :tag "Processes"))
  :group 'straight-overview)

(defcustom straight-overview-fetch-jobs 16
  "Maximum number of `git fetch' processes to run at once.
A fetch mostly waits on its server, so more fetches than processors
still pay off."
  :type 'natnum
  :group 'straight-overview)

(defcustom straight-overview-fetch-timeout 30
  "Seconds after which a single repository's fetch is stopped.
A stopped fetch is reported as timed out.  nil means no limit."
  :type '(choice (const :tag "No limit" nil)
                 (number :tag "Seconds"))
  :group 'straight-overview)

(defcustom straight-overview-pinned-file nil
  "File where pinned packages are persisted, or nil for no persistence.
When set to a path, pins are stored there as an alist of
\(PACKAGE-NAME . COMMIT) in plain `.eld' form, read on first use and
rewritten on every pin/unpin.  When nil, pinning still works but is
session-only (lost when Emacs exits).

A pinned package is shown in the overview but cannot be marked for
update; `straight-overview-restore' resets it to its pinned commit."
  :type '(choice (const :tag "No persistence (session-only)" nil)
                 (file :tag "Lockfile (.eld)"))
  :group 'straight-overview)

(defface straight-overview-outdated
  '((t :inherit warning))
  "Face for the behind-upstream indicator.")

(defface straight-overview-mark
  '((t :inherit dired-mark))
  "Face for the mark character on marked rows.
Inherits from Dired's `dired-mark' so it tracks the active theme.")

(defface straight-overview-marked
  '((t :inherit dired-marked))
  "Face for marked package rows.
Inherits from Dired's `dired-marked' so marked rows pick up the same
styling Dired uses for marked files under the active theme.")

(defvar-local straight-overview--records nil
  "Cached list of per-package status plists for the current buffer.")
(defvar-local straight-overview--marks nil
  "Hash table of marked package names (string -> t).")
(defvar-local straight-overview--show nil
  "Buffer-local copy of `straight-overview-show'.")

(defvar straight-overview--log-buffers nil
  "Magit log buffers opened by `straight-overview-changelog'.
Used to reuse an already-visible changelog window instead of
popping a new one for each package.")

(defvar-local straight-overview--mark-overlays nil
  "Overlays highlighting the currently marked rows.")

(defvar-local straight-overview--banner nil
  "Overlay showing the status banner above the first row.")

(defvar straight-overview--pins nil
  "Alist of (PACKAGE-NAME . COMMIT) for pinned packages.
Loaded from `straight-overview-pinned-file' and the source of truth
for pin state across the session.")
(defvar straight-overview--pins-loaded nil
  "Non-nil once `straight-overview--pins' has been read from disk.")

(defvar straight-overview--fetch nil
  "The pool of the fetch running in the background, or nil.")

(defvar straight-overview--fetch-problems nil
  "Packages whose last fetch did not succeed.
A plist with keys :failed, :timed-out and :credentials, each a list of
package names.  Between the end of the fetch and the credentials round,
:credentials holds `straight-overview--repo' structs.")

(defvar straight-overview--ahead-behind 'unknown
  "Whether git supports the `ahead-behind' format atom (git 2.41+).
The symbol `unknown' until `straight-overview--ahead-behind-p' checks.")

;;; Pins

(defun straight-overview--ensure-pins ()
  "Load pinned packages from `straight-overview-pinned-file' once."
  (unless straight-overview--pins-loaded
    (setq straight-overview--pins
          (when (and straight-overview-pinned-file
                     (file-readable-p straight-overview-pinned-file))
            (with-temp-buffer
              (insert-file-contents straight-overview-pinned-file)
              (ignore-errors (read (current-buffer)))))
          straight-overview--pins-loaded t)))

(defun straight-overview--save-pins ()
  "Persist `straight-overview--pins' to `straight-overview-pinned-file'."
  (when straight-overview-pinned-file
    (with-temp-file straight-overview-pinned-file
      (let ((print-length nil) (print-level nil))
        (prin1 straight-overview--pins (current-buffer))
        (insert "\n")))))

(defun straight-overview--pinned-p (name)
  "Return the pinned commit for package NAME, or nil if not pinned."
  (cdr (assoc name straight-overview--pins)))

;;; Git plumbing

(defun straight-overview--git (dir &rest args)
  "Run git with ARGS in DIR; return trimmed stdout, or nil on failure."
  (when (and dir (file-directory-p dir))
    (condition-case nil
        (let ((default-directory (file-name-as-directory dir)))
          (with-temp-buffer
            (when (eq 0 (apply #'call-process "git" nil t nil args))
              (string-trim (buffer-string)))))
      (error nil))))

(cl-defstruct (straight-overview--pool
               (:constructor straight-overview--make-pool)
               (:copier nil))
  "Git calls run in parallel by `straight-overview--pool-start'.
RESULTS holds one entry per job, in job order; ERRORS holds the output
of the jobs that failed.  PENDING counts the jobs
not yet finished.  TIMED-OUT lists the indices of jobs stopped after
TIMEOUT seconds.  ENV is the `process-environment' the jobs run with."
  queue results errors pending procs width timeout env timed-out
  on-progress on-done)

(cl-defun straight-overview--pool-start (jobs &key width timeout on-progress on-done)
  "Start the git calls JOBS in parallel and return the pool.
Each job is (DIR . ARGS).  At most WIDTH processes run at once (default
`straight-overview-jobs'); a finished process hands its slot to the next
job in the queue.  A process still running after TIMEOUT seconds is stopped and
its job index added to the pool's `timed-out'.  ON-PROGRESS is called
with the pool after each job, ON-DONE once after the last.  Each entry
of the pool's `results' is trimmed stdout, or nil on failure, as from
`straight-overview--git'."
  (let ((pool (straight-overview--make-pool
               :queue (seq-map-indexed (lambda (job i) (cons i job)) jobs)
               :results (make-vector (length jobs) nil)
               :errors (make-vector (length jobs) nil)
               :pending (length jobs)
               :width (max 1 (or width straight-overview-jobs (num-processors)))
               :timeout timeout :env process-environment
               :on-progress on-progress :on-done on-done)))
    (if (zerop (length jobs))
        (when on-done (funcall on-done pool))
      (straight-overview--pool-fill pool))
    pool))

(defun straight-overview--pool-fill (pool)
  "Start queued jobs of POOL until its width is reached."
  (while (and (straight-overview--pool-queue pool)
              (< (length (straight-overview--pool-procs pool))
                 (straight-overview--pool-width pool)))
    (pcase-let ((`(,i ,dir . ,args) (pop (straight-overview--pool-queue pool))))
      (let ((buf (generate-new-buffer " *straight-overview-git*" t)))
        (condition-case nil
            (let* ((default-directory (file-name-as-directory dir))
                   (process-environment (straight-overview--pool-env pool))
                   (proc (make-process
                          :name "straight-overview-git"
                          :buffer buf
                          :command (cons "git" args)
                          :connection-type 'pipe
                          :noquery t
                          :sentinel (lambda (p _event)
                                      (unless (process-live-p p)
                                        (straight-overview--pool-finish pool p)))))
                   (timeout (straight-overview--pool-timeout pool)))
              (process-put proc 'index i)
              (when timeout
                (process-put proc 'timer
                             (run-at-time timeout nil
                                          #'straight-overview--pool-time-out
                                          pool proc)))
              (push proc (straight-overview--pool-procs pool)))
          (error (kill-buffer buf)
                 (straight-overview--pool-job-done pool)))))))

(defun straight-overview--pool-time-out (pool proc)
  "Stop PROC, a process of POOL that ran past the pool's timeout."
  (when (process-live-p proc)
    (process-put proc 'timed-out t)
    (set-process-sentinel proc #'ignore)
    (delete-process proc)
    (straight-overview--pool-finish pool proc)))

(defun straight-overview--pool-finish (pool proc)
  "Record the result of PROC, a finished process of POOL, and start the next job."
  (let ((buf (process-buffer proc))
        (i (process-get proc 'index))
        (timer (process-get proc 'timer)))
    (unwind-protect
        (progn
          (when timer (cancel-timer timer))
          (cond ((process-get proc 'timed-out)
                 (push i (straight-overview--pool-timed-out pool)))
                ((and (eq (process-status proc) 'exit)
                      (eq 0 (process-exit-status proc)))
                 (aset (straight-overview--pool-results pool) i
                       (with-current-buffer buf
                         (string-trim (buffer-string)))))
                (t
                 (aset (straight-overview--pool-errors pool) i
                       (with-current-buffer buf (buffer-string))))))
      (kill-buffer buf)
      (setf (straight-overview--pool-procs pool)
            (delq proc (straight-overview--pool-procs pool)))
      (straight-overview--pool-job-done pool)
      (straight-overview--pool-fill pool))))

(defun straight-overview--pool-job-done (pool)
  "Count one job of POOL as finished and run its callbacks."
  (cl-decf (straight-overview--pool-pending pool))
  (let ((on-progress (straight-overview--pool-on-progress pool))
        (on-done (straight-overview--pool-on-done pool)))
    (when on-progress (funcall on-progress pool))
    (when (and on-done (zerop (straight-overview--pool-pending pool)))
      (funcall on-done pool))))

(defun straight-overview--pool-cancel (pool)
  "Stop POOL: drop its queued jobs and delete its running processes.
Neither callback of POOL runs afterwards."
  (setf (straight-overview--pool-queue pool) nil
        (straight-overview--pool-on-progress pool) nil
        (straight-overview--pool-on-done pool) nil)
  (dolist (proc (straight-overview--pool-procs pool))
    (let ((timer (process-get proc 'timer)))
      (when timer (cancel-timer timer)))
    (set-process-sentinel proc #'ignore)
    (delete-process proc)
    (kill-buffer (process-buffer proc)))
  (setf (straight-overview--pool-procs pool) nil))

(defun straight-overview--git-batch (jobs)
  "Run the git calls JOBS in parallel, wait, and return their results.
JOBS and the results are as for `straight-overview--pool-start'; the
results come back as a list in the order of JOBS."
  (let ((pool (straight-overview--pool-start jobs)))
    (unwind-protect
        (while (> (straight-overview--pool-pending pool) 0)
          (accept-process-output nil 0.05))
      ;; Reached early only on a quit: stop the processes still running.
      (straight-overview--pool-cancel pool))
    (append (straight-overview--pool-results pool) nil)))

(defun straight-overview--ahead-behind-p (dir)
  "Return non-nil if git supports `%(ahead-behind:...)'; run git in DIR.
Checked once per session."
  (when (eq straight-overview--ahead-behind 'unknown)
    (setq straight-overview--ahead-behind
          (let ((v (straight-overview--git dir "--version")))
            (and v (string-match "\\([0-9]+\\.[0-9]+\\)" v)
                 (version<= "2.41" (match-string 1 v))))))
  straight-overview--ahead-behind)

(defun straight-overview--refs-args (remote ahead-behind)
  "Return git arguments listing local branches and branches of REMOTE.
One line per ref: name, hash, commit timestamp, then (with AHEAD-BEHIND)
the ref's commits missing from HEAD, then the checked-out marker."
  (list "for-each-ref"
        (concat "--format=%(refname)%09%(objectname)%09%(committerdate:unix)"
                (if ahead-behind "%09%(ahead-behind:HEAD)" "")
                "%09%(HEAD)")
        "refs/heads" (concat "refs/remotes/" remote)))

(defun straight-overview--parse-refs (out ahead-behind)
  "Parse OUT, the output of `straight-overview--refs-args' with AHEAD-BEHIND.
Each element is (REFNAME HASH TIMESTAMP BEHIND HEAD-P).  BEHIND counts
the ref's commits missing from HEAD; it is nil unless AHEAD-BEHIND."
  (when out
    (mapcar (lambda (line)
              (let ((f (split-string line "\t")))
                ;; The trailing HEAD marker is a space when not checked out,
                ;; and `string-trim' strips it from the last line.
                (list (nth 0 f) (nth 1 f) (nth 2 f)
                      (and ahead-behind (nth 3 f)
                           (string-to-number (nth 3 f)))
                      (equal (nth (if ahead-behind 4 3) f) "*"))))
            (split-string out "\n" t))))

(defun straight-overview--duration (seconds)
  "Format SECONDS as a compact age like \"1y209d\", \"27d\" or \"5h\".
Non-positive SECONDS (the upstream tip is not newer than HEAD, e.g. on a
fork whose HEAD commit post-dates the tracked tip) render as \"<1d\"."
  (let ((d (/ seconds 86400)))
    (cond ((<= seconds 0) "<1d")
          ((>= d 365) (format "%dy%dd" (/ d 365) (% d 365)))
          ((>= d 1) (format "%dd" d))
          (t (format "%dh" (max 1 (/ seconds 3600)))))))

(defun straight-overview--url (recipe)
  "Return a clickable web URL for RECIPE, or nil."
  (let ((repo (plist-get recipe :repo))
        (host (plist-get recipe :host))
        (protocol (plist-get recipe :protocol)))
    (when repo
      (let ((url (ignore-errors
                   (straight-vc-git--encode-url repo host (or protocol 'https)))))
        (when url
          (replace-regexp-in-string "\\.git\\'" "" url))))))

(cl-defstruct (straight-overview--repo
               (:constructor straight-overview--make-repo)
               (:copier nil))
  "Git state of one package, gathered by `straight-overview--collect'.
REFS is parsed `for-each-ref' output, TAG the `describe' output.  HEAD
\(\"HASH\\tTIMESTAMP\" on a detached HEAD) and COUNT (`rev-list --count'
on git before 2.41) are fallbacks, nil when not needed."
  name recipe dir remote refs tag head count)

(defun straight-overview--find-repo (name)
  "Return a `straight-overview--repo' for package NAME, or nil.
nil when the package is not a git clone."
  (let* ((recipe (gethash name straight--recipe-cache))
         (local-repo (plist-get recipe :local-repo))
         (dir (and local-repo (straight--repos-dir local-repo))))
    (when (and dir (file-directory-p dir)
               (file-exists-p (expand-file-name ".git" dir)))
      (straight-overview--make-repo
       :name name :recipe recipe :dir dir
       :remote (or (plist-get recipe :remote) "origin")))))

(defun straight-overview--current (repo)
  "Return REPO's ref row for the checked-out branch, or nil if detached."
  (seq-find (lambda (r) (nth 4 r)) (straight-overview--repo-refs repo)))

(defun straight-overview--branch (repo)
  "Return REPO's recipe `:branch', else its checked-out branch, or nil."
  (or (plist-get (straight-overview--repo-recipe repo) :branch)
      (let ((current (straight-overview--current repo)))
        (and current (string-remove-prefix "refs/heads/" (car current))))))

(defun straight-overview--upstream (repo)
  "Return REPO's upstream as \"REMOTE/BRANCH\", or nil."
  (let ((branch (straight-overview--branch repo)))
    (and branch (format "%s/%s" (straight-overview--repo-remote repo) branch))))

(defun straight-overview--upstream-row (repo)
  "Return REPO's ref row for its upstream, or nil if there is none."
  (let ((upstream (straight-overview--upstream repo)))
    (and upstream
         (assoc (concat "refs/remotes/" upstream)
                (straight-overview--repo-refs repo)))))

(defun straight-overview--fallbacks (repo ahead-behind)
  "Return (SLOT . JOB) pairs for the git calls REPO still needs.
A detached HEAD needs `log -1 HEAD'; git before 2.41 (AHEAD-BEHIND nil)
needs `rev-list --count'.  SLOT names the REPO field for the result."
  (let ((dir (straight-overview--repo-dir repo))
        jobs)
    (unless (straight-overview--current repo)
      (push (cons 'head (list dir "log" "-1" "--format=%H%x09%ct" "HEAD")) jobs))
    (when (and (not ahead-behind) (straight-overview--upstream-row repo))
      (push (cons 'count (list dir "rev-list" "--count"
                               (format "HEAD..%s" (straight-overview--upstream repo))))
            jobs))
    jobs))

(defun straight-overview--record (repo ahead-behind)
  "Build the status plist for REPO from its git output.
AHEAD-BEHIND says whether REPO's refs carry behind counts."
  (let* ((recipe (straight-overview--repo-recipe repo))
         (current (straight-overview--current repo))
         (branch (straight-overview--branch repo))
         (upstream (straight-overview--upstream repo))
         (up (straight-overview--upstream-row repo))
         (head (if current
                   (list (nth 1 current) (nth 2 current))
                 (let ((s (straight-overview--repo-head repo)))
                   (and s (split-string s "\t")))))
         (commit (car head))
         (head-ts (cadr head))
         (installed (if commit (substring commit 0 (min 8 (length commit))) "?"))
         (tag (or (straight-overview--repo-tag repo) ""))
         (url (straight-overview--url recipe))
         (commits (and up
                       (if ahead-behind
                           (nth 3 up)
                         (let ((s (straight-overview--repo-count repo)))
                           (and s (string-to-number s))))))
         (up-ts (nth 2 up))
         (behind-secs (and head-ts up-ts
                           (- (string-to-number up-ts) (string-to-number head-ts))))
         (outdated (and commits (> commits 0)))
         (behind (cond ((null commits) "?")
                       ((zerop commits) "")
                       (t (format "(%d; %s)" commits
                                  (straight-overview--duration (or behind-secs 0)))))))
    (list :name (straight-overview--repo-name repo)
          :dir (straight-overview--repo-dir repo) :branch (or branch "?")
          :remote (straight-overview--repo-remote repo)
          :upstream upstream :url url :installed installed :commit commit
          :tag tag :commits commits :behind behind
          :behind-secs (or behind-secs 0) :outdated outdated)))

(defun straight-overview--collect ()
  "Scan every straight package, returning a sorted list of status plists.
Git runs in two parallel rounds: `for-each-ref' and `describe' for every
package, then the fallback calls that the first round shows are needed."
  (let* ((repos (delq nil (mapcar #'straight-overview--find-repo
                                  (hash-table-keys straight--recipe-cache))))
         (ahead-behind (and repos
                            (straight-overview--ahead-behind-p
                             (straight-overview--repo-dir (car repos)))))
         (round1 (straight-overview--git-batch
                  (mapcan (lambda (repo)
                            (let ((dir (straight-overview--repo-dir repo)))
                              (list (cons dir (straight-overview--refs-args
                                               (straight-overview--repo-remote repo)
                                               ahead-behind))
                                    (list dir "describe" "--tags" "--abbrev=0"))))
                          repos))))
    (cl-loop for repo in repos
             for (refs tag) on round1 by #'cddr
             do (setf (straight-overview--repo-refs repo)
                      (straight-overview--parse-refs refs ahead-behind)
                      (straight-overview--repo-tag repo) tag))
    (let ((fallbacks (mapcan (lambda (repo)
                               (mapcar (lambda (f) (cons repo f))
                                       (straight-overview--fallbacks repo ahead-behind)))
                             repos)))
      (cl-loop for (repo slot . _job) in fallbacks
               for out in (straight-overview--git-batch (mapcar #'cddr fallbacks))
               do (setf (cl-struct-slot-value 'straight-overview--repo slot repo) out)))
    (sort (delq nil (mapcar (lambda (repo)
                              (ignore-errors (straight-overview--record repo ahead-behind)))
                            repos))
          (lambda (a b)
            (string< (plist-get a :name) (plist-get b :name))))))

;;; Rendering

(defun straight-overview--entries ()
  "Build `tabulated-list-entries' from the cached records, honoring the filter."
  (let ((show straight-overview--show))
    (delq nil
          (mapcar
           (lambda (rec)
             (when (or (eq show 'all) (plist-get rec :outdated))
               (let* ((name (plist-get rec :name))
                      (pinned (straight-overview--pinned-p name))
                      (behind (if (plist-get rec :outdated)
                                  (propertize (plist-get rec :behind)
                                              'face 'straight-overview-outdated)
                                (plist-get rec :behind)))
                      ;; "#" is filled in by `straight-overview--print-entry'.
                      (cells (list ""
                                   (if pinned "*" "")
                                   name
                                   (plist-get rec :installed)
                                   (plist-get rec :branch)
                                   behind
                                   (plist-get rec :tag)
                                   (or (plist-get rec :url) ""))))
                 ;; Pinned rows are faded so "outdated but held" reads as parked.
                 (when pinned
                   (setq cells (mapcar (lambda (c) (propertize c 'face 'shadow))
                                       cells)))
                 (list name (apply #'vector cells)))))
           straight-overview--records))))

(defun straight-overview--print-entry (id cols)
  "Print the row ID with COLS, numbering it by its line in the buffer.
Calls `tabulated-list-print-entry' with the \"#\" column filled in.  The
number is computed while printing, so it follows the current sort and
filter, also after a column sort that does not go through
`straight-overview--render'."
  (let ((cols (copy-sequence cols))
        (n (number-to-string (line-number-at-pos))))
    (aset cols 0 (if (straight-overview--pinned-p id)
                     (propertize n 'face 'shadow)
                   n))
    (tabulated-list-print-entry id cols)))

(defun straight-overview--redraw-marks ()
  "Re-apply the mark column and row highlight from `straight-overview--marks'."
  (mapc #'delete-overlay straight-overview--mark-overlays)
  (setq straight-overview--mark-overlays nil)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((marked (let ((id (tabulated-list-get-id)))
                      (and id (gethash id straight-overview--marks)))))
        (tabulated-list-put-tag
         (if marked (propertize "*" 'face 'straight-overview-mark) " "))
        (when marked
          (let ((ov (make-overlay (line-beginning-position)
                                  (min (point-max) (1+ (line-end-position))))))
            (overlay-put ov 'face 'straight-overview-marked)
            (overlay-put ov 'straight-overview-mark t)
            (push ov straight-overview--mark-overlays))))
      (forward-line 1))))

(defun straight-overview--fetch-progress (pool)
  "Return \"N of M repositories done\" for the fetch POOL."
  (let ((total (length (straight-overview--pool-results pool))))
    (format "%d of %d repositories done"
            (- total (straight-overview--pool-pending pool)) total)))

(defun straight-overview--banner-text ()
  "Return the banner: packages behind, the keys to press, and fetch state.
The third line shows the progress while a fetch runs and is blank
otherwise, so the table does not move when a fetch starts or ends.  The
problems of the last fetch are listed only when no fetch is running."
  (let ((n (cl-count-if (lambda (r) (plist-get r :outdated))
                        straight-overview--records))
        (fetch straight-overview--fetch)
        (failed (plist-get straight-overview--fetch-problems :failed))
        (timed-out (plist-get straight-overview--fetch-problems :timed-out))
        (credentials (plist-get straight-overview--fetch-problems :credentials)))
    (concat
     (format "%d %s behind the remote as of the last fetch.\n"
             n (if (= n 1) "package is" "packages are"))
     (substitute-command-keys
      (format "Press \\[straight-overview-fetch] to %s, \
\\[straight-overview-toggle-show] to show %s packages.\n"
              (if fetch "cancel the fetch" "fetch new commits")
              (if (eq straight-overview--show 'all) "only outdated" "all")))
     (if fetch
         (format "Fetching in the background: %s.\n"
                 (straight-overview--fetch-progress fetch))
       (concat
        (when failed
          (format "Last fetch failed for: %s.\n" (string-join failed ", ")))
        (when timed-out
          (format "Last fetch timed out for: %s.\n" (string-join timed-out ", ")))
        (when (and credentials (stringp (car credentials)))
          (format "Last fetch needed credentials for: %s.%s\n"
                  (string-join credentials ", ")
                  (if (bound-and-true-p straight-display-subprocess-prompts)
                      ""
                    "  Set `straight-display-subprocess-prompts' to enter them.")))
        "\n")))))

(defun straight-overview--draw-banner ()
  "Show the banner above the first row.
The banner is an overlay's `before-string', so it is not buffer text:
it survives `tabulated-list-print' and never carries a row id."
  (unless straight-overview--banner
    (setq straight-overview--banner (make-overlay (point-min) (point-min))))
  (move-overlay straight-overview--banner (point-min) (point-min))
  (overlay-put straight-overview--banner 'before-string
               (straight-overview--banner-text)))

(defun straight-overview--update-banner ()
  "Redraw the banner of the overview buffer, if there is one."
  (let ((buf (get-buffer "*straight-overview*")))
    (when buf
      (with-current-buffer buf
        (when (derived-mode-p 'straight-overview-mode)
          (straight-overview--draw-banner))))))

(defun straight-overview--render ()
  "Repaint the list from cached records, preserving marks."
  (setq tabulated-list-entries (straight-overview--entries))
  (tabulated-list-print t)
  (straight-overview--redraw-marks)
  (straight-overview--draw-banner))

(defun straight-overview-refresh ()
  "Recompute package status from local git refs (no fetch)."
  (interactive)
  (message "straight-overview: scanning repositories...")
  (straight-overview--ensure-pins)
  (setq straight-overview--records (straight-overview--collect))
  (straight-overview--render)
  (message "straight-overview: %d package(s), %d outdated"
           (length straight-overview--records)
           (cl-count-if (lambda (r) (plist-get r :outdated))
                        straight-overview--records)))

(defconst straight-overview--credentials-regexp
  (regexp-opt '("could not read Username" "could not read Password"
                "terminal prompts disabled" "Permission denied (publickey"
                "Host key verification failed"))
  "Matches git's and ssh's error output when a fetch needed credentials.
Fetches run in the C locale, so these messages are not translated.")

(defun straight-overview--fetch-start ()
  "Start `git fetch REMOTE' in every straight repository, in the background.
Each repository is fetched once, also when several packages share it.
Unlike `straight-fetch-all', this skips straight's checks of the local
repository (remote URLs, worktree, checked-out branch): a fetch only
updates remote refs.  When the last fetch ends, the overview refreshes."
  (let* ((repos (seq-uniq
                 (delq nil (mapcar #'straight-overview--find-repo
                                   (hash-table-keys straight--recipe-cache)))
                 (lambda (a b)
                   (equal (straight-overview--repo-dir a)
                          (straight-overview--repo-dir b)))))
         ;; No terminal can answer a credential prompt: fail instead of
         ;; wait.  The C locale keeps the error messages untranslated.
         (process-environment (append '("GIT_TERMINAL_PROMPT=0" "LC_ALL=C")
                                      process-environment))
         (pool (straight-overview--pool-start
                (mapcar (lambda (repo)
                          (list (straight-overview--repo-dir repo)
                                "fetch" "--quiet"
                                (straight-overview--repo-remote repo)))
                        repos)
                :width straight-overview-fetch-jobs
                :timeout straight-overview-fetch-timeout
                :on-progress (lambda (_pool) (straight-overview--update-banner))
                :on-done (lambda (pool) (straight-overview--fetch-done repos pool)))))
    (setq straight-overview--fetch
          (and (> (straight-overview--pool-pending pool) 0) pool))
    (straight-overview--update-banner)
    (message "straight-overview: fetching %d repositories in the background..."
             (length repos))))

(defun straight-overview--fetch-done (repos pool)
  "Sort the fetches of POOL that did not succeed, then refresh.
REPOS are the repositories POOL fetched, in job order."
  (setq straight-overview--fetch nil
        straight-overview--fetch-problems
        (cl-loop for repo in repos
                 for out across (straight-overview--pool-results pool)
                 for err across (straight-overview--pool-errors pool)
                 for i from 0
                 if (memq i (straight-overview--pool-timed-out pool))
                 collect (straight-overview--repo-name repo) into timed-out
                 else if (and (null out) err
                              (string-match-p straight-overview--credentials-regexp
                                              err))
                 collect repo into credentials
                 else if (null out)
                 collect (straight-overview--repo-name repo) into failed
                 finally return (list :failed failed :timed-out timed-out
                                      :credentials credentials)))
  ;; From a sentinel, a refresh could start inside another command's scan;
  ;; an idle timer waits until Emacs waits for input.
  (run-with-idle-timer 0 nil #'straight-overview--after-fetch))

(defun straight-overview--prompt-filter (proc string)
  "Insert STRING into PROC's buffer and answer the prompt it ends with.
Username and password prompts are read in the minibuffer, as are ssh's
yes/no questions.  Git and ssh run in the C locale, so their prompts
are in English."
  (with-current-buffer (process-buffer proc)
    (goto-char (point-max))
    (insert string)
    (let ((line (buffer-substring-no-properties (line-beginning-position) (point)))
          (case-fold-search t)
          (inhibit-quit nil))
      (condition-case nil
          (cond
           ((string-match-p "username for .*: *\\'" line)
            (insert "\n")
            (process-send-string proc (concat (read-string line) "\n")))
           ((string-match-p "\\(password\\|passphrase\\).*: *\\'" line)
            (insert "\n")
            (let ((password (read-passwd line)))
              (process-send-string proc (concat password "\n"))
              (clear-string password)))
           ((string-match-p "(yes/no[^)]*)\\? *\\'" line)
            (insert "\n")
            (process-send-string proc (if (yes-or-no-p line) "yes\n" "no\n"))))
        (quit (delete-process proc))))))

(defun straight-overview--fetch-with-prompts (repo)
  "Fetch REPO on a pty, answering its prompts in the minibuffer.
Return non-nil if the fetch succeeded."
  (let* ((default-directory (file-name-as-directory
                             (straight-overview--repo-dir repo)))
         (process-environment (cons "LC_ALL=C" process-environment))
         (buf (generate-new-buffer " *straight-overview-fetch*" t))
         (proc (make-process
                :name "straight-overview-fetch"
                :buffer buf
                :command (list "git" "fetch" "--quiet"
                               (straight-overview--repo-remote repo))
                :connection-type 'pty
                :noquery t
                :filter #'straight-overview--prompt-filter
                :sentinel #'ignore)))
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (and (eq (process-status proc) 'exit)
               (eq 0 (process-exit-status proc))))
      (when (process-live-p proc)
        (delete-process proc))
      (kill-buffer buf))))

(defun straight-overview--after-fetch ()
  "Ask for the credentials the fetch needed, refresh, and report the outcome.
The credentials round runs only when `straight-display-subprocess-prompts'
is non-nil, the option with which straight itself asks for credentials.
The fetches that need credentials then run again one at a time, so their
prompts come one after the other."
  (if (active-minibuffer-window)
      ;; Do not interrupt a minibuffer read; ask once it is done.
      (run-with-idle-timer 1 nil #'straight-overview--after-fetch)
    (let ((credentials (plist-get straight-overview--fetch-problems :credentials)))
      ;; Structs until this round has run; package names afterwards.
      (when (straight-overview--repo-p (car credentials))
        (when (and (bound-and-true-p straight-display-subprocess-prompts)
                   (y-or-n-p
                    (format "%d %s credentials (%s).  Enter them now? "
                            (length credentials)
                            (if (= (length credentials) 1) "fetch needs" "fetches need")
                            (mapconcat #'straight-overview--repo-name credentials ", "))))
          (setq credentials
                (seq-remove #'straight-overview--fetch-with-prompts credentials)))
        (setq straight-overview--fetch-problems
              (plist-put straight-overview--fetch-problems :credentials
                         (mapcar #'straight-overview--repo-name credentials)))))
    (let ((buf (get-buffer "*straight-overview*")))
      (when buf
        (with-current-buffer buf
          (straight-overview-refresh))))
    (let ((n (+ (length (plist-get straight-overview--fetch-problems :failed))
                (length (plist-get straight-overview--fetch-problems :timed-out))
                (length (plist-get straight-overview--fetch-problems :credentials)))))
      (message "straight-overview: fetch done%s"
               (if (> n 0)
                   (format "; %d did not succeed (listed in the overview)" n)
                 "")))))

(defun straight-overview-fetch ()
  "Fetch every package's remote in the background, then refresh.
The fetches run in parallel and Emacs stays usable meanwhile.  While a
fetch is running, this command offers to cancel it."
  (interactive)
  (let ((pool straight-overview--fetch))
    (if (not pool)
        (straight-overview--fetch-start)
      (when (y-or-n-p (format "Fetch running (%s); cancel it? "
                              (straight-overview--fetch-progress pool)))
        (straight-overview--pool-cancel pool)
        (setq straight-overview--fetch nil)
        (straight-overview--update-banner)
        (message "straight-overview: fetch cancelled")))))

(defun straight-overview-toggle-show ()
  "Toggle between showing only outdated packages and all packages."
  (interactive)
  (setq straight-overview--show
        (if (eq straight-overview--show 'all) 'outdated 'all))
  (straight-overview--render)
  (message "Showing %s packages" straight-overview--show))

;;; Marking

(defun straight-overview-mark ()
  "Mark the package at point for update and move to the next line.
Pinned packages cannot be marked."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (cond
     ((null id) nil)
     ((straight-overview--pinned-p id)
      (message "%s is pinned; press F to unpin first" id))
     (t (puthash id t straight-overview--marks))))
  (straight-overview--redraw-marks)
  (forward-line 1))

(defun straight-overview-unmark ()
  "Unmark the package at point and move to the next line."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id (remhash id straight-overview--marks)))
  (straight-overview--redraw-marks)
  (forward-line 1))

(defun straight-overview-unmark-all ()
  "Remove all marks."
  (interactive)
  (clrhash straight-overview--marks)
  (straight-overview--redraw-marks))

(defun straight-overview-mark-outdated ()
  "Mark every outdated package (skipping pinned ones)."
  (interactive)
  (dolist (rec straight-overview--records)
    (when (and (plist-get rec :outdated)
               (not (straight-overview--pinned-p (plist-get rec :name))))
      (puthash (plist-get rec :name) t straight-overview--marks)))
  (straight-overview--redraw-marks))

(defun straight-overview--marked ()
  "Return the list of marked package names."
  (let (names)
    (maphash (lambda (k _v) (push k names)) straight-overview--marks)
    (sort names #'string<)))

;;; Pinning

(defun straight-overview-pin ()
  "Pin the package at point at its current commit, then move to next line.
A pinned package is held: it cannot be marked for update.  The pin
records the currently installed commit so `straight-overview-restore'
can reset to it later."
  (interactive)
  (let ((rec (straight-overview--record-at-point)))
    (when rec
      (let ((name (plist-get rec :name)))
        (setf (alist-get name straight-overview--pins nil nil #'equal)
              (plist-get rec :commit))
        (remhash name straight-overview--marks)
        (straight-overview--save-pins)
        (straight-overview--render))))
  (forward-line 1))

(defun straight-overview-unpin ()
  "Remove the pin on the package at point (\"free\"), then move to next line.
This only updates the pin list; it does not touch the git repository."
  (interactive)
  (let ((rec (straight-overview--record-at-point)))
    (when rec
      (setf (alist-get (plist-get rec :name) straight-overview--pins nil 'remove #'equal)
            nil)
      (straight-overview--save-pins)
      (straight-overview--render)))
  (forward-line 1))

(defun straight-overview--restore-branch (name dir remote)
  "Determine the branch to reattach to for package NAME in DIR (REMOTE).
Prefers the recipe's `:branch', then the current branch, then the
remote's default branch, falling back to \"master\"."
  (let ((recipe (gethash name straight--recipe-cache)))
    (or (plist-get recipe :branch)
        (let ((b (straight-overview--git dir "symbolic-ref" "--short" "HEAD")))
          (and b (not (string-empty-p b)) b))
        (let ((d (straight-overview--git dir "rev-parse" "--abbrev-ref"
                                         (format "%s/HEAD" remote))))
          (and d (string-prefix-p (concat remote "/") d)
               (substring d (1+ (length remote)))))
        "master")))

(defun straight-overview-restore ()
  "Restore the package at point to its pinned commit.
Reattaches to the branch straight tracks and `git reset --hard's it to
the pinned commit (so there is never a detached HEAD; a later pull
fast-forwards the branch normally).  Rebuilds in-session when
`straight-overview-build-on-pull' is non-nil, otherwise straight
rebuilds on the next restart.  A no-op if the package is not pinned."
  (interactive)
  (let* ((rec (straight-overview--record-at-point))
         (name (and rec (plist-get rec :name)))
         (commit (and name (straight-overview--pinned-p name))))
    (cond
     ((null rec) (message "No package at point"))
     ((null commit) (message "%s is not pinned" name))
     ((not (yes-or-no-p
            (format "Reset %s to pinned commit %s (discards local changes)? "
                    name (substring commit 0 (min 7 (length commit))))))
      (message "Aborted"))
     (t
      (let* ((dir (plist-get rec :dir))
             (remote (plist-get rec :remote))
             (branch (straight-overview--restore-branch name dir remote)))
        (message "straight-overview: restoring %s to %s..."
                 name (substring commit 0 (min 7 (length commit))))
        (straight-overview--git dir "checkout" branch)
        (straight-overview--git dir "reset" "--hard" commit)
        (when straight-overview-build-on-pull
          (straight-rebuild-package name))
        (straight-overview-refresh)
        (message "%s restored to %s on %s%s"
                 name (substring commit 0 (min 7 (length commit))) branch
                 (if straight-overview-build-on-pull
                     " (rebuilt)" " (rebuild on next restart)")))))))

;;; Dependencies

(defun straight-overview--find-record (name)
  "Return the status plist for package NAME, or nil."
  (seq-find (lambda (r) (equal (plist-get r :name) name))
            straight-overview--records))

(defun straight-overview--main-file (name dir rev)
  "Return (PATH . TEXT) for package NAME's main file at REV in DIR, or nil.
Prefers NAME-pkg.el, then NAME.el, wherever they sit in the tree."
  (let ((files (split-string (or (straight-overview--git
                                  dir "ls-tree" "-r" "--name-only" rev)
                                 "")
                             "\n" t)))
    (cl-loop for base in (list (concat name "-pkg.el") (concat name ".el"))
             for path = (seq-find (lambda (f) (equal (file-name-nondirectory f) base))
                                  files)
             when path
             return (let ((text (straight-overview--git
                                 dir "show" (format "%s:%s" rev path))))
                      (and text (cons path text))))))

(defun straight-overview--version (string)
  "Return the version list of STRING, a version header, or nil.
nil when STRING is not a version, as for `package-strip-rcs-id'."
  (and (stringp string)
       (ignore-errors (version-to-list (package-strip-rcs-id string)))))

(defun straight-overview--prepare-requires (reqs)
  "Return REQS, read from `Package-Requires', as (PACKAGE MIN-VERSION) lists.
As in `lm-package-requires' and `package-desc-from-define', a bare
PACKAGE or (PACKAGE) requires version 0, and MIN-VERSION becomes a
version list.  Signal an error where package.el does."
  (unless (listp reqs)
    (error "Invalid requirement specifier: %S" reqs))
  (mapcar (lambda (req)
            (pcase req
              ((pred symbolp) (list req '(0)))
              (`(,(and dep (pred symbolp))) (list dep '(0)))
              (`(,(and dep (pred symbolp)) ,(and min (pred stringp)) . ,_)
               (list dep (version-to-list min)))
              (_ (error "Invalid requirement specifier: %S" req))))
          reqs))

(defun straight-overview--package-info (name dir rev)
  "Return the version and requirements of package NAME at REV in DIR.
The value is a plist, or nil when the main file is not found:
:version-string is the `Package-Version' or `Version' header, or the
version in NAME-pkg.el; :version is its version list, (0) when there is
no header (as in `package-vc'), nil when the header is not a version;
:requires lists (PACKAGE MIN-VERSION) from `Package-Requires' or the
`define-package' form; :error is the message when those cannot be read."
  (pcase (straight-overview--main-file name dir rev)
    (`(,path . ,text)
     (with-temp-buffer
       (insert text)
       (goto-char (point-min))
       (let (header reqs err)
         (condition-case e
             (progn
               (if (string-suffix-p "-pkg.el" path)
                   (let ((form (read (current-buffer))))
                     (unless (eq (car-safe form) 'define-package)
                       (error "No `define-package' form in %s" path))
                     (setq header (nth 2 form)
                           reqs (nth 4 form))
                     (when (eq (car-safe reqs) 'quote)
                       (setq reqs (cadr reqs))))
                 (setq header (or (lm-header "package-version") (lm-header "version")))
                 (let ((lines (lm-header-multiline "package-requires")))
                   (when lines
                     (setq reqs (car (read-from-string (string-join lines " ")))))))
               (setq reqs (straight-overview--prepare-requires reqs)))
           (error (setq err (error-message-string e)
                        reqs nil)))
         (list :version (if header (straight-overview--version header) '(0))
               :version-string header
               :requires reqs
               :error err))))))

(defun straight-overview--requires (name)
  "Return the (PACKAGE MIN-VERSION) requirements of NAME at its upstream tip.
Signal an error where package.el would refuse to install NAME: when its
requirements cannot be read, or its version header is not a version."
  (let* ((rec (straight-overview--find-record name))
         (info (straight-overview--package-info
                name (plist-get rec :dir) (or (plist-get rec :upstream) "HEAD"))))
    (cond
     ((plist-get info :error)
      (error "%s" (plist-get info :error)))
     ((and info (null (plist-get info :version)))
      (error "Invalid version header %S" (plist-get info :version-string))))
    (plist-get info :requires)))

(defun straight-overview--unmet (name reqs)
  "Return the requirements in REQS that package NAME would pull without.
REQS is from `straight-overview--requires'.  Each element is
\(PACKAGE MIN-VERSION HAVE), HAVE describing what is installed.  A
dependency in NAME's own repo is read at the upstream tip, any other at
HEAD.  As in `package-vc', a dependency without a version header, or
without a main file, has version 0.  A version header that is not a
version never meets a requirement."
  (let* ((rec (straight-overview--find-record name))
         (dir (plist-get rec :dir))
         (upstream (or (plist-get rec :upstream) "HEAD"))
         unmet)
    (pcase-dolist (`(,dep ,min) reqs)
      (let* ((dep-rec (straight-overview--find-record (symbol-name dep)))
             (dep-dir (plist-get dep-rec :dir))
             (have
              (cond
               (dep-rec
                (let* ((info (straight-overview--package-info
                              (symbol-name dep) dep-dir
                              (if (equal dep-dir dir) upstream "HEAD")))
                       (version (if info (plist-get info :version) '(0)))
                       (header (plist-get info :version-string)))
                  (cond ((null version) (format "invalid version %S" header))
                        ((not (version-list-< version min)) nil)
                        (header (package-version-join version))
                        (t "no version header"))))
               ((package-built-in-p dep min) nil)
               ((eq dep 'emacs) emacs-version)
               ((package-built-in-p dep) "older built-in")
               (t "not installed"))))
        (when have
          (push (list dep min have) unmet))))
    (nreverse unmet)))

(defun straight-overview--pull-order (reqs)
  "Return the package names in REQS, each after the marked packages it needs.
REQS is an alist (NAME . REQUIREMENTS).  NAME needs a marked package
whose repo holds one of NAME's requirements."
  (let ((names (mapcar #'car reqs))
        order visited)
    (cl-labels ((dir (name) (plist-get (straight-overview--find-record name) :dir))
                (visit (name)
                  (unless (member name visited)
                    (push name visited)
                    (let ((dep-dirs (delq nil (mapcar (lambda (req)
                                                        (dir (symbol-name (car req))))
                                                      (cdr (assoc name reqs))))))
                      (dolist (other names)
                        (when (and (not (equal other name))
                                   (member (dir other) dep-dirs))
                          (visit other))))
                    (push name order))))
      (mapc #'visit names))
    (nreverse order)))

;;; Actions

(defun straight-overview--record-at-point ()
  "Return the status plist for the package on the current line."
  (let ((id (tabulated-list-get-id)))
    (and id (seq-find (lambda (r) (equal (plist-get r :name) id))
                      straight-overview--records))))

(defun straight-overview--behind-secs (id)
  "Return the seconds-behind-upstream for package ID (0 if unknown)."
  (let ((rec (seq-find (lambda (r) (equal (plist-get r :name) id))
                       straight-overview--records)))
    (or (and rec (plist-get rec :behind-secs)) 0)))

(defun straight-overview--behind-lessp (a b)
  "Sort predicate for the Behind column: compare entries A and B by time behind."
  (< (straight-overview--behind-secs (car a))
     (straight-overview--behind-secs (car b))))

(defun straight-overview-execute (&optional force)
  "Pull every marked package, optionally rebuilding, then refresh.
Each package is pulled after the marked packages it depends on.  A
package whose `Package-Requires' at the upstream tip names a dependency
that is not installed, or older than required, is skipped with a
warning.  The rules are package.el's: a package whose header package.el
could not read is skipped too.

With prefix argument FORCE, those packages are pulled anyway, each with
a warning naming what was not met."
  (interactive "P")
  (let ((names (straight-overview--marked)))
    (if (null names)
        (message "No packages marked")
      (when (yes-or-no-p
             (format "Pull %d package(s)%s%s? "
                     (length names)
                     (if straight-overview-build-on-pull " and rebuild" "")
                     (if force ", ignoring unmet dependencies" "")))
        (let ((verb (if force "was pulled although" "was not pulled;"))
              reqs (skipped 0))
          (dolist (name names)
            (condition-case err
                (push (cons name (straight-overview--requires name)) reqs)
              (error
               (if force
                   (push (list name) reqs)
                 (cl-incf skipped))
               (display-warning
                'straight-overview
                (format "%s %s its package header cannot be read: %s"
                        name verb (error-message-string err))))))
          (setq reqs (nreverse reqs))
          (dolist (name (straight-overview--pull-order reqs))
            (let ((unmet (straight-overview--unmet name (cdr (assoc name reqs)))))
              (when unmet
                (display-warning
                 'straight-overview
                 (format "%s %s it requires %s"
                         name verb
                         (mapconcat
                          (pcase-lambda (`(,dep ,min ,have))
                            (format "%s %s (installed: %s)"
                                    dep (package-version-join min) have))
                          unmet ", "))))
              (if (and unmet (not force))
                  (cl-incf skipped)
                (message "straight-overview: pulling %s..." name)
                (when (straight-pull-package name)
                  (when straight-overview-build-on-pull
                    (message "straight-overview: rebuilding %s..." name)
                    (straight-rebuild-package name))))))
          (clrhash straight-overview--marks)
          (straight-overview-refresh)
          (message "straight-overview: done%s"
                   (if (zerop skipped) ""
                     (format "; %d skipped, see *Warnings*" skipped))))))))

(defun straight-overview-execute-force ()
  "Pull every marked package, also those whose dependencies are not met.
Like `straight-overview-execute' with a prefix argument."
  (interactive)
  (straight-overview-execute t))

(defun straight-overview-browse ()
  "Open the remote URL of the package at point in a browser."
  (interactive)
  (let* ((rec (straight-overview--record-at-point))
         (url (and rec (plist-get rec :url))))
    (if url (browse-url url) (message "No remote URL for this package"))))

(defun straight-overview--display-log (buffer)
  "Display BUFFER, reusing a visible `straight-overview' log window if any.
Intended as a `magit-display-buffer-function'.  When one of our
previously-opened changelog buffers is currently visible, replace its
window's contents with BUFFER; otherwise pop up a new window (never the
overview window itself).  Returns the window, as magit requires."
  (let ((win (seq-some (lambda (b)
                         (and (buffer-live-p b) (get-buffer-window b 'visible)))
                       straight-overview--log-buffers)))
    (if (window-live-p win)
        (progn (set-window-buffer win buffer) win)
      (display-buffer
       buffer
       '((display-buffer-reuse-window
          display-buffer-pop-up-window
          display-buffer-use-some-window)
         (inhibit-same-window . t))))))

(defun straight-overview--changelog-plain (name dir range)
  "Show RANGE commits for package NAME in DIR as a plain `git log' buffer."
  (let ((log (straight-overview--git dir "log" "--oneline" "--decorate" range)))
    (if (or (null log) (string-empty-p log))
        (message "%s: up to date" name)
      (with-current-buffer (get-buffer-create
                            (format "*straight-overview-log: %s*" name))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Pending commits for %s (%s):\n\n" name range))
          (insert log "\n"))
        (goto-char (point-min))
        (special-mode)
        (pop-to-buffer (current-buffer))))))

(defun straight-overview-changelog ()
  "Show the pending commits (HEAD..upstream) for the package at point.
When Magit is available, open a `magit-log' buffer so each commit is
actionable (RET to inspect it, etc.); otherwise fall back to a plain
`git log --oneline' listing."
  (interactive)
  (let ((rec (straight-overview--record-at-point)))
    (if (or (null rec) (null (plist-get rec :upstream)))
        (message "No upstream to compare against")
      (let* ((name (plist-get rec :name))
             (dir (plist-get rec :dir))
             (range (format "HEAD..%s" (plist-get rec :upstream))))
        (cond
         ((not (and (plist-get rec :commits) (> (plist-get rec :commits) 0)))
          (message "%s: up to date" name))
         ((and straight-overview-changelog-use-magit (require 'magit nil t))
          (let* ((default-directory (file-name-as-directory dir))
                 (magit-display-buffer-function #'straight-overview--display-log)
                 (buf (magit-log-setup-buffer (list range) (list "-n256" "--decorate") nil)))
            (setq straight-overview--log-buffers
                  (cons buf (seq-filter (lambda (b)
                                          (and (buffer-live-p b) (not (eq b buf))))
                                        straight-overview--log-buffers)))))
         (t
          (straight-overview--changelog-plain name dir range)))))))

;;; Mode

(defvar-keymap straight-overview-mode-map
  :doc "Keymap for `straight-overview-mode'."
  "m"   #'straight-overview-mark
  "u"   #'straight-overview-unmark
  "U"   #'straight-overview-unmark-all
  "M"   #'straight-overview-mark-outdated
  "x"   #'straight-overview-execute
  "X"   #'straight-overview-execute-force
  "P"   #'straight-overview-pin
  "F"   #'straight-overview-unpin
  "R"   #'straight-overview-restore
  "c"   #'straight-overview-changelog
  "o"   #'straight-overview-browse
  "RET" #'straight-overview-browse
  "a"   #'straight-overview-toggle-show
  "g"   #'straight-overview-refresh
  "G"   #'straight-overview-fetch)

(define-derived-mode straight-overview-mode tabulated-list-mode "Straight-Overview"
  "Major mode listing straight.el packages and their upstream status."
  (setq tabulated-list-format
        [("#"          4 nil :right-align t)
         ("Pin"        3 nil)
         ("Package"   28 t)
         ("Installed" 10 nil)
         ("Branch"    14 t)
         ("Behind"    18 straight-overview--behind-lessp)
         ("Tag"       14 t)
         ("Remote"     0 nil)])
  (when straight-overview-hl-line
    (hl-line-mode 1))
  (setq tabulated-list-padding 2)
  (setq tabulated-list-printer #'straight-overview--print-entry)
  ;; A fresh cons: `tabulated-list-sort' reverses the order with `setcdr'.
  (setq tabulated-list-sort-key (cons "Package" nil))
  (setq straight-overview--marks (make-hash-table :test #'equal))
  (setq straight-overview--show straight-overview-show)
  (tabulated-list-init-header))

;;;###autoload
(defun straight-overview (&optional fetch)
  "Open an overview of straight.el packages and their upstream status.
With prefix arg FETCH, also start fetching all remotes in the background;
the overview refreshes when the fetch ends."
  (interactive "P")
  (let ((do-fetch (cond (fetch t)
                        ((eq straight-overview-fetch-on-open t) t)
                        ((eq straight-overview-fetch-on-open 'ask)
                         (y-or-n-p "Fetch all remotes? "))
                        (t nil)))
        (buf (get-buffer-create "*straight-overview*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'straight-overview-mode)
        (straight-overview-mode)
        ;; The banner is an overlay on the first row's line, so line numbers
        ;; would number the banner instead of that row.  Turned off here:
        ;; `global-display-line-numbers-mode' turns them on after the mode
        ;; body has run.
        (when (bound-and-true-p display-line-numbers-mode)
          (display-line-numbers-mode -1)))
      (straight-overview-refresh))
    (when (and do-fetch (not straight-overview--fetch))
      (straight-overview--fetch-start))
    ;; Same window by default, but route through `display-buffer' so users can
    ;; redirect placement via `display-buffer-alist' keyed on "*straight-overview*".
    (pop-to-buffer-same-window buf)))

(provide 'straight-overview)
;;; straight-overview.el ends here
