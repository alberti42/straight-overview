# straight-overview

A read-only overview and **selective-upgrade UI** for packages managed by
[straight.el](https://github.com/radian-software/straight.el).

`straight-pull-all` is all-or-nothing. `straight-overview` answers a different
question — *which* of my packages have newer commits upstream, and *how far*
behind am I? — and lets you upgrade only the ones you choose, dired-style.

```
M-x straight-overview
```

opens a buffer with one row per git-managed package:

| Pin | Package | Installed | Branch | Behind | Tag | Remote |
|-----|---------|-----------|--------|--------|-----|--------|
|     | consult | a1b2c3d   | main   | (3; 14d) | 1.9 | https://github.com/minad/consult |

The **Behind** column shows `(<commits>; <time>)` — how many commits and how
much wall-clock time your installed checkout is behind the tracked upstream
branch. By default only outdated packages are listed.

## Design

- **Opens instantly.** The list is built from *local* git refs — no network
  call when you open it. The "behind" figures reflect the last time each
  remote was fetched.
- **Fetch is explicit and decoupled.** Press <kbd>G</kbd> to run
  `straight-fetch-all` and refresh against live remotes. You decide when to
  pay the network cost, not the act of opening the list.
- **Selective, dired-style upgrades.** Mark the packages you want, then
  execute. No more updating 100 packages to get the one you cared about.
- **Pinning (holds).** Pin a package to *hold* it: it stays visible (faded, with
  a `*` in the Pin column) but can't be marked for update, so you won't pull it
  by accident. Pinning records the installed commit, and <kbd>R</kbd> resets the
  package back to it. This is a UI-level hold — it's independent of straight's
  own `straight-freeze-versions` lockfile and doesn't affect `straight-pull-all`.

## Installation

`straight-overview` requires a working straight.el. With `use-package`:

```elisp
(use-package straight-overview
  :straight (:host github :repo "alberti42/straight-overview")
  :commands (straight-overview))
```

Or directly:

```elisp
(straight-use-package
 '(straight-overview :host github :repo "alberti42/straight-overview"))
```

Requires Emacs 29.1+.

## Keybindings

| Key | Action |
|-----|--------|
| <kbd>m</kbd> | mark package at point for update |
| <kbd>u</kbd> | unmark |
| <kbd>U</kbd> | unmark all |
| <kbd>M</kbd> | mark all outdated packages |
| <kbd>x</kbd> | pull marked packages (and rebuild, if enabled) |
| <kbd>P</kbd> | pin the package at point at its current commit (hold) |
| <kbd>F</kbd> | free (unpin) the package at point |
| <kbd>R</kbd> | restore the package at point to its pinned commit (no-op if unpinned) |
| <kbd>c</kbd> | show changelog (`HEAD..upstream`) for package at point — a `magit-log` buffer when Magit is available (each commit actionable), else a plain `git log` listing |
| <kbd>o</kbd> / <kbd>RET</kbd> | open the package's repo in a browser |
| <kbd>a</kbd> | toggle outdated-only / show all packages |
| <kbd>g</kbd> | re-scan from local refs (no fetch) |
| <kbd>G</kbd> | `straight-fetch-all`, then re-scan |

Standard `tabulated-list-mode` keys also apply (sort by clicking a column
header, etc.).

## Customization

| Variable | Default | Meaning |
|----------|---------|---------|
| `straight-overview-fetch-on-open` | `nil` | `nil` opens instantly (fetch later with <kbd>G</kbd>); `ask` prompts y/n; `t` always fetches first. A prefix arg (`C-u M-x straight-overview`) forces a fetch for one invocation. |
| `straight-overview-show` | `outdated` | `outdated` shows only behind packages; `all` shows everything. Toggle live with <kbd>a</kbd>. |
| `straight-overview-changelog-use-magit` | `t` | When `t` and Magit is loaded, <kbd>c</kbd> opens a `magit-log` buffer. Set to `nil` to always use the plain `git log` listing even if Magit is installed (useful for debugging the built-in path). |
| `straight-overview-build-on-pull` | `nil` | `nil` pulls only — straight rebuilds the modified repos on the next Emacs restart. `t` also runs `straight-rebuild-package` immediately, doing everything in one go. Also governs whether <kbd>R</kbd> rebuilds in-session. |
| `straight-overview-pinned-file` | `nil` | When set to a path, pinned packages persist there as an `.eld` alist of `(name . commit)`. When `nil`, pinning is session-only. |

## Notes & limitations

- **"Latest stable" vs "unstable".** straight has no stable/unstable concept —
  it tracks one branch. The **Behind** column reflects that branch's tip; the
  **Tag** column shows `git describe --tags` as the closest stand-in for a
  stable release (blank for untagged packages).
- **Fetch is synchronous.** `straight-fetch-all` (via <kbd>G</kbd>) blocks
  Emacs while it contacts every remote. Asynchronous fetching is a planned
  improvement.
- **Shallow clones.** Commit counts and changelogs assume full clones
  (straight's default — `straight-vc-git-default-clone-depth` = `full`). If a
  package was cloned shallow, those figures may be truncated.
- **Restore is a hard reset.** <kbd>R</kbd> reattaches to the tracked branch and
  runs `git reset --hard` to the pinned commit, so any uncommitted local changes
  in that repo are discarded (straight clones are normally pristine). It asks for
  confirmation first.

## License

[Mozilla Public License 2.0](LICENSE).
