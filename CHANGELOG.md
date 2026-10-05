# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The current row is highlighted with `hl-line-mode`. Set
  `straight-overview-hl-line` to nil to turn this off.

## [0.1.0] - 2026-10-04

First release.

### Added

- `M-x straight-overview` opens a buffer with one row per git-managed
  package, with the columns `#`, `Pin`, `Package`, `Installed`, `Branch`,
  `Behind`, `Tag` and `Remote`. The **Behind** column shows
  `(<commits>; <time>)` — how many commits and how much wall-clock time your
  installed checkout is behind the tracked upstream branch. By default only
  outdated packages are listed; <kbd>a</kbd> toggles outdated-only / show all
  packages.
- The list is built from local git refs. The scan runs git for all packages
  in parallel, at most `straight-overview-jobs` processes at once: 0.4 s for
  111 packages on an 8-core Mac.
- <kbd>G</kbd> fetches all remotes in the background, then re-scans; while a
  fetch runs, it offers to cancel it. The fetches run in parallel, at most
  `straight-overview-fetch-jobs` at once (default 16). A fetch still running
  after `straight-overview-fetch-timeout` seconds (default 30) is stopped.
- A banner above the table gives the number of packages behind the remote as
  of the last fetch and reminds you to press <kbd>G</kbd>. While a fetch runs,
  it shows the progress; afterwards, it lists the packages whose fetch
  failed, timed out, or needed credentials.
- Credentials are asked for at the end of a fetch, one repository at a time,
  when `straight-display-subprocess-prompts` is non-nil.
- Dired-style selective upgrades: <kbd>m</kbd>, <kbd>u</kbd>, <kbd>U</kbd>
  and <kbd>M</kbd> mark and unmark packages; <kbd>x</kbd> pulls the marked
  packages through `straight-pull-package` (and rebuilds them when
  `straight-overview-build-on-pull` is non-nil).
- Pinning: <kbd>P</kbd> pins the package at point at its current commit
  (hold), <kbd>F</kbd> frees it, and <kbd>R</kbd> restores it to its pinned
  commit. Pinned packages cannot be marked for update. Pins persist in
  `straight-overview-pinned-file` when it is set.
- <kbd>c</kbd> shows the changelog (`HEAD..upstream`) for the package at point
  — a `magit-log` buffer when Magit is available, else a plain `git log`
  listing.
- <kbd>o</kbd> / <kbd>RET</kbd> opens the package's repo in a browser.
- `straight-overview-fetch-on-open` fetches when the overview opens; a prefix
  arg (`C-u M-x straight-overview`) forces a fetch for one invocation.
- The overview opens in the selected window and honors
  `display-buffer-alist`, keyed on the buffer name `*straight-overview*`.

[Unreleased]: https://github.com/alberti42/straight-overview/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alberti42/straight-overview/releases/tag/v0.1.0
