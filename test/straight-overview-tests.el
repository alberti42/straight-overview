;;; straight-overview-tests.el --- Tests for straight-overview -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
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
;; ERT tests.  Run from the repository root with `make test', or:
;;
;;   emacs --batch -Q -L . -l test/straight-overview-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Each test that needs packages creates them in a temporary directory:
;; an upstream repository per package and its clone under repos/, which
;; `straight--repos-dir' is made to return.  straight.el is stubbed when
;; it is not on the `load-path'; its commands are mocked where called.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(unless (require 'straight nil t)
  (defvar straight--recipe-cache (make-hash-table :test #'equal))
  (defvar straight-display-subprocess-prompts nil)
  (defvar straight-hosts '((github :https "https://github.com/user/repo.git")))
  (defun straight--host-spec (host)
    (alist-get host straight-hosts))
  (defun straight--repos-dir (&rest segments)
    (apply #'file-name-concat temporary-file-directory segments))
  (defun straight-vc-git--encode-url (repo host &optional _protocol)
    (format "https://%s.com/%s.git" host repo))
  (defun straight-pull-package (_package &optional _from-upstream) nil)
  (defun straight-rebuild-package (_package &optional _recursive) nil)
  (provide 'straight))

(require 'straight-overview)

;;; Fixtures

(defvar so-test--root nil
  "Temporary directory of the running test.")

(defconst so-test--time 1700000000
  "Commit time of a package's first commit, in seconds since the epoch.")

(defmacro so-test-with-env (&rest body)
  "Run BODY with an empty recipe cache and a fresh temporary directory.
Git runs without the user's configuration.  The package's global state
is let-bound, so the session is left as it was."
  (declare (indent 0) (debug t))
  `(let* ((so-test--root (file-name-as-directory
                          (file-truename
                           (make-temp-file "straight-overview-test" t))))
          (process-environment
           (append (list "GIT_CONFIG_NOSYSTEM=1"
                         (concat "GIT_CONFIG_GLOBAL=" null-device)
                         "GIT_AUTHOR_NAME=Test"
                         "GIT_AUTHOR_EMAIL=test@example.com"
                         "GIT_COMMITTER_NAME=Test"
                         "GIT_COMMITTER_EMAIL=test@example.com"
                         "GIT_TERMINAL_PROMPT=0")
                   process-environment))
          (straight--recipe-cache (make-hash-table :test #'equal))
          (straight-overview--ahead-behind 'unknown)
          (straight-overview--pins nil)
          (straight-overview--pins-loaded t)
          (straight-overview-pinned-file nil)
          (straight-overview--fetch nil)
          (straight-overview--fetch-problems nil)
          (straight-overview--log-buffers nil)
          (straight-overview-build-on-pull nil)
          (straight-overview-fetch-on-open nil)
          (straight-overview-show 'outdated)
          (straight-overview-changelog-use-magit nil))
     (unwind-protect
         (cl-letf (((symbol-function 'straight--repos-dir)
                    (lambda (&rest segments)
                      (expand-file-name (apply #'file-name-concat "repos" segments)
                                        so-test--root)))
                   ((symbol-function 'straight-vc-git--encode-url)
                    (lambda (repo host &optional _protocol)
                      (format "https://%s.com/%s.git" host repo))))
           ,@body)
       (dolist (name '("*straight-overview*" "*straight-overview-log: alpha*"))
         (when (get-buffer name) (kill-buffer name)))
       (delete-directory so-test--root t))))

(defun so-test--git (dir &rest args)
  "Run git with ARGS in DIR; return trimmed stdout, or signal an error."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (eq 0 (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun so-test--commit (dir files &optional time)
  "Write FILES, an alist (PATH . CONTENT), in DIR and commit them.
TIME is the commit time in seconds since the epoch, by default
`so-test--time'.  Return the commit's hash."
  (pcase-dolist (`(,path . ,content) files)
    (let ((file (expand-file-name path dir)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert content))))
  (let* ((date (format "@%d +0000" (or time so-test--time)))
         (process-environment (append (list (concat "GIT_AUTHOR_DATE=" date)
                                            (concat "GIT_COMMITTER_DATE=" date))
                                      process-environment)))
    (so-test--git dir "add" "-A")
    (so-test--git dir "commit" "-q" "--allow-empty" "-m" "commit")
    (so-test--git dir "rev-parse" "HEAD")))

(defun so-test--header (name version &optional requires)
  "Return the text of NAME.el declaring VERSION and REQUIRES.
VERSION or REQUIRES nil leaves that header out."
  (concat ";;; " name ".el --- Test package  -*- lexical-binding: t; -*-\n"
          (if version (format ";; Version: %s\n" version) "")
          (if requires (format ";; Package-Requires: %s\n" requires) "")
          ";;; Code:\n(provide '" name ")\n"))

(defun so-test--upstream (repo)
  "Return the directory of the upstream repository REPO."
  (expand-file-name (concat "upstream/" repo) so-test--root))

(cl-defun so-test--package (name &key files repo recipe)
  "Create package NAME and return its clone's directory.
The package lives in REPO, default NAME.  When REPO does not exist yet,
it is created upstream with FILES as its first commit (default NAME.el
version 1.0) and cloned under repos/.  RECIPE is prepended to the
package's recipe."
  (let* ((repo (or repo name))
         (upstream (so-test--upstream repo))
         (clone (straight--repos-dir repo)))
    (unless (file-directory-p upstream)
      (make-directory upstream t)
      (so-test--git upstream "init" "-q" "-b" "main")
      (so-test--commit upstream (or files
                                    (list (cons (concat name ".el")
                                                (so-test--header name "1.0")))))
      (so-test--git so-test--root "clone" "-q" upstream clone))
    (puthash name (append recipe
                          (list :package name :type 'git :host 'github
                                :repo (concat "user/" repo) :local-repo repo))
             straight--recipe-cache)
    clone))

(defun so-test--advance (repo n &optional files time)
  "Add N commits upstream to REPO, then fetch them into its clone.
The first commit writes FILES.  Commits are made at TIME, default three
days after `so-test--time'."
  (let ((upstream (so-test--upstream repo))
        (time (or time (+ so-test--time (* 3 86400)))))
    (so-test--commit upstream files time)
    (dotimes (i (1- n))
      (so-test--commit upstream (list (cons (format "file-%d" i) "x")) time))
    (so-test--git (straight--repos-dir repo) "fetch" "-q" "origin")))

(defun so-test--head (repo)
  "Return the hash of HEAD in REPO's clone."
  (so-test--git (straight--repos-dir repo) "rev-parse" "HEAD"))

(defun so-test--record (name)
  "Return the record of package NAME in the current buffer."
  (straight-overview--find-record name))

(defun so-test--open ()
  "Open the overview and return its buffer."
  (save-window-excursion (straight-overview))
  (get-buffer "*straight-overview*"))

(defun so-test--goto (id)
  "Move point to the row of package ID; return non-nil if found."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
    (forward-line 1))
  (equal (tabulated-list-get-id) id))

(defun so-test--ids ()
  "Return the package names of the rows, top to bottom."
  (save-excursion
    (goto-char (point-min))
    (let (ids)
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (when id (push id ids)))
        (forward-line 1))
      (nreverse ids))))

(defun so-test--wait (pool)
  "Wait until POOL has no pending jobs, for at most ten seconds."
  (with-timeout (10 (error "Pool did not finish"))
    (while (> (straight-overview--pool-pending pool) 0)
      (accept-process-output nil 0.05))))

;;; Pure helpers

(ert-deftest straight-overview-test-duration ()
  (should (equal (straight-overview--duration 0) "<1d"))
  (should (equal (straight-overview--duration -100) "<1d"))
  (should (equal (straight-overview--duration 60) "1h"))
  (should (equal (straight-overview--duration (* 5 3600)) "5h"))
  (should (equal (straight-overview--duration (* 27 86400)) "27d"))
  (should (equal (straight-overview--duration (* 574 86400)) "1y209d")))

(ert-deftest straight-overview-test-refs-args ()
  (should (equal (straight-overview--refs-args "origin" nil)
                 '("for-each-ref"
                   "--format=%(refname)%09%(objectname)%09%(committerdate:unix)%09%(HEAD)"
                   "refs/heads" "refs/remotes/origin")))
  (should (equal (nth 1 (straight-overview--refs-args "up" t))
                 "--format=%(refname)%09%(objectname)%09%(committerdate:unix)%09%(ahead-behind:HEAD)%09%(HEAD)"))
  (should (equal (nth 3 (straight-overview--refs-args "up" t)) "refs/remotes/up")))

(ert-deftest straight-overview-test-parse-refs ()
  (should-not (straight-overview--parse-refs nil t))
  ;; The last line's HEAD marker (a space) is gone after `string-trim'.
  (should (equal (straight-overview--parse-refs
                  "refs/heads/main\tabc\t100\t0 0\t*\nrefs/remotes/origin/main\tdef\t200\t3 0"
                  t)
                 '(("refs/heads/main" "abc" "100" 0 t)
                   ("refs/remotes/origin/main" "def" "200" 3 nil))))
  (should (equal (straight-overview--parse-refs
                  "refs/heads/dev\tabc\t100\t \nrefs/heads/main\tdef\t200\t*\nrefs/remotes/origin/main\tghi\t300"
                  nil)
                 '(("refs/heads/dev" "abc" "100" nil nil)
                   ("refs/heads/main" "def" "200" nil t)
                   ("refs/remotes/origin/main" "ghi" "300" nil nil)))))

(ert-deftest straight-overview-test-url ()
  (let ((straight-hosts '((github :https "https://github.com/user/repo.git")
                          (sshonly :ssh "git@example.com:user/repo.git"))))
    (cl-letf (((symbol-function 'straight--host-spec)
               (lambda (host) (alist-get host straight-hosts)))
              ((symbol-function 'straight-vc-git--encode-url)
               (lambda (repo host &optional protocol)
                 (should (eq protocol 'https))
                 (string-replace "user/repo" repo
                                 (plist-get (alist-get host straight-hosts)
                                            :https)))))
      (should (equal (straight-overview--url '(:repo "u/p" :host github))
                     "https://github.com/u/p"))
      ;; A browser cannot open the ssh URL the recipe clones from.
      (should (equal (straight-overview--url '(:repo "u/p" :host github :protocol ssh))
                     "https://github.com/u/p"))
      (should (equal (straight-overview--url '(:repo "https://example.com/u/p.git"))
                     "https://example.com/u/p"))
      (should-not (straight-overview--url '(:repo "git@example.com:u/p.git")))
      (should-not (straight-overview--url '(:host github)))
      ;; Where `straight-vc-git--encode-url' would signal an error.
      (should-not (straight-overview--url '(:repo "u/p" :host nowhere)))
      (should-not (straight-overview--url '(:repo "u/p" :host sshonly)))
      (should-not (straight-overview--url '(:repo "https://github.com/u/p"
                                              :host github))))))

(ert-deftest straight-overview-test-version ()
  (should (equal (straight-overview--version "1.2.3") '(1 2 3)))
  (should (equal (straight-overview--version "1.0snapshot") '(1 0 -4)))
  ;; `package-strip-rcs-id' accepts the first, not the second.
  (should (equal (straight-overview--version "$Revision: 1.4") '(1 4)))
  (should-not (straight-overview--version "$Revision: 1.4 $"))
  (should-not (straight-overview--version "x.y"))
  (should-not (straight-overview--version nil))
  (should-not (straight-overview--version '(1 2))))

(ert-deftest straight-overview-test-prepare-requires ()
  ;; The rules of `lm-package-requires' and `package-desc-from-define'.
  (should (equal (straight-overview--prepare-requires
                  '((emacs "29.1") bare (empty) (foo "1.0" extra)))
                 '((emacs (29 1)) (bare (0)) (empty (0)) (foo (1 0)))))
  (should-not (straight-overview--prepare-requires nil))
  (dolist (bad '(foo ("foo") ((foo "x.y")) ((foo 1)) (("foo" "1.0"))))
    (should-error (straight-overview--prepare-requires bad))))

(ert-deftest straight-overview-test-behind-lessp ()
  (with-temp-buffer
    (setq-local straight-overview--records
                '((:name "a" :behind-secs 10) (:name "b" :behind-secs 500)))
    (should (straight-overview--behind-lessp '("a") '("b")))
    (should-not (straight-overview--behind-lessp '("b") '("a")))
    ;; An unknown package counts as 0.
    (should (straight-overview--behind-lessp '("zzz") '("a")))))

;;; Pins

(ert-deftest straight-overview-test-pins-file ()
  (so-test-with-env
    (let ((straight-overview-pinned-file (expand-file-name "pins.eld" so-test--root)))
      (setq straight-overview--pins '(("alpha" . "abc123")))
      (straight-overview--save-pins)
      (setq straight-overview--pins nil
            straight-overview--pins-loaded nil)
      (straight-overview--ensure-pins)
      (should (equal straight-overview--pins '(("alpha" . "abc123"))))
      (should (equal (straight-overview--pinned-p "alpha") "abc123"))
      (should-not (straight-overview--pinned-p "beta"))
      ;; Loaded once: a later change to the file is not read.
      (with-temp-file straight-overview-pinned-file (insert "((\"beta\" . \"def\"))"))
      (straight-overview--ensure-pins)
      (should (equal straight-overview--pins '(("alpha" . "abc123")))))))

(ert-deftest straight-overview-test-pins-invalid-file ()
  (so-test-with-env
    (let ((file (expand-file-name "pins.eld" so-test--root))
          warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        ;; Empty: no pins, no warning.
        (with-temp-file file)
        (should-not (straight-overview--read-pins file))
        (should-not warnings)
        (dolist (text '("((\"alpha\" . " "alpha" "(\"alpha\")"))
          (with-temp-file file (insert text))
          (should-not (straight-overview--read-pins file)))
        (should (= (length warnings) 3))
        (should (string-match-p "does not hold a list of (PACKAGE \\. COMMIT)"
                                (car warnings)))))))

(ert-deftest straight-overview-test-pins-no-file ()
  (so-test-with-env
    (let ((straight-overview-pinned-file (expand-file-name "missing.eld" so-test--root)))
      (setq straight-overview--pins-loaded nil)
      (straight-overview--ensure-pins)
      (should-not straight-overview--pins)
      (should straight-overview--pins-loaded))
    ;; With no file, saving writes nothing.
    (setq straight-overview--pins '(("alpha" . "abc")))
    (straight-overview--save-pins)
    (should-not (directory-files so-test--root nil "\\.eld\\'"))))

;;; Process pool

(ert-deftest straight-overview-test-git ()
  (so-test-with-env
    (should (string-prefix-p "git version" (straight-overview--git so-test--root "--version")))
    (should-not (straight-overview--git so-test--root "no-such-command"))
    (should-not (straight-overview--git (expand-file-name "missing" so-test--root) "--version"))
    (should-not (straight-overview--git nil "--version"))))

(ert-deftest straight-overview-test-git-batch ()
  (so-test-with-env
    (let ((results (straight-overview--git-batch
                    (list (list so-test--root "--version")
                          (list so-test--root "no-such-command")
                          (list so-test--root "-c" "alias.say=!echo hello" "say")))))
      (should (= (length results) 3))
      (should (string-prefix-p "git version" (nth 0 results)))
      (should-not (nth 1 results))
      (should (equal (nth 2 results) "hello")))
    (should-not (straight-overview--git-batch nil))))

(ert-deftest straight-overview-test-pool-width-and-callbacks ()
  (so-test-with-env
    (let* ((progress 0) (done 0)
           (pool (straight-overview--pool-start
                  (make-list 5 (list so-test--root "--version"))
                  :width 2
                  :on-progress (lambda (_) (cl-incf progress))
                  :on-done (lambda (_) (cl-incf done)))))
      (should (= (length (straight-overview--pool-procs pool)) 2))
      (should (= (length (straight-overview--pool-queue pool)) 3))
      (so-test--wait pool)
      (should (= progress 5))
      (should (= done 1))
      (should (cl-every #'stringp (straight-overview--pool-results pool)))
      (should-not (straight-overview--pool-procs pool)))))

(ert-deftest straight-overview-test-pool-empty ()
  (let* ((done nil)
         (pool (straight-overview--pool-start nil :on-done (lambda (_) (setq done t)))))
    (should done)
    (should (= (straight-overview--pool-pending pool) 0))))

(ert-deftest straight-overview-test-pool-errors ()
  (so-test-with-env
    (let ((pool (straight-overview--pool-start
                 (list (list so-test--root "no-such-command")
                       (list (expand-file-name "missing" so-test--root) "--version")))))
      (so-test--wait pool)
      (should (equal (append (straight-overview--pool-results pool) nil) '(nil nil)))
      (should (string-match-p "no-such-command"
                              (aref (straight-overview--pool-errors pool) 0))))))

(ert-deftest straight-overview-test-pool-timeout ()
  (so-test-with-env
    (let* ((start (float-time))
           (pool (straight-overview--pool-start
                  (list (list so-test--root "-c" "alias.slow=!sleep 5" "slow")
                        (list so-test--root "--version"))
                  :timeout 0.3)))
      (so-test--wait pool)
      (should (< (- (float-time) start) 4))
      (should (equal (straight-overview--pool-timed-out pool) '(0)))
      (should-not (aref (straight-overview--pool-results pool) 0))
      (should (aref (straight-overview--pool-results pool) 1)))))

(ert-deftest straight-overview-test-pool-cancel ()
  (so-test-with-env
    (let* ((done nil)
           (pool (straight-overview--pool-start
                  (make-list 3 (list so-test--root "-c" "alias.slow=!sleep 5" "slow"))
                  :width 2 :on-done (lambda (_) (setq done t))))
           (procs (straight-overview--pool-procs pool)))
      (straight-overview--pool-cancel pool)
      (should-not (straight-overview--pool-procs pool))
      (should-not (straight-overview--pool-queue pool))
      (should-not (seq-some #'process-live-p procs))
      (accept-process-output nil 0.2)
      (should-not done))))

(ert-deftest straight-overview-test-pool-environment ()
  ;; The second job starts from a sentinel, outside the `let' below.
  (so-test-with-env
    (let ((pool (let ((process-environment (cons "SO_TEST_VAR=captured"
                                                 process-environment)))
                  (straight-overview--pool-start
                   (make-list 2 (list so-test--root "-c"
                                      "alias.env=!printenv SO_TEST_VAR" "env"))
                   :width 1))))
      (so-test--wait pool)
      (should (equal (append (straight-overview--pool-results pool) nil)
                     '("captured" "captured"))))))

(ert-deftest straight-overview-test-ahead-behind-p ()
  (so-test-with-env
    (let* ((v (so-test--git so-test--root "--version"))
           (expected (progn (string-match "\\([0-9]+\\.[0-9]+\\)" v)
                            (version<= "2.41" (match-string 1 v)))))
      (should (eq (and (straight-overview--ahead-behind-p so-test--root) t) expected))
      ;; Cached: a second call does not run git.
      (should (eq (and (straight-overview--ahead-behind-p nil) t) expected)))))

;;; Scan

(ert-deftest straight-overview-test-collect ()
  (so-test-with-env
    (let ((alpha (so-test--package "alpha")))
      (so-test--git alpha "tag" "v1.0")
      (so-test--advance "alpha" 2)
      (so-test--package "beta")
      ;; Not git clones: skipped.
      (puthash "builtin" '(:package "builtin" :type built-in) straight--recipe-cache)
      (make-directory (straight--repos-dir "plain") t)
      (puthash "plain" '(:package "plain" :local-repo "plain") straight--recipe-cache)
      (dolist (ahead-behind (delete-dups
                             (list nil (and (straight-overview--ahead-behind-p
                                             so-test--root)
                                            t))))
        (let* ((straight-overview--ahead-behind ahead-behind)
               (records (straight-overview--collect))
               (a (car records))
               (b (cadr records)))
          (should (equal (mapcar (lambda (r) (plist-get r :name)) records)
                         '("alpha" "beta")))
          (should (equal (plist-get a :commits) 2))
          (should (equal (plist-get a :behind) "(2; 3d)"))
          (should (equal (plist-get a :behind-secs) (* 3 86400)))
          (should (plist-get a :outdated))
          (should (equal (plist-get a :branch) "main"))
          (should (equal (plist-get a :upstream) "origin/main"))
          (should (equal (plist-get a :tag) "v1.0"))
          (should (equal (plist-get a :commit) (so-test--head "alpha")))
          (should (equal (plist-get a :installed) (substring (so-test--head "alpha") 0 8)))
          (should (equal (plist-get a :url) "https://github.com/user/alpha"))
          (should (equal (plist-get a :dir) alpha))
          (should (equal (plist-get b :commits) 0))
          (should (equal (plist-get b :behind) ""))
          (should-not (plist-get b :outdated))
          (should (equal (plist-get b :tag) "")))))))

(ert-deftest straight-overview-test-collect-detached ()
  (so-test-with-env
    (let ((alpha (so-test--package "alpha"))
          (beta (so-test--package "beta" :recipe '(:branch "main"))))
      (so-test--advance "alpha" 1)
      (so-test--advance "beta" 1)
      (so-test--git alpha "checkout" "-q" "--detach")
      (so-test--git beta "checkout" "-q" "--detach")
      (let* ((records (straight-overview--collect))
             (a (car records))
             (b (cadr records)))
        ;; No branch to compare with.
        (should (equal (plist-get a :branch) "?"))
        (should (equal (plist-get a :behind) "?"))
        (should (equal (plist-get a :commit) (so-test--head "alpha")))
        ;; The recipe's branch is compared with.
        (should (equal (plist-get b :branch) "main"))
        (should (equal (plist-get b :commits) 1))
        (should (equal (plist-get b :commit) (so-test--head "beta")))))))

(ert-deftest straight-overview-test-collect-shared-repo ()
  (so-test-with-env
    (so-test--package "suite")
    (so-test--package "suite-core" :repo "suite")
    (so-test--advance "suite" 1)
    (let ((records (straight-overview--collect)))
      (should (equal (mapcar (lambda (r) (plist-get r :name)) records)
                     '("suite" "suite-core")))
      (should (equal (plist-get (car records) :dir) (plist-get (cadr records) :dir)))
      (should (cl-every (lambda (r) (equal (plist-get r :commits) 1)) records)))))

;;; Dependencies

(ert-deftest straight-overview-test-package-info-header ()
  (so-test-with-env
    (let ((dir (so-test--package
                "alpha"
                :files `(("alpha.el" . ,(so-test--header
                                         "alpha" "1.2"
                                         "((emacs \"29.1\") (foo \"1.0\") bare (empty))")))))
          (multi (so-test--package
                  "multi"
                  :files '(("lisp/multi.el" . ";;; multi.el --- Test\n;; Package-Version: 3.0\n;; Version: 2.0\n;; Package-Requires: ((emacs \"28.1\")\n;;                    (dash \"2.19\"))\n;;; Code:\n")))))
      (should (equal (straight-overview--package-info "alpha" dir "HEAD")
                     '(:version (1 2) :version-string "1.2"
                       :requires ((emacs (29 1)) (foo (1 0)) (bare (0)) (empty (0)))
                       :error nil)))
      ;; Package-Version wins over Version, as in `lm-package-version'.
      (should (equal (straight-overview--package-info "multi" multi "HEAD")
                     '(:version (3 0) :version-string "3.0"
                       :requires ((emacs (28 1)) (dash (2 19)))
                       :error nil)))
      (should-not (straight-overview--package-info "missing" dir "HEAD"))
      (should-not (straight-overview--package-info "alpha" dir "no-such-rev")))))

(ert-deftest straight-overview-test-package-info-invalid ()
  (so-test-with-env
    (dolist (case '(("bad-version" "x.y" "((emacs \"29.1\"))" nil)
                    ("bad-min" "1.0" "((foo \"x.y\"))" t)
                    ("bad-string" "1.0" "(\"foo\")" t)
                    ("bad-form" "1.0" "foo" t)
                    ("bad-read" "1.0" "((foo \"1.0\")" t)))
      (pcase-let* ((`(,name ,version ,requires ,error) case)
                   (dir (so-test--package
                         name :files `((,(concat name ".el")
                                        . ,(so-test--header name version requires)))))
                   (info (straight-overview--package-info name dir "HEAD")))
        (should (equal (plist-get info :version-string) version))
        (should (eq (and (plist-get info :error) t) error))
        (when error (should-not (plist-get info :requires)))))
    (should-not (plist-get (straight-overview--package-info
                            "bad-version" (straight--repos-dir "bad-version") "HEAD")
                           :version))))

(ert-deftest straight-overview-test-package-info-pkg-file ()
  (so-test-with-env
    (let ((dir (so-test--package
                "alpha"
                :files `(("alpha.el" . ,(so-test--header "alpha" "1.0" "((emacs \"24.1\"))"))
                         ("alpha-pkg.el" . "(define-package \"alpha\" \"2.0\" \"Doc.\"\n  '((emacs \"28.1\") (seq \"2.24\")))\n"))))
          (bad (so-test--package
                "bad" :files '(("bad-pkg.el" . "(provide 'bad)\n")))))
      (should (equal (straight-overview--package-info "alpha" dir "HEAD")
                     '(:version (2 0) :version-string "2.0"
                       :requires ((emacs (28 1)) (seq (2 24))) :error nil)))
      (should (string-match-p "define-package"
                              (plist-get (straight-overview--package-info "bad" bad "HEAD")
                                         :error))))))

(ert-deftest straight-overview-test-package-info-no-version ()
  ;; As in `package-vc': no version header is version 0.
  (so-test-with-env
    (let ((dir (so-test--package
                "alpha" :files `(("alpha.el" . ,(so-test--header "alpha" nil))))))
      (should (equal (straight-overview--package-info "alpha" dir "HEAD")
                     '(:version (0) :version-string nil :requires nil :error nil))))))

(ert-deftest straight-overview-test-package-info-at-rev ()
  (so-test-with-env
    (let ((dir (so-test--package "alpha")))
      (so-test--advance "alpha" 1 `(("alpha.el" . ,(so-test--header "alpha" "2.0"))))
      (should (equal (plist-get (straight-overview--package-info "alpha" dir "HEAD")
                                :version)
                     '(1 0)))
      (should (equal (plist-get (straight-overview--package-info "alpha" dir "origin/main")
                                :version)
                     '(2 0))))))

(defun so-test--deps-fixture ()
  "Create lib (1.0, upstream 2.0) and app (upstream requires lib 2.0)."
  (so-test--package "lib")
  (so-test--advance "lib" 1 `(("lib.el" . ,(so-test--header "lib" "2.0"))))
  (so-test--package "app" :files `(("app.el" . ,(so-test--header
                                                 "app" "1.0" "((lib \"1.0\"))"))))
  (so-test--advance "app" 1 `(("app.el" . ,(so-test--header
                                            "app" "1.1"
                                            "((emacs \"24.1\") (cl-lib \"0.5\") (lib \"2.0\"))")))))

(ert-deftest straight-overview-test-requires-and-unmet ()
  (so-test-with-env
    (so-test--deps-fixture)
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      ;; Read at the upstream tip.
      (should (equal (straight-overview--requires "app")
                     '((emacs (24 1)) (cl-lib (0 5)) (lib (2 0)))))
      ;; lib is read at HEAD.
      (should (equal (straight-overview--unmet "app" (straight-overview--requires "app"))
                     '((lib (2 0) "1.0"))))
      (should-not (straight-overview--unmet "app" '((lib (1 0)))))
      (should (equal (straight-overview--unmet
                      "app" '((emacs (999)) (cl-lib (99)) (no-such-package (1))))
                     `((emacs (999) ,emacs-version)
                       (cl-lib (99) "older built-in")
                       (no-such-package (1) "not installed")))))))

(ert-deftest straight-overview-test-unmet-no-version ()
  ;; As in `package-vc': no version header, or no main file, is version 0.
  (so-test-with-env
    (so-test--package "lib" :files `(("lib.el" . ,(so-test--header "lib" nil))))
    (so-test--package "nofile" :files '(("README" . "x")))
    (so-test--package "app")
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      (should (equal (straight-overview--unmet "app" '((lib (5 0)) (nofile (1))))
                     '((lib (5 0) "no version header") (nofile (1) "no version header"))))
      (should-not (straight-overview--unmet "app" '((lib (0)) (nofile (0))))))))

(ert-deftest straight-overview-test-unmet-invalid-version ()
  ;; A version header that is not a version never meets a requirement.
  (so-test-with-env
    (so-test--package "lib" :files `(("lib.el" . ,(so-test--header "lib" "x.y"))))
    (so-test--package "app")
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      (should (equal (straight-overview--unmet "app" '((lib (0))))
                     '((lib (0) "invalid version \"x.y\"")))))))

(ert-deftest straight-overview-test-requires-errors ()
  ;; Where package.el would refuse to install the package.
  (so-test-with-env
    (so-test--package "badver" :files `(("badver.el" . ,(so-test--header "badver" "x.y"))))
    (so-test--package "badreq" :files `(("badreq.el" . ,(so-test--header
                                                          "badreq" "1.0" "((foo \"x.y\"))"))))
    (so-test--package "nover" :files `(("nover.el" . ,(so-test--header "nover" nil "(bare)"))))
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      (should (equal (cadr (should-error (straight-overview--requires "badver")))
                     "Invalid version header \"x.y\""))
      (should-error (straight-overview--requires "badreq"))
      (should (equal (straight-overview--requires "nover") '((bare (0))))))))

(ert-deftest straight-overview-test-unmet-same-repo ()
  ;; A dependency in the package's own repo is read at the upstream tip.
  (so-test-with-env
    (so-test--package "suite" :files `(("suite.el" . ,(so-test--header "suite" "1.0"))
                                       ("suite-core.el" . ,(so-test--header "suite-core" "1.0"))))
    (so-test--package "suite-core" :repo "suite")
    (so-test--advance "suite" 1 `(("suite-core.el" . ,(so-test--header "suite-core" "2.0"))))
    (so-test--package "other")
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      (should-not (straight-overview--unmet "suite" '((suite-core (2 0)))))
      (should (equal (straight-overview--unmet "other" '((suite-core (2 0))))
                     '((suite-core (2 0) "1.0")))))))

(ert-deftest straight-overview-test-pull-order ()
  (so-test-with-env
    (so-test--package "app")
    (so-test--package "lib")
    (so-test--package "tool")
    (so-test--package "lib-extra" :repo "lib")
    (with-temp-buffer
      (setq-local straight-overview--records (straight-overview--collect))
      (should (equal (straight-overview--pull-order
                      '(("app" (lib (1)) (emacs (29))) ("lib") ("tool" (app (1)))))
                     '("lib" "app" "tool")))
      ;; A requirement in another marked package's repo.
      (should (equal (straight-overview--pull-order
                      '(("app" (lib-extra (1))) ("lib")))
                     '("lib" "app")))
      ;; A cycle terminates.
      (should (equal (sort (straight-overview--pull-order
                            '(("app" (lib (1))) ("lib" (app (1)))))
                           #'string<)
                     '("app" "lib"))))))

;;; Overview buffer

(defun so-test--three-packages ()
  "Create alpha (2 behind), beta (up to date) and gamma (1 behind, older)."
  (so-test--package "alpha")
  (so-test--advance "alpha" 2)
  (so-test--package "beta")
  (so-test--package "gamma")
  (so-test--advance "gamma" 1 nil (+ so-test--time 86400)))

(ert-deftest straight-overview-test-open ()
  (so-test-with-env
    (so-test--three-packages)
    (let ((display-line-numbers-mode-hook nil)
          (straight-overview-mode-hook (list (lambda () (display-line-numbers-mode 1)))))
      (with-current-buffer (so-test--open)
        (should (derived-mode-p 'straight-overview-mode))
        (should-not display-line-numbers-mode)
        (should hl-line-mode)
        (should (= (length straight-overview--records) 3))
        ;; Only outdated rows; the banner is not a row.
        (should (equal (so-test--ids) '("alpha" "gamma")))
        (goto-char (point-min))
        (should (equal (tabulated-list-get-id) "alpha"))
        (should (string-match-p "\\`2 packages are behind the remote"
                                (overlay-get straight-overview--banner 'before-string)))))))

(ert-deftest straight-overview-test-needs-straight ()
  ;; straight.el is loaded when the overview opens, not with the package.
  (let ((require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest args)
                 (unless (eq feature 'straight)
                   (apply require feature args)))))
      (should (equal (cadr (should-error (straight-overview) :type 'user-error))
                     "This command needs straight.el, which is not installed")))))

(ert-deftest straight-overview-test-open-no-hl-line ()
  (so-test-with-env
    (so-test--package "alpha")
    (let ((straight-overview-hl-line nil))
      (with-current-buffer (so-test--open)
        (should-not hl-line-mode)))))

(ert-deftest straight-overview-test-open-fetch ()
  (so-test-with-env
    (so-test--package "alpha")
    (let ((fetches 0))
      (cl-letf (((symbol-function 'straight-overview--fetch-start)
                 (lambda () (cl-incf fetches)))
                ((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (so-test--open)
        (should (= fetches 0))
        (let ((straight-overview-fetch-on-open 'ask))
          (so-test--open))
        (should (= fetches 0))
        (let ((straight-overview-fetch-on-open t))
          (so-test--open))
        (should (= fetches 1))
        (save-window-excursion (straight-overview t))
        (should (= fetches 2))))))

(ert-deftest straight-overview-test-row-numbers-and-sort ()
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (straight-overview-toggle-show)
      (should (eq straight-overview--show 'all))
      (should (equal (so-test--ids) '("alpha" "beta" "gamma")))
      ;; Behind sorts by time: beta (0), gamma (1 day), alpha (3 days).
      (setq tabulated-list-sort-key '("Behind" . nil))
      (tabulated-list-print t)
      (should (equal (so-test--ids) '("beta" "gamma" "alpha")))
      ;; The "#" column follows the sort.
      (goto-char (point-min))
      (should (equal (aref (tabulated-list-get-entry) 0) "1"))
      (forward-line 2)
      (should (equal (aref (tabulated-list-get-entry) 0) "3"))
      (straight-overview-toggle-show)
      (should (equal (so-test--ids) '("gamma" "alpha"))))))

(ert-deftest straight-overview-test-marks ()
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (goto-char (point-min))
      (straight-overview-mark)
      (should (equal (straight-overview--marked) '("alpha")))
      (should (equal (tabulated-list-get-id) "gamma"))
      (should (= (length straight-overview--mark-overlays) 1))
      (save-excursion
        (so-test--goto "alpha")
        (should (eq (char-after (line-beginning-position)) ?*)))
      (forward-line -1)
      (straight-overview-unmark)
      (should-not (straight-overview--marked))
      (should-not straight-overview--mark-overlays)
      (straight-overview-mark-outdated)
      (should (equal (straight-overview--marked) '("alpha" "gamma")))
      (should (= (length straight-overview--mark-overlays) 2))
      ;; Marks survive a re-render.
      (straight-overview--render)
      (should (= (length straight-overview--mark-overlays) 2))
      (straight-overview-unmark-all)
      (should-not (straight-overview--marked))
      (should-not straight-overview--mark-overlays))))

(ert-deftest straight-overview-test-pin ()
  (so-test-with-env
    (so-test--three-packages)
    (let ((straight-overview-pinned-file (expand-file-name "pins.eld" so-test--root)))
      (with-current-buffer (so-test--open)
        (so-test--goto "alpha")
        (straight-overview-mark)
        (so-test--goto "alpha")
        (straight-overview-pin)
        ;; Pinning unmarks.
        (should-not (straight-overview--marked))
        (should (equal (straight-overview--pinned-p "alpha") (so-test--head "alpha")))
        (should (equal (with-temp-buffer
                         (insert-file-contents straight-overview-pinned-file)
                         (read (current-buffer)))
                       `(("alpha" . ,(so-test--head "alpha")))))
        (so-test--goto "alpha")
        (should (equal (aref (tabulated-list-get-entry) 1) "*"))
        (should (eq (get-text-property 0 'face (aref (tabulated-list-get-entry) 2))
                    'shadow))
        ;; A pinned package cannot be marked.
        (straight-overview-mark)
        (should-not (straight-overview--marked))
        (straight-overview-mark-outdated)
        (should (equal (straight-overview--marked) '("gamma")))
        (so-test--goto "alpha")
        (straight-overview-unpin)
        (should-not (straight-overview--pinned-p "alpha"))
        (should (equal (with-temp-buffer
                         (insert-file-contents straight-overview-pinned-file)
                         (read (current-buffer)))
                       nil))))))

(ert-deftest straight-overview-test-restore ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 2)
    (let ((pinned (so-test--head "alpha"))
          (dir (straight--repos-dir "alpha")))
      (with-current-buffer (so-test--open)
        (so-test--goto "alpha")
        (straight-overview-pin)
        (so-test--git dir "merge" "-q" "--ff-only" "origin/main")
        (so-test--git dir "checkout" "-q" "--detach")
        (straight-overview-refresh)
        (straight-overview-toggle-show)
        (so-test--goto "alpha")
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (straight-overview-restore))
        (should (equal (so-test--head "alpha") pinned))
        (should (equal (so-test--git dir "symbolic-ref" "--short" "HEAD") "main"))
        (should (equal (plist-get (so-test--record "alpha") :commits) 2))))))

(ert-deftest straight-overview-test-restore-refused ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 1)
    (with-current-buffer (so-test--open)
      (let ((head (so-test--head "alpha")))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (_) (error "Should not ask"))))
          (so-test--goto "alpha")
          (straight-overview-restore))
        (so-test--goto "alpha")
        (straight-overview-pin)
        (so-test--goto "alpha")
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
          (straight-overview-restore))
        (should (equal (so-test--head "alpha") head))))))

(ert-deftest straight-overview-test-restore-branch ()
  (so-test-with-env
    (let ((dir (so-test--package "alpha")))
      (so-test--package "beta" :recipe '(:branch "dev"))
      (should (equal (straight-overview--restore-branch "beta" dir "origin") "dev"))
      (should (equal (straight-overview--restore-branch "alpha" dir "origin") "main"))
      (so-test--git dir "checkout" "-q" "--detach")
      (should (equal (straight-overview--restore-branch "alpha" dir "origin") "main"))
      (so-test--git dir "remote" "set-head" "origin" "--delete")
      (should (equal (straight-overview--restore-branch "alpha" dir "origin") "master")))))

;;; Pull

(defmacro so-test-with-pull (pulled rebuilt &rest body)
  "Run BODY with straight's pull and rebuild mocked.
PULLED and REBUILT name lists of the package names, in call order.  The
mocked pull fast-forwards the package's clone."
  (declare (indent 2) (debug t))
  `(let ((,pulled nil) (,rebuilt nil))
     (cl-letf (((symbol-function 'straight-pull-package)
                (lambda (name &rest _)
                  (setq ,pulled (append ,pulled (list name)))
                  (so-test--git (straight--repos-dir
                                 (plist-get (gethash name straight--recipe-cache)
                                            :local-repo))
                                "merge" "-q" "--ff-only" "origin/main")
                  t))
               ((symbol-function 'straight-rebuild-package)
                (lambda (name &rest _) (setq ,rebuilt (append ,rebuilt (list name)))))
               ((symbol-function 'yes-or-no-p) (lambda (_) t)))
       ,@body)))

(ert-deftest straight-overview-test-execute-order ()
  (so-test-with-env
    (so-test--deps-fixture)
    (with-current-buffer (so-test--open)
      (straight-overview-mark-outdated)
      (should (equal (straight-overview--marked) '("app" "lib")))
      (so-test-with-pull pulled rebuilt
        (straight-overview-execute)
        (should (equal pulled '("lib" "app")))
        (should-not rebuilt))
      (should-not (straight-overview--marked))
      (should-not (plist-get (so-test--record "app") :outdated))
      (should-not (plist-get (so-test--record "lib") :outdated)))))

(ert-deftest straight-overview-test-execute-skips-unmet ()
  (so-test-with-env
    (so-test--deps-fixture)
    (with-current-buffer (so-test--open)
      (so-test--goto "app")
      (straight-overview-mark)
      (let (warnings)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (type message &rest _) (push (cons type message) warnings))))
          (so-test-with-pull pulled _rebuilt
            (straight-overview-execute)
            (should-not pulled)))
        (should (equal warnings
                       '((straight-overview
                          . "app was not pulled; it requires lib 2.0 (installed: 1.0)")))))
      (should (plist-get (so-test--record "app") :outdated)))))

(ert-deftest straight-overview-test-execute-skips-unreadable ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 1 `(("alpha.el" . ,(so-test--header
                                                  "alpha" "1.1" "((foo \"x.y\"))"))))
    (so-test--package "beta")
    (so-test--advance "beta" 1)
    (with-current-buffer (so-test--open)
      (straight-overview-mark-outdated)
      (let (warnings)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (so-test-with-pull pulled _rebuilt
            (straight-overview-execute)
            (should (equal pulled '("beta")))))
        (should (equal (length warnings) 1))
        (should (string-prefix-p "alpha was not pulled; its package header cannot be read: "
                                 (car warnings)))))))

(ert-deftest straight-overview-test-execute-bare-requirement ()
  ;; A bare symbol in Package-Requires still requires the package.
  (so-test-with-env
    (so-test--package "app")
    (so-test--advance "app" 1 `(("app.el" . ,(so-test--header "app" "1.1" "(no-such-package)"))))
    (with-current-buffer (so-test--open)
      (straight-overview-mark-outdated)
      (let (warnings)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (so-test-with-pull pulled _rebuilt
            (straight-overview-execute)
            (should-not pulled)))
        (should (equal warnings
                       '("app was not pulled; it requires no-such-package 0 (installed: not installed)")))))))

(ert-deftest straight-overview-test-execute-force ()
  ;; X pulls what x skips, in dependency order, and warns.
  (so-test-with-env
    (so-test--deps-fixture)
    (so-test--package "broken")
    (so-test--advance "broken" 1 `(("broken.el" . ,(so-test--header
                                                    "broken" "x.y"))))
    (with-current-buffer (so-test--open)
      (dolist (name '("app" "broken"))
        (so-test--goto name)
        (straight-overview-mark))
      (let (warnings prompt)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (so-test-with-pull pulled _rebuilt
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (p) (setq prompt p) t)))
              (straight-overview-execute-force))
            (should (equal pulled '("app" "broken")))))
        (should (equal prompt "Pull 2 package(s), ignoring unmet dependencies? "))
        (should (equal (sort warnings #'string<)
                       '("app was pulled although it requires lib 2.0 (installed: 1.0)"
                         "broken was pulled although its package header cannot be read: Invalid version header \"x.y\""))))
      (should-not (plist-get (so-test--record "app") :outdated)))))

(ert-deftest straight-overview-test-execute-prefix-forces ()
  (so-test-with-env
    (so-test--deps-fixture)
    (with-current-buffer (so-test--open)
      (so-test--goto "app")
      (straight-overview-mark)
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (so-test-with-pull pulled _rebuilt
          (let ((current-prefix-arg '(4)))
            (call-interactively #'straight-overview-execute))
          (should (equal pulled '("app"))))))))

(ert-deftest straight-overview-test-execute-rebuild ()
  (so-test-with-env
    (so-test--three-packages)
    (let ((straight-overview-build-on-pull t))
      (with-current-buffer (so-test--open)
        (straight-overview-mark-outdated)
        (so-test-with-pull pulled rebuilt
          (straight-overview-execute)
          (should (equal pulled '("alpha" "gamma")))
          (should (equal rebuilt '("alpha" "gamma"))))))))

(ert-deftest straight-overview-test-execute-nothing ()
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (error "Should not ask"))))
        (straight-overview-execute))
      (straight-overview-mark-outdated)
      (let (pulled)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil))
                  ((symbol-function 'straight-pull-package)
                   (lambda (name &rest _) (push name pulled))))
          (straight-overview-execute))
        (should-not pulled)
        (should (equal (straight-overview--marked) '("alpha" "gamma")))))))

;;; Fetch

(ert-deftest straight-overview-test-fetch-progress ()
  (let ((pool (straight-overview--make-pool :results (make-vector 4 nil) :pending 1)))
    (should (equal (straight-overview--fetch-progress pool) "3 of 4 repositories done"))))

(ert-deftest straight-overview-test-banner-text ()
  (with-temp-buffer
    (setq-local straight-overview--records '((:name "a" :outdated t) (:name "b")))
    (setq-local straight-overview--show 'outdated)
    (let ((straight-overview--fetch nil)
          (straight-overview--fetch-problems nil)
          (straight-display-subprocess-prompts nil))
      (let ((text (straight-overview--banner-text)))
        (should (string-prefix-p "1 package is behind the remote as of the last fetch.\n" text))
        (should (string-match-p "to fetch new commits" text))
        (should (string-match-p "to show all packages" text))
        (should (string-suffix-p ".\n\n" text)))
      (setq straight-overview--fetch-problems
            '(:failed ("a" "b") :timed-out ("c") :credentials ("d")))
      (let ((text (straight-overview--banner-text)))
        (should (string-match-p "^Last fetch failed for: a, b\\.$" text))
        (should (string-match-p "^Last fetch timed out for: c\\.$" text))
        (should (string-match-p "^Last fetch needed credentials for: d\\.  Set `straight-display-subprocess-prompts'" text)))
      (let ((straight-display-subprocess-prompts t))
        (should (string-match-p "^Last fetch needed credentials for: d\\.$"
                                (straight-overview--banner-text))))
      ;; While a fetch runs, the progress replaces the problems.
      (setq straight-overview--fetch
            (straight-overview--make-pool :results (make-vector 2 nil) :pending 2))
      (setq-local straight-overview--show 'all)
      (let ((text (straight-overview--banner-text)))
        (should (string-match-p "to cancel the fetch" text))
        (should (string-match-p "to show only outdated packages" text))
        (should (string-match-p "^Fetching in the background: 0 of 2 repositories done\\.$" text))
        (should-not (let ((case-fold-search nil))
                      (string-match-p "Last fetch" text)))))
    (setq-local straight-overview--records nil)
    (should (string-prefix-p "0 packages are behind" (straight-overview--banner-text)))))

(ert-deftest straight-overview-test-fetch-done ()
  (let* ((repos (mapcar (lambda (n) (straight-overview--make-repo :name n))
                        '("ok" "creds" "failed" "slow")))
         (pool (straight-overview--make-pool
                :results (vector "" nil nil nil)
                :errors (vector nil "fatal: could not read Username for 'https://x'"
                                "fatal: repository not found" nil)
                :timed-out '(3)))
         (straight-overview--fetch pool)
         (straight-overview--fetch-problems nil)
         timers)
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_secs _repeat fn &rest _) (push fn timers))))
      (straight-overview--fetch-done repos pool))
    (should-not straight-overview--fetch)
    (should (equal (plist-get straight-overview--fetch-problems :failed) '("failed")))
    (should (equal (plist-get straight-overview--fetch-problems :timed-out) '("slow")))
    (should (equal (plist-get straight-overview--fetch-problems :credentials)
                   (list (nth 1 repos))))
    (should (equal timers '(straight-overview--after-fetch)))))

(ert-deftest straight-overview-test-after-fetch-credentials ()
  (let* ((repos (mapcar (lambda (n) (straight-overview--make-repo :name n)) '("a" "b")))
         (straight-overview--fetch-problems (list :failed nil :timed-out nil
                                                  :credentials repos)))
    ;; Without straight's prompt switch, nobody is asked.
    (let ((straight-display-subprocess-prompts nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (error "Should not ask"))))
        (straight-overview--after-fetch)))
    (should (equal (plist-get straight-overview--fetch-problems :credentials) '("a" "b")))
    ;; With it, the fetches that still fail are kept.
    (setq straight-overview--fetch-problems (list :credentials repos))
    (let ((straight-display-subprocess-prompts t))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'straight-overview--fetch-with-prompts)
                 (lambda (repo) (equal (straight-overview--repo-name repo) "a"))))
        (straight-overview--after-fetch)))
    (should (equal (plist-get straight-overview--fetch-problems :credentials) '("b")))))

(ert-deftest straight-overview-test-fetch ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--package "alpha-extra" :repo "alpha")
    (so-test--package "beta")
    (let ((broken (so-test--package "broken")))
      (so-test--git broken "remote" "set-url" "origin"
                    (expand-file-name "no-such-repo" so-test--root)))
    ;; Upstream moves on without a fetch into the clone.
    (so-test--commit (so-test--upstream "alpha") '(("new" . "x")))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_secs _repeat fn &rest args) (apply fn args))))
      (with-current-buffer (so-test--open)
        (should-not (plist-get (so-test--record "alpha") :outdated))
        (straight-overview-fetch)
        (let ((pool straight-overview--fetch))
          ;; One fetch per repository.
          (should (= (length (straight-overview--pool-results pool)) 3))
          (should (string-match-p "Fetching in the background"
                                  (overlay-get straight-overview--banner 'before-string)))
          (so-test--wait pool))
        (should-not straight-overview--fetch)
        (should (equal (plist-get straight-overview--fetch-problems :failed) '("broken")))
        (should (equal (plist-get (so-test--record "alpha") :commits) 1))
        (should (string-match-p "Last fetch failed for: broken"
                                (overlay-get straight-overview--banner 'before-string)))))))

(ert-deftest straight-overview-test-fetch-cancel ()
  (so-test-with-env
    (let ((cancelled nil))
      (setq straight-overview--fetch
            (straight-overview--make-pool :results (make-vector 2 nil) :pending 2))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'straight-overview--pool-cancel)
                 (lambda (_) (setq cancelled t))))
        (straight-overview-fetch))
      (should cancelled)
      (should-not straight-overview--fetch))))

(ert-deftest straight-overview-test-fetch-with-prompts ()
  (so-test-with-env
    (let ((alpha (so-test--package "alpha"))
          (broken (so-test--package "broken")))
      (so-test--commit (so-test--upstream "alpha") '(("new" . "x")))
      (so-test--git broken "remote" "set-url" "origin"
                    (expand-file-name "no-such-repo" so-test--root))
      (should (straight-overview--fetch-with-prompts
               (straight-overview--find-repo "alpha")))
      (should (equal (so-test--git alpha "rev-parse" "origin/main")
                     (so-test--git (so-test--upstream "alpha") "rev-parse" "HEAD")))
      (should-not (straight-overview--fetch-with-prompts
                   (straight-overview--find-repo "broken"))))))

(ert-deftest straight-overview-test-prompt-filter ()
  (with-temp-buffer
    (let ((buf (current-buffer)) sent deleted)
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'process-send-string)
                 (lambda (_ string) (push string sent)))
                ((symbol-function 'delete-process) (lambda (_) (setq deleted t)))
                ((symbol-function 'read-string) (lambda (_) "user"))
                ((symbol-function 'read-passwd) (lambda (_) (copy-sequence "secret")))
                ((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (straight-overview--prompt-filter 'proc "remote: Counting objects\n")
        (should-not sent)
        (straight-overview--prompt-filter 'proc "Username for 'https://github.com': ")
        (should (equal sent '("user\n")))
        (straight-overview--prompt-filter 'proc "Password for 'https://user@github.com': ")
        (should (equal (car sent) "secret\n"))
        (straight-overview--prompt-filter 'proc "Enter passphrase for key '/k': ")
        (should (equal (car sent) "secret\n"))
        (straight-overview--prompt-filter
         'proc "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        (should (equal (car sent) "yes\n"))
        (should (= (length sent) 4))
        (should (string-match-p "remote: Counting objects" (buffer-string)))
        (should-not deleted)
        (cl-letf (((symbol-function 'read-string) (lambda (_) (signal 'quit nil))))
          (straight-overview--prompt-filter 'proc "Username for 'https://x': "))
        (should deleted)))))

;;; Changelog and browse

(ert-deftest straight-overview-test-changelog-plain ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 2)
    (so-test--package "beta")
    (with-current-buffer (so-test--open)
      (straight-overview-toggle-show)
      (so-test--goto "beta")
      (save-window-excursion (straight-overview-changelog))
      (should-not (get-buffer "*straight-overview-log: beta*"))
      (so-test--goto "alpha")
      (save-window-excursion (straight-overview-changelog))
      (with-current-buffer "*straight-overview-log: alpha*"
        (should (derived-mode-p 'special-mode))
        (should (string-prefix-p "Pending commits for alpha (HEAD..origin/main):\n\n"
                                 (buffer-string)))
        (should (= (count-lines (point-min) (point-max)) 4))))))

(ert-deftest straight-overview-test-browse ()
  (so-test-with-env
    (so-test--package "alpha")
    (with-current-buffer (so-test--open)
      (straight-overview-toggle-show)
      (so-test--goto "alpha")
      (let (urls)
        (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url urls))))
          (straight-overview-browse))
        (should (equal urls '("https://github.com/user/alpha")))))))

;;; Mechanisms named in the commit history

(ert-deftest straight-overview-test-pool-default-width ()
  (let ((straight-overview-jobs nil))
    (should (= (straight-overview--pool-width (straight-overview--pool-start nil))
               (num-processors))))
  (let ((straight-overview-jobs 3))
    (should (= (straight-overview--pool-width (straight-overview--pool-start nil)) 3))
    (should (= (straight-overview--pool-width (straight-overview--pool-start nil :width 0))
               1))))

(ert-deftest straight-overview-test-git-batch-quit ()
  ;; C-g while waiting deletes the processes still running.
  (so-test-with-env
    (let ((start (symbol-function 'straight-overview--pool-start))
          pool procs)
      (cl-letf (((symbol-function 'straight-overview--pool-start)
                 (lambda (&rest args) (setq pool (apply start args))))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _)
                   (setq procs (straight-overview--pool-procs pool))
                   (signal 'quit nil))))
        (should (eq (condition-case nil
                        (straight-overview--git-batch
                         (make-list 2 (list so-test--root "-c" "alias.slow=!sleep 5" "slow")))
                      (quit 'quit))
                    'quit)))
      (should (= (length procs) 2))
      (should-not (seq-some #'process-live-p procs))
      (should-not (straight-overview--pool-procs pool)))))

(ert-deftest straight-overview-test-collect-non-positive-time ()
  ;; A fork whose HEAD post-dates the tracked tip.
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 4 nil (- so-test--time 86400))
    (let ((rec (car (straight-overview--collect))))
      (should (equal (plist-get rec :behind) "(4; <1d)"))
      (should (< (plist-get rec :behind-secs) 0)))))

(ert-deftest straight-overview-test-collect-remote ()
  ;; The recipe's :remote is the one compared with.
  (so-test-with-env
    (let ((dir (so-test--package "alpha" :recipe '(:remote "upstream"))))
      (so-test--git dir "remote" "rename" "origin" "upstream")
      (so-test--commit (so-test--upstream "alpha") nil (+ so-test--time 86400))
      (so-test--git dir "fetch" "-q" "upstream")
      (let ((rec (car (straight-overview--collect))))
        (should (equal (plist-get rec :remote) "upstream"))
        (should (equal (plist-get rec :upstream) "upstream/main"))
        (should (equal (plist-get rec :commits) 1))))))

(ert-deftest straight-overview-test-format ()
  (with-temp-buffer
    (straight-overview-mode)
    ;; "#" is right-aligned and not sortable; Behind sorts with a predicate.
    (should (equal (aref tabulated-list-format 0) '("#" 4 nil :right-align t)))
    (should (eq (nth 2 (aref tabulated-list-format 5)) #'straight-overview--behind-lessp))
    (should (equal (mapcar #'car tabulated-list-format)
                   '("#" "Pin" "Package" "Installed" "Branch" "Behind" "Tag" "Remote")))
    (should (eq tabulated-list-printer #'straight-overview--print-entry))))

(ert-deftest straight-overview-test-keymap ()
  (dolist (binding '(("m" . straight-overview-mark) ("u" . straight-overview-unmark)
                     ("U" . straight-overview-unmark-all)
                     ("M" . straight-overview-mark-outdated)
                     ("x" . straight-overview-execute)
                     ("X" . straight-overview-execute-force)
                     ("P" . straight-overview-pin)
                     ("F" . straight-overview-unpin) ("R" . straight-overview-restore)
                     ("c" . straight-overview-changelog) ("o" . straight-overview-browse)
                     ("RET" . straight-overview-browse)
                     ("a" . straight-overview-toggle-show)
                     ("g" . straight-overview-refresh) ("G" . straight-overview-fetch)))
    (should (eq (keymap-lookup straight-overview-mode-map (car binding)) (cdr binding)))))

(ert-deftest straight-overview-test-banner-survives-sort ()
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (let ((banner straight-overview--banner))
        ;; A column sort re-prints without `straight-overview--render'.
        (goto-char (point-min))
        (tabulated-list-sort 2)
        (should (eq straight-overview--banner banner))
        (should (eq (overlay-buffer banner) (current-buffer)))
        (should (= (overlay-start banner) (point-min)))
        (should (string-prefix-p "2 packages" (overlay-get banner 'before-string)))
        (should (equal (so-test--ids) '("gamma" "alpha")))
        (goto-char (point-min))
        (should (equal (aref (tabulated-list-get-entry) 0) "1"))))))

(ert-deftest straight-overview-test-sort-key-fresh ()
  ;; Reversing a sort does not carry over to the next overview buffer.
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (goto-char (point-min))
      (tabulated-list-sort 2)
      (should (equal (so-test--ids) '("gamma" "alpha"))))
    (kill-buffer "*straight-overview*")
    (with-current-buffer (so-test--open)
      (should (equal tabulated-list-sort-key '("Package")))
      (should (equal (so-test--ids) '("alpha" "gamma"))))))

(ert-deftest straight-overview-test-banner-height ()
  ;; The table does not move when a fetch starts or ends.
  (with-temp-buffer
    (let ((straight-overview--fetch-problems nil)
          (lines (lambda ()
                   (cl-count ?\n (straight-overview--banner-text)))))
      (let ((straight-overview--fetch nil))
        (should (= (funcall lines) 3)))
      (let ((straight-overview--fetch
             (straight-overview--make-pool :results (make-vector 1 nil) :pending 1)))
        (should (= (funcall lines) 3))))))

(ert-deftest straight-overview-test-mark-faces ()
  (should (eq (face-attribute 'straight-overview-mark :inherit) 'dired-mark))
  (should (eq (face-attribute 'straight-overview-marked :inherit) 'dired-marked))
  (so-test-with-env
    (so-test--three-packages)
    (with-current-buffer (so-test--open)
      (goto-char (point-min))
      (straight-overview-mark)
      (let ((ov (car straight-overview--mark-overlays)))
        (should (eq (overlay-get ov 'face) 'straight-overview-marked))
        ;; The overlay covers the newline, so the highlight reaches the
        ;; window edge.
        (should (= (overlay-start ov) (point-min)))
        (should (= (overlay-end ov) (save-excursion (goto-char (point-min))
                                                    (line-beginning-position 2))))
        (should (eq (get-text-property (point-min) 'face) 'straight-overview-mark))))))

(ert-deftest straight-overview-test-open-selected-window ()
  (so-test-with-env
    (so-test--package "alpha")
    (save-window-excursion
      (delete-other-windows)
      (let ((window (selected-window)))
        (straight-overview)
        (should (eq (window-buffer window) (get-buffer "*straight-overview*")))
        (should (one-window-p))))
    ;; `display-buffer-alist' decides where it goes.
    (save-window-excursion
      (let* (called
             (display-buffer-alist
              `(("\\`\\*straight-overview\\*\\'"
                 ,(lambda (buffer alist)
                    (setq called t)
                    (display-buffer-same-window buffer alist))))))
        (straight-overview)
        (should called)))))

(ert-deftest straight-overview-test-restore-rebuild ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 1)
    (let ((straight-overview-build-on-pull t)
          rebuilt)
      (with-current-buffer (so-test--open)
        (so-test--goto "alpha")
        (straight-overview-pin)
        (straight-overview-toggle-show)
        (so-test--goto "alpha")
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                  ((symbol-function 'straight-rebuild-package)
                   (lambda (name &rest _) (push name rebuilt))))
          (straight-overview-restore))
        (should (equal rebuilt '("alpha")))))))

(ert-deftest straight-overview-test-credentials-regexp ()
  (dolist (err '("fatal: could not read Username for 'https://github.com': terminal prompts disabled"
                 "fatal: could not read Password for 'https://u@github.com': No such device"
                 "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."
                 "Host key verification failed.\nfatal: Could not read from remote repository."))
    (should (string-match-p straight-overview--credentials-regexp err)))
  (dolist (err '("fatal: repository 'https://github.com/u/x/' not found"
                 "fatal: unable to access 'https://x/': Could not resolve host: x"))
    (should-not (string-match-p straight-overview--credentials-regexp err))))

(ert-deftest straight-overview-test-fetch-start-arguments ()
  (so-test-with-env
    (so-test--package "alpha" :recipe '(:remote "upstream"))
    (so-test--package "beta")
    (let ((straight-overview-fetch-jobs 7)
          (straight-overview-fetch-timeout 12)
          call)
      (cl-letf (((symbol-function 'straight-overview--pool-start)
                 (lambda (jobs &rest keys)
                   (setq call (list jobs keys process-environment))
                   (straight-overview--make-pool :pending 0))))
        (straight-overview--fetch-start))
      (pcase-let ((`(,jobs ,keys ,env) call))
        (should (equal (sort (mapcar #'cdr jobs)
                             (lambda (a b) (string< (car (last a)) (car (last b)))))
                       '(("fetch" "--quiet" "origin") ("fetch" "--quiet" "upstream"))))
        (should (equal (plist-get keys :width) 7))
        (should (equal (plist-get keys :timeout) 12))
        (should (member "GIT_TERMINAL_PROMPT=0" env))
        (should (equal (getenv-internal "LC_ALL" env) "C")))
      ;; Nothing left to wait for.
      (should-not straight-overview--fetch))))

(ert-deftest straight-overview-test-fetch-timeout ()
  (so-test-with-env
    (let ((slow (so-test--package "slow"))
          (straight-overview-fetch-timeout 0.5)
          (start (float-time)))
      (so-test--git slow "config" "remote.origin.uploadpack" "sleep 5; git-upload-pack")
      (cl-letf (((symbol-function 'run-with-idle-timer) #'ignore))
        (straight-overview--fetch-start)
        (so-test--wait straight-overview--fetch))
      (should (< (- (float-time) start) 4))
      (should (equal (plist-get straight-overview--fetch-problems :timed-out) '("slow"))))))

(ert-deftest straight-overview-test-fetch-cancel-declined ()
  (so-test-with-env
    (let ((pool (straight-overview--make-pool :results (make-vector 2 nil) :pending 2)))
      (setq straight-overview--fetch pool)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil))
                ((symbol-function 'straight-overview--pool-cancel)
                 (lambda (_) (error "Should not cancel"))))
        (straight-overview-fetch))
      (should (eq straight-overview--fetch pool)))))

(ert-deftest straight-overview-test-after-fetch-waits-for-minibuffer ()
  (let ((straight-overview--fetch-problems nil)
        timers)
    (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
              ((symbol-function 'run-with-idle-timer)
               (lambda (secs _repeat fn &rest _) (push (cons secs fn) timers)))
              ((symbol-function 'straight-overview-refresh)
               (lambda () (error "Should not refresh"))))
      (straight-overview--after-fetch))
    (should (equal timers '((1 . straight-overview--after-fetch))))))

(ert-deftest straight-overview-test-after-fetch-message ()
  (let ((straight-overview--fetch-problems
         '(:failed ("a") :timed-out ("b") :credentials ("c")))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (straight-overview--after-fetch)
      (should (equal (car messages)
                     "straight-overview: fetch done; 3 did not succeed (listed in the overview)"))
      (setq straight-overview--fetch-problems nil)
      (straight-overview--after-fetch)
      (should (equal (car messages) "straight-overview: fetch done")))))

(ert-deftest straight-overview-test-changelog-magit ()
  (so-test-with-env
    (so-test--package "alpha")
    (so-test--advance "alpha" 2)
    ;; A stand-in Magit that only provides the feature.
    (with-temp-file (expand-file-name "magit.el" so-test--root)
      (insert "(provide 'magit)\n"))
    (let ((load-path (cons so-test--root load-path))
          (features (copy-sequence features))
          (straight-overview-changelog-use-magit t)
          (dead (generate-new-buffer "dead-log"))
          (log (generate-new-buffer "log"))
          calls)
      (kill-buffer dead)
      (setq straight-overview--log-buffers (list dead log))
      (unwind-protect
          (cl-letf (((symbol-function 'magit-log-setup-buffer)
                     (lambda (revs args files &rest _)
                       (push (list revs args files default-directory
                                   (bound-and-true-p magit-display-buffer-function))
                             calls)
                       log)))
            (with-current-buffer (so-test--open)
              (so-test--goto "alpha")
              (straight-overview-changelog))
            (should (equal calls
                           `((("HEAD..origin/main") ("-n256" "--decorate") nil
                              ,(file-name-as-directory (straight--repos-dir "alpha"))
                              straight-overview--display-log))))
            ;; Dead buffers are dropped; the new one comes first, once.
            (should (equal straight-overview--log-buffers (list log))))
        (kill-buffer log)))))

(ert-deftest straight-overview-test-display-log ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((overview (selected-window))
           (a (generate-new-buffer "log-a"))
           (b (generate-new-buffer "log-b"))
           (straight-overview--log-buffers (list a)))
      (unwind-protect
          (let ((window (straight-overview--display-log a)))
            ;; None visible: a new window, never the overview's.
            (should (window-live-p window))
            (should-not (eq window overview))
            (should (eq (window-buffer window) a))
            ;; A visible log window is reused.
            (should (eq (straight-overview--display-log b) window))
            (should (eq (window-buffer window) b))
            (should (= (length (window-list)) 2)))
        (kill-buffer a)
        (kill-buffer b)))))

(provide 'straight-overview-tests)
;;; straight-overview-tests.el ends here
