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
;; The list opens instantly from local git refs (no network).  The displayed
;; "behind" figures reflect the last time each remote was fetched; press `G'
;; to run `straight-fetch-all' and refresh against live remotes.
;;
;; Packages are marked dired-style and acted on in a batch:
;;
;;   m   mark for update          x   pull marked (+ rebuild if enabled)
;;   u   unmark                   c   show changelog (HEAD..upstream)
;;   U   unmark all               o / RET  open repo in browser
;;   M   mark all outdated        a   toggle outdated-only / all
;;   g   re-scan (local, no fetch)
;;   G   straight-fetch-all, then re-scan
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

;; Optional integration: `straight-overview-changelog' uses Magit when it is
;; available, but Magit is not a hard dependency.
(declare-function magit-log-setup-buffer "magit-log"
                  (revs args files &optional locked focus))

(defgroup straight-overview nil
  "Overview of straight.el packages and their upstream status."
  :group 'straight)

(defcustom straight-overview-fetch-on-open nil
  "Whether to run `straight-fetch-all' when opening the overview.
nil opens instantly from local refs (press G to fetch later)."
  :type '(choice (const :tag "Never (open instantly; refresh with G)" nil)
                 (const :tag "Ask each time" ask)
                 (const :tag "Always fetch first" t))
  :group 'straight-overview)

(defcustom straight-overview-show 'outdated
  "Which packages to display by default."
  :type '(choice (const :tag "Only outdated" outdated)
                 (const :tag "All" all))
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

(defvar straight-overview--pins nil
  "Alist of (PACKAGE-NAME . COMMIT) for pinned packages.
Loaded from `straight-overview-pinned-file' and the source of truth
for pin state across the session.")
(defvar straight-overview--pins-loaded nil
  "Non-nil once `straight-overview--pins' has been read from disk.")

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

(defun straight-overview--record (name)
  "Compute a status plist for package NAME, or nil if not a git clone."
  (let* ((recipe (gethash name straight--recipe-cache))
         (local-repo (plist-get recipe :local-repo))
         (dir (and local-repo (straight--repos-dir local-repo))))
    (when (and dir (file-directory-p dir)
               (file-exists-p (expand-file-name ".git" dir)))
      (let* ((remote (or (plist-get recipe :remote) "origin"))
             (branch (or (plist-get recipe :branch)
                         (straight-overview--git dir "symbolic-ref" "--short" "HEAD")))
             (upstream (and branch (format "%s/%s" remote branch)))
             ;; One call gets HEAD's full hash and committer timestamp; the
             ;; short hash is just a prefix, no extra `rev-parse'.
             (head (straight-overview--git dir "log" "-1" "--format=%H%x09%ct" "HEAD"))
             (head-parts (and head (split-string head "\t")))
             (commit (car head-parts))
             (head-ts (cadr head-parts))
             (installed (if commit (substring commit 0 (min 8 (length commit))) "?"))
             (tag (or (straight-overview--git dir "describe" "--tags" "--abbrev=0") ""))
             (url (straight-overview--url recipe))
             (count-str (and upstream
                             (straight-overview--git dir "rev-list" "--count"
                                                     (format "HEAD..%s" upstream))))
             (commits (and count-str (string-to-number count-str)))
             (up-ts (and upstream (straight-overview--git dir "log" "-1" "--format=%ct" upstream)))
             (behind-secs (and head-ts up-ts
                               (- (string-to-number up-ts) (string-to-number head-ts))))
             (outdated (and commits (> commits 0)))
             (behind (cond ((null commits) "?")
                           ((zerop commits) "")
                           (t (format "(%d; %s)" commits
                                      (straight-overview--duration (or behind-secs 0)))))))
        (list :name name :dir dir :branch (or branch "?") :remote remote
              :upstream upstream :url url :installed installed :commit commit
              :tag tag :commits commits :behind behind
              :behind-secs (or behind-secs 0) :outdated outdated)))))

(defun straight-overview--collect ()
  "Scan every straight package, returning a sorted list of status plists."
  (let (records)
    (dolist (name (hash-table-keys straight--recipe-cache))
      (let ((rec (ignore-errors (straight-overview--record name))))
        (when rec (push rec records))))
    (sort records (lambda (a b)
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
                      (cells (list (if pinned "*" "")
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

(defun straight-overview--render ()
  "Repaint the list from cached records, preserving marks."
  (setq tabulated-list-entries (straight-overview--entries))
  (tabulated-list-print t)
  (straight-overview--redraw-marks))

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

(defun straight-overview-fetch ()
  "Fetch all remotes via `straight-fetch-all', then refresh."
  (interactive)
  (message "straight-overview: fetching all remotes (this blocks)...")
  (straight-fetch-all)
  (straight-overview-refresh))

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

(defun straight-overview-execute ()
  "Pull every marked package, optionally rebuilding, then refresh."
  (interactive)
  (let ((names (straight-overview--marked)))
    (if (null names)
        (message "No packages marked")
      (when (yes-or-no-p
             (format "Pull %d package(s)%s? "
                     (length names)
                     (if straight-overview-build-on-pull " and rebuild" "")))
        (dolist (name names)
          (message "straight-overview: pulling %s..." name)
          (when (straight-pull-package name)
            (when straight-overview-build-on-pull
              (message "straight-overview: rebuilding %s..." name)
              (straight-rebuild-package name))))
        (clrhash straight-overview--marks)
        (straight-overview-refresh)
        (message "straight-overview: done")))))

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
        [("Pin"        3 nil)
         ("Package"   28 t)
         ("Installed" 10 nil)
         ("Branch"    14 t)
         ("Behind"    18 straight-overview--behind-lessp)
         ("Tag"       14 t)
         ("Remote"     0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Package" . nil))
  (setq straight-overview--marks (make-hash-table :test #'equal))
  (setq straight-overview--show straight-overview-show)
  (tabulated-list-init-header))

;;;###autoload
(defun straight-overview (&optional fetch)
  "Open an overview of straight.el packages and their upstream status.
With prefix arg FETCH, run `straight-fetch-all' before displaying."
  (interactive "P")
  (let ((do-fetch (cond (fetch t)
                        ((eq straight-overview-fetch-on-open t) t)
                        ((eq straight-overview-fetch-on-open 'ask)
                         (y-or-n-p "Fetch all remotes first? "))
                        (t nil)))
        (buf (get-buffer-create "*straight-overview*")))
    (when do-fetch
      (message "straight-overview: fetching all remotes (this blocks)...")
      (straight-fetch-all))
    (with-current-buffer buf
      (unless (derived-mode-p 'straight-overview-mode)
        (straight-overview-mode))
      (straight-overview-refresh))
    ;; Same window by default, but route through `display-buffer' so users can
    ;; redirect placement via `display-buffer-alist' keyed on "*straight-overview*".
    (pop-to-buffer-same-window buf)))

(provide 'straight-overview)
;;; straight-overview.el ends here
