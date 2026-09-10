# Dwindle for Doom Emacs

A native Emacs BSP layout with focused-window insertion, tree operations, and
XMonad's `ExpandTowards` / `ShrinkFrom` resizing. Requires Emacs 28.1 or later. Evil is
optional; the package also works in ordinary Emacs.

Each new split divides the focused ordinary window in half, alternating the
axis of its parent split. Keeping each new pane selected gives a dwindle chain:

```text
+-----------------------+-----------------------+
|                       |                       |
|                       |           B           |
|                       |                       |
|           A           +-----------+-----------+
|        master         |           |           |
|                       |     C     |     D     |
|                       |           |           |
+-----------------------+-----------+-----------+
```

Closing a window expands its surviving sibling subtree into the vacated space.
Closing A promotes the B/C/D subtree; its surviving windows keep their identities,
buffers, and views. Selecting A before splitting instead divides A, producing
the branching layout of XMonad BSP. `dwindle-split-policy` can restore the
original trailing-pane insertion if desired.

## Enable in Doom

Install from [vonpost/emacs-dwindle](https://github.com/vonpost/emacs-dwindle)
using Doom's package manager. The files below belong in your existing Doom
configuration directory, usually `~/.config/doom/` or `~/.doom.d/`.

**1. Add the package to `packages.el`:**

```elisp
(package! dwindle
  :recipe (:host github
           :repo "vonpost/emacs-dwindle"
           :files ("dwindle*.el")))
```

The recipe includes the main package and its resize, tree, Doom, and terminal
helpers. Doom manages the checkout; you do not need to clone it yourself.

**2. Enable it in `config.el`:**

```elisp
(use-package! dwindle
  :demand t
  :config
  (dwindle-mode 1))
```

`:demand t` loads the package at startup so its global mode and Super bindings
are active immediately. If you previously used the local-checkout instructions,
remove that Dwindle `add-to-list 'load-path` form so it cannot shadow the installed
package. Copyable examples are in [doom/packages.el](doom/packages.el) and
[doom/config.el](doom/config.el).

**3. For the terminal shortcuts, enable Ghostel:**

If your Doom installation provides the Ghostel module, add or uncomment `ghostel`
under `:term` inside your existing `(doom! ...)` form in `init.el`:

```elisp
;; Inside (doom! ...), alongside your existing terminal modules:
:term
ghostel
```

If Ghostel already works in your configuration, keep that setup. For Doom
versions without the module, follow [Ghostel's installation
instructions](https://github.com/dakra/ghostel#installation) to install the package
and its native module. Ghostel is optional for splitting, resizing, rotation,
and opening scratch; it is required for the terminal commands.

**4. Synchronize Doom, then restart Emacs:**

```sh
doom sync
```

If `doom` is not on your `PATH`, use the executable from your Doom installation,
for example `~/.config/emacs/bin/doom sync` or `~/.emacs.d/bin/doom sync`.
Restart the daemon too if you use `emacsclient`. This follows Doom's
[package installation workflow](https://github.com/doomemacs/core/blob/master/docs/getting_started.org#installing-packages-from-external-sources).

After restarting, `C-h v dwindle-mode` should show `t`. Try `C-x 2` to split,
Super+Enter for a disposable terminal, or Super+Shift+Enter for a persistent one.
The first terminal launch may ask you to install Ghostel's native module.

### Local checkout alternative

For development, use the following in `config.el` instead of the GitHub package
declaration and `use-package!` configuration above. Adjust the path as needed:

```elisp
(add-to-list 'load-path (expand-file-name "~/emacs-dwindle"))
(require 'dwindle)
(dwindle-mode 1)
```

Restart Emacs after switching installation methods. This direct local setup needs
no Dwindle `package!` declaration; Ghostel still needs its own installation if you
want terminal shortcuts.

To try the package in a separate Emacs first, run this from the checkout:

```sh
emacs -Q -L . -l dwindle --eval '(dwindle-mode 1)'
```

Run `M-x dwindle-mode` again to disable it. Disabling removes the package's
bindings, hooks, and Evil advice and restores the previous default split function
if dwindle still owns that setting. The current window arrangement remains usable.

## Keys and commands

The bindings are active while `dwindle-mode` is enabled. Here `s` means **Super**,
usually the Windows key on Linux; it is distinct from Emacs's Meta/Alt modifier.
They work in Evil normal and insert states, including Ghostel. Dwindle's map
takes precedence over Evil's state bindings, including Doom's macOS
`+default/newline-below` on Super+Enter and `+default/newline-above` on
Super+Shift+Enter. Disabling Dwindle restores those underlying bindings.

| Operation | Left | Down | Up | Right |
| --- | --- | --- | --- | --- |
| Select window | `s-h` | `s-j` | `s-k` | `s-l` |
| Expand towards edge | `s-H` | `s-J` | `s-K` | `s-L` |
| Shrink from edge | `C-s-h` | `C-s-j` | `C-s-k` | `C-s-l` |

**Super+r (`s-r`) rotates the selected pane's parent split.** It switches
between side-by-side and stacked children, preserving their order and ratio.
It does not rotate the whole screen or merely cycle buffers.

| Open in a new Dwindle split | Key | Command |
| --- | --- | --- |
| Shared `*scratch*` buffer | `s-e` (Super+e) | `dwindle-new-buffer` |
| Fresh disposable Ghostel terminal | Super+Enter | `dwindle-new-terminal` |
| Fresh persistent Ghostel terminal | Super+Shift+Enter | `dwindle-new-persistent-terminal` |

All three select the new pane. `s-e` reuses `*scratch*`, preserving its contents,
major mode, and directory. If that buffer has been killed, Dwindle recreates it
using `initial-major-mode` and the focused buffer's directory.

Each terminal command creates a new shell session and inherits the focused
buffer's `default-directory`: the current file's directory, Dired's directory,
or a terminal's tracked working directory. It uses
[Ghostel's public creation API](https://github.com/dakra/ghostel)
and places the terminal through Dwindle before starting the shell. Ghostel must
be installed (Doom's `:term ghostel` module provides it); Dwindle loads it on demand.
If splitting or terminal initialization fails, the layout is restored and the
partially launched terminal is cleaned up.

Closing a disposable terminal's last displayed pane with `C-x 0`, Evil's `C-w c`
or `:q`, or `dwindle-delete-window` also kills that terminal buffer and session.
Ghostel's configured confirmation checks still apply; declining leaves the pane
open. A persistent terminal stays available through normal buffer switching.
Use `M-x dwindle-toggle-terminal-persistence` in a Dwindle terminal to change its
policy. Its mode line shows `Disposable` or `Persistent` when visible; Doom's
hidden terminal mode line remains hidden. Other terminals are unaffected.
Rotation, workspace restoration, buffer
switching, frame closure, `delete-other-windows`, and programmatic layout changes
do not dispose terminals. If the same terminal is displayed in another pane,
closing one view keeps it running.

`s-H` means Super+Shift+h, and `C-s-h` means Super+Ctrl+h. A window manager that
already grabs these combinations must pass them through to Emacs. Many terminal
emulators do not transmit Super keys; the commands remain available through
`M-x` or another binding.

Use `C-x 2`, `C-x 3`, or `M-x dwindle-split` to add a pane. With Evil, `C-w s`,
`C-w v`, `:split`, and `:vsplit` also use dwindle, including `:split FILE` and
`:vsplit FILE`. The new pane shows the invoking window's buffer and is selected.
Normal window deletion, such as `C-x 0` or Evil's `C-w c`, lets Emacs collapse
the tree. `M-x dwindle-delete-window` additionally refuses to delete the last
ordinary window.

The following commands implement the corresponding BSP operations:

| Command | Behavior |
| --- | --- |
| `dwindle-rotate` | Toggle the parent split's axis; bound to `s-r`. |
| `dwindle-swap` | Exchange the focused node and its sibling. |
| `dwindle-rotate-left`, `dwindle-rotate-right` | Reassociate the binary tree around the parent, as `RotateL` / `RotateR`. |
| `dwindle-focus-parent` | Cycle focus from the selected pane through its managed ancestors, then back to the pane. |
| `dwindle-focus-window` | Return node focus to the selected pane. |
| `dwindle-balance` | Rebuild the focused subtree with shallow splits, choosing axes for its available space. |
| `dwindle-equalize` | Adjust the focused subtree's split ratios to give leaves equal areas. |
| `dwindle-select-node` | Mark the focused node for moving; invoke again to unmark it. |
| `dwindle-move-node` | Move the marked node alongside the currently focused node. |
| `dwindle-split-shift-previous`, `dwindle-split-shift-next` | Reinsert a leaf by splitting its previous/next neighbor, preserving leaf order. |
| `dwindle-move-split-left/right/up/down` | Move an enclosing divider in that direction, as BSP `MoveSplit`. |

Node focus does not change the selected Emacs window. For example, run
`dwindle-focus-parent` until it reports the desired number of panes, then
`dwindle-equalize` or `dwindle-balance`. These two commands do nothing when only
a leaf is focused. Resizing also honors node focus. Splitting a focused internal
node inserts a new pane beside that subtree and toggles its axes, as in BSP.
Successful tree transformations reset node focus and the move mark. Records
are validated against the current native tree before use.

The eight resize commands are `dwindle-expand-left`, `dwindle-expand-down`,
`dwindle-expand-up`, `dwindle-expand-right`, and the corresponding
`dwindle-shrink-*` commands. A positive numeric prefix multiplies the resize step.

Resizing finds the nearest ancestor split on the requested edge. It moves that
divider, so panes sharing that subtree may resize together. Each step is 5% of
the ancestor's size, rounded to columns or lines. Resizing does not push ratios
further beyond the 10–90% limits, subject to Emacs's minimum sizes and fixed-size
restrictions. Existing ratios outside that range are not normalized automatically.

For finer movements when holding a resize key, set `dwindle-resize-step` to
`0.02` (2%). Each command still makes one immediate adjustment, rounded to at
least one column or line. Animated transitions are deliberately omitted:
intermediate sizes trigger extra window hooks and Ghostel terminal resizes and
redraws, which can slow down active shells. No animation timers are installed.

At an outer edge, `ExpandTowards` follows XMonad's specific fallback: it **shrinks
from the opposite edge**. For example, expanding right in the rightmost pane
moves its left divider right and makes that pane smaller. `ShrinkFrom` has no
fallback; it does nothing at an outer edge. With no usable divider, resizing
does nothing. A divider belonging to a foreign window is blocked and does not
trigger the opposite-edge fallback. These semantics follow
[XMonad's BinarySpacePartition implementation](https://github.com/xmonad/xmonad-contrib/blob/master/XMonad/Layout/BinarySpacePartition.hs);
the default 5% step is described in its
[resize documentation](https://xmonad.github.io/xmonad-docs/xmonad-contrib/XMonad-Layout-BinarySpacePartition.html).

These settings can be adjusted before or after enabling the mode:

```elisp
;; Start a fresh tree with its second pane below the first.
(setq dwindle-first-split 'below) ; default: 'right

;; Move an ancestor divider by 3% per resize command.
(setq dwindle-resize-step 0.03)   ; default: 0.05

;; Optional: original dwindle insertion, independent of focused pane.
(setq dwindle-split-policy 'tail) ; default: 'focused (BSP)
```

Changing `dwindle-first-split` affects the next split with no managed parent;
it does not rotate an existing tree.

## Doom, popups, and existing layouts

The mode reads the current layout and splits the focused leaf. It
does not rearrange an existing layout when enabled or from a window hook.
Manual combinations containing three or more siblings remain usable: directional
resizing moves only the adjacent pair, preserving the other siblings. Explicit
tree transformations can turn an entirely Dwindle-owned combination into a binary tree.

Dwindle manages **all windows by default**, including side panels, dedicated
windows, popups, atomic groups, Help and compilation buffers, terminals, and
panes restored with a workspace or Winner. The minibuffer is excluded. A window
becomes eligible immediately; there is no need to split it with a Dwindle command
first. Setting `dwindle-ignore` on a window or an ancestor explicitly excludes it.

Before a Dwindle command operates, it releases application placement restrictions,
dedication, atomic grouping, and custom split/deletion handlers. This keeps the
existing window objects, buffers, scrolling, and geometry. A subsequent explicit
tree transformation may recreate windows as usual. Observation hooks only update
bookkeeping; enabling the mode does not rearrange the screen.

Native side-window and directional display actions also use focused BSP splits.
This includes `emacs-jupyter-notebook` output: its directional display action
otherwise bypasses Emacs's preferred splitter. Output panels left over from its
older side-window implementation are usable too; the next Dwindle command
releases their old restrictions. Reopening a visible output panel reuses it and
preserves manual resizing.

In Doom, the standard stacked-side popup display action opens ordinary Dwindle
panes by default. This brings common popup buffers into the layout before Doom
assigns side-window ownership. Existing popups are adopted when a Dwindle command
runs, including removal of Doom's transient popup buffer lifecycle.

Opening a popup from an ignored sidebar uses an eligible pane. If a split will
not fit, Dwindle reuses an eligible ordinary pane when the display rule permits
it. Doom's Eshell and Vterm toggles also keep their newly routed panes managed.
Requests with no usable pane retain the application's display fallback.

To retain application window ownership while managing every ordinary pane, use:

```elisp
(setq dwindle-manage-windows 'ordinary)
```

This preserves the former `all` behavior: side windows, existing popups,
dedicated panes, atomic groups, custom window handlers, `no-other-window`, and
`no-delete-other-windows` remain boundaries. Doom's standard popups still route
through BSP; also set `dwindle-doom-manage-popups` to `nil` to retain their native
placement and lifecycle. Under `all`, native side display routing and command
adoption apply independently of that Doom-specific option.

For the previous conservative ownership behavior, set:

```elisp
(setq dwindle-manage-windows 'explicit)
```

Under that policy, enabling the mode enrolls only the selected eligible editor
pane in each frame. Explicit Dwindle splits enroll the invoking and new panes;
other windows and special-mode buffers other than Dired stay outside structural
operations. This policy also retains Doom's popup behavior.

Rotate and other tree commands stop at an unowned branch. They still work within
an owned subtree beside it, preserving the outside pane's window object, buffer,
view, and geometry. Closing that outside pane lets native Emacs collapse the
tree; Dwindle checks the resulting boundaries on the next command.

The default `display-buffer` splitter uses dwindle when Emacs asks it to create
a new ordinary window. The resulting pane participates in Dwindle by default.
This path always performs a leaf
split, even when an internal BSP node is focused. Existing `display-buffer-alist`
rules can choose another action, and Emacs may reuse an existing window. Switching
a buffer or opening a file in the current window does not itself create a pane.
Native restoration records for new windows, frames, tabs, and background reuse
remain eligible.
Tree transformations update their window references so `quit-window` can still
close the temporary pane or restore its previous buffer and selection. Native
frame/tab close behavior is retained. Unknown record formats remain protected
under the `ordinary` and `explicit` policies.
These cases follow Emacs's
[quit-restore record format](https://www.gnu.org/software/emacs/manual/html_node/elisp/Quitting-Windows.html).

Evil integration wraps its two split commands outside Doom's overrides, retaining
Evil's argument parsing and file-opening behavior. An explicitly sized Evil
split, such as `:10split`, retains Doom/Evil's native behavior. Direct calls to
the low-level `split-window` function also retain native behavior. This allows
other packages to create layouts that have their own requirements.

Workspace restoration and Winner undo can replace the native window tree.
Dwindle reads the current tree before operating, so it does not depend on window
objects from a previous workspace. Previously owned objects revived by a saved
configuration retain their eligibility; replacement ordinary windows are
automatically enrolled under the default policy. `(dwindle-root-window)` returns the current
frame root (the main root under conservative policies), which may be an internal
window; `(dwindle-master-window)` returns the first managed live leaf. Both accept
an optional frame.

Explicit tree transformations recreate native window objects inside their
owned region, while retaining buffers, points, scrolling, history, and window
presentation. All outside windows must keep their identities and geometry.
Emacs has no public API to rotate a split while preserving every window object.
Packages retaining raw references to ordinary panes can lose those references
after an explicit tree transformation. Use the `explicit` policy for conservative
ownership, or set a pane's `dwindle-ignore` parameter to exclude it. Node focus
has minibuffer feedback;
there is no XMonad-style graphical border around the focused subtree.

Transparent gaps with opaque pane backgrounds are not implemented. Stock macOS
Emacs paints its dividers inside one frame; whole-frame `alpha` also fades the
panes ([NS renderer](https://github.com/emacs-mirror/emacs/blob/master/src/nsterm.m)).
Some builds offer selective fringe transparency, such as the
[Emacs Plus transparency patch](https://github.com/d12frosted/homebrew-emacs-plus/blob/master/community/patches/frame-transparency/README.md),
but this is not a complete transparent-divider solution and would require
testing on that specific macOS build.

## Bounded window operations

Emacs owns the window tree and the promotion of surviving children after a
deletion, as described in the
[GNU Emacs Lisp manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Windows-and-Frames.html).
Dwindle refreshes its root/master references from that tree. Its window-change
hook only observes windows; it never splits, deletes, resizes, or redisplays them.

An ordinary insertion attempts one native split. If the focused pane is too small, the
interactive command reports an error and automatic display returns control to
Emacs's normal fallback. It does not repeatedly retry, borrow space from the
master, or rebuild the layout. A reentry guard prevents recursive insertions
from display hooks. Failed operations restore the original native configuration,
window parameters, and views, including failures occurring before a native split
returns. Rollback does not call application deletion handlers and temporarily
suppresses buffer-list callbacks that could interrupt restoration. The hook
values are restored afterward. Resizing walks a finite ancestor chain and
attempts one native edge movement.

Tree transformations preflight available space before mutation, then verify the
result and outside windows before committing. A mismatch rolls back. Buffer text
edits or other external effects made by arbitrary application hooks cannot be
undone by a window transaction. Emacs's minimum sizes and fixed-size restrictions
still apply; there is no automatic overflow stack when a split does not fit.

The [Astra adversarial review](docs/adversarial-review.md) records the callback
failures found and repaired, interference tests, and remaining limits.
The later [window-management review](docs/window-management-review.md) covers
automatic enrollment, common Doom displays, and native quit behavior across
tabs and frames.

## Validation

Run the automated checks from this directory:

```sh
make test
make check
make smoke
```

If `make` is unavailable, run the test recipe directly:

```sh
timeout -k 5s 60s emacs --batch -Q -L . -L test \
  -l test/dwindle-tests.el -l test/dwindle-tree-tests.el \
  -l test/dwindle-ownership-tree-tests.el -l test/dwindle-doom-tests.el \
  -l test/dwindle-terminal-tests.el -l test/dwindle-evil-tests.el \
  -f ert-run-tests-batch-and-exit
```

The tests run in disposable batch Emacs processes with an external timeout.
The four Evil integration tests skip when Evil is absent from `load-path`; add
`-L /path/to/evil` and paths for its dependencies to run them. They cover normal
and insert key conflicts, mode toggling, scratch invocation, and delayed Evil
loading. The optional real Doom popup test uses the installed `ui/popup` module;
set `DWINDLE_DOOM_POPUP_DIR` to its directory if it is not found automatically.
It runs in a disposable Emacs process, including delayed loading and normal
popup behavior after disabling Dwindle. `make check` also checks byte compilation.
Evil/Doom command integration was
additionally smoke-tested in a disposable batch Emacs using the installed Evil
package and Doom's actual split overrides: Ex file arguments, read-only splits, advice
precedence, delayed Evil loading, key resolution, and disabling the mode.
This does not replace testing a full graphical Doom session with your own
window-manager bindings and popup rules.

The terminal commands were also checked against installed Ghostel and its native
module, Evil, and evil-ghostel in a disposable Emacs process: terminal shortcuts
resolved in normal and insert states despite Doom's macOS newline bindings;
separate shell processes started in the focused directory; disposable close terminated its
process; persistent close retained it; declined `:q` left the session open; and
an injected startup failure cleaned up the new process and restored the layout.

`make smoke` runs a separate terminal Emacs through 100 split/delete/resize
operations and 10 rotations, including real redisplay hooks, and checks native
quit focus across two frames after rotation. It runs under an external timeout
and needs the `script` command from util-linux. Without `make`, run
`sh test/run-redisplay-smoke.sh`.
