# Adversarial compatibility review

This is a historical review. The later broad-management change makes automatic
enrollment the default; the private provenance policy described below remains
available as `(setq dwindle-manage-windows 'explicit)`. Standard ordinary
`quit-restore` records are now preserved and remapped during reconstruction.
See the README for the current ownership and Doom popup behavior.

Reviewed on 2026-09-09 by Astra, using extra-high reasoning, in an independent
review agent. Runtime probes used GNU Emacs 30.2 in disposable processes. Every
Emacs invocation had an external timeout; the user's running Emacs was untouched.

The initial implementation had reproducible callback failures, including loss of
an existing pane during rollback. The new BSP transformations initially introduced
a recursive buffer-hook path that could make Emacs unresponsive. These findings
were fixed during the review and independently rechecked. A subsequent review
replaced blanket adoption of ordinary panes with private ownership tracking,
requiring no changes or flags from other packages. It also found and corrected
two ways application callbacks could be overwritten during reconstruction.
No unresolved hang, stale-root, or reconstruction across an unowned pane was
reproduced in the final bounded probes. Existing-pane reuse has an unavoidable
ambiguity described below; this is not a guarantee about arbitrary third-party Lisp.

## Scope

Reviewed `dwindle.el`, `dwindle-resize.el`, `dwindle-doom.el`, the README, and the
existing test suite, then reviewed the added `dwindle-tree.el` and its tests.
Probes covered manual/native splits, combinations with more than two children,
mixed ordinary/application trees, all four side-window positions, dedicated and
atomic windows, application parameters, fixed sizes, external resize/deletion,
serialized `window-state-put`, actual Winner undo/redo, reentrant callbacks, and
repeated mode lifecycle changes.

The final pass also exercised focused insertion, parent focus, Rotate, Swap,
RotateL/RotateR, Equalize, Balance, SelectNode/MoveNode, and SplitShift alongside
external changes. Native Emacs function documentation and installed `window.el`
and `winner.el` sources were used to verify callback and restoration behavior.

## Findings and resolutions

Severity describes the original behavior: **P1** means a credible loss of window
state or responsiveness; **P2** means a broken operation or incomplete rollback.

### P1: private BSP buffer creation allowed recursive tree operations — fixed

The initial `dwindle--tree-apply` created its private working buffer before binding
the reentry guard or entering cleanup. `generate-new-buffer` runs
`buffer-list-update-hook`. A hook invoking `dwindle-rotate` therefore entered
another transformation and created another private buffer.

A bounded reproduction installed a buffer-list hook that called `dwindle-rotate`,
aborting after eight invocations. All eight saw `dwindle--inhibit` equal to nil;
eight private buffers accumulated. The review deliberately stopped before Lisp's
recursion limit or the external timeout.

The guard now covers private buffer creation, the transformation, and cleanup;
private buffer creation/deletion suppress buffer-list callbacks. Rechecking with
a hook attempting recursive rotations completed with two guarded callbacks, two
live panes, and no private buffers left behind.

Permanent regression:
`dwindle-tree-private-buffer-hooks-cannot-reenter-or-leak`.

### P1: rollback could delete an existing atomic sibling — fixed

Start with two ordinary panes and split the selected pane into a different buffer.
Give the destination buffer this local scroll hook:

```elisp
(setq-local window-scroll-functions
            (list (lambda (window _start)
                    (window-make-atom (window-parent window))
                    (error "Application setup failed"))))
```

The hook made the old pane and new pane an atomic group before failing. The old
rollback called `delete-window` on the new pane; native atomic semantics deleted
the entire group. The observed result was two original panes becoming one, with
the selected original pane dead.

Rollback now restores a native window configuration instead of deleting the new
pane. It also restores original window parameters and views. Rechecking preserved
both original window objects, their geometry, and selection.

Permanent regression:
`dwindle-buffer-local-hook-cannot-poison-rollback-or-delete-old-windows`.

### P2: native split errors left orphan panes — fixed

`split-window` runs scroll hooks after creating its native window but before
returning it. This reproduction originally signaled an error while changing the
window count from one to two:

```elisp
(let ((window-scroll-functions
       (list (lambda (_window _start) (error "Application scroll failed")))))
  (condition-case nil (dwindle-split) (error nil)))
```

The caller never received the new window, so its deletion-based cleanup skipped
it. With `display-buffer-pop-up-window`, Emacs tried another candidate: the
operation returned nil after changing one pane into three.

The configuration transaction is captured before calling `split-window`, so it
can restore the layout even when native code creates a pane and then signals.
Explicit splitting, the preferred splitter, and actual automatic display were
rechecked.

Permanent regression:
`dwindle-synchronous-native-split-hook-failure-leaves-no-orphan`.

### P2: an application deletion handler could prevent rollback — fixed

A destination buffer's local scroll hook installed
`(set-window-parameter window 'delete-window #'ignore)` and then signaled an
error. The original cleanup obeyed that handler, leaving the half-initialized pane
in place. Configuration restoration bypasses application deletion handlers and
removed the partial layout in the repeated probe.

This case is included in
`dwindle-buffer-local-hook-cannot-poison-rollback-or-delete-old-windows`.

### P2: rollback itself could fail through buffer-list hooks — fixed

Although `set-window-configuration` did not synchronously run the tested scroll,
configuration, size, buffer-change, or selection hooks, it did run
`buffer-list-update-hook`. A throwing hook interrupted cleanup after topology
restoration, before parameter and view repair.

A simple dynamic binding of that hook was insufficient: restoring a configuration
can select another buffer with its own local hook. The reproduction saved a
configuration showing buffer A, changed the selected pane to B, split it, and
installed throwing default and A-local hooks before signaling the original error.

Failed-operation rollback now temporarily suppresses both the default hook and
existing buffer-local values, then restores those values in cleanup. Independent
verification confirmed the original error was preserved, no hostile hook ran,
the original panes/parameters/selection returned, and both hook values remained
unchanged after rollback.

Permanent regression:
`dwindle-rollback-suppresses-and-restores-buffer-local-and-global-hooks`.

### P2: deletion could reenter an unfinished split — fixed

The original split guard protected insertion, but `dwindle-delete-window` could
still run from a scroll callback during insertion and delete an existing selected
pane. Explicit deletion now checks the shared guard and uses the transaction.
The repeated real-scroll-hook probe produced an operation-in-progress error and
preserved both original panes and selection.

### P1: reconstruction erased an application's ownership claim — fixed

During the ownership follow-up, a destination buffer's local scroll hook installed
a valid native lifecycle record:

```elisp
(set-window-parameter window 'quit-restore
                      (list 'window 'window window (window-buffer window)))
```

The old restoration order called `set-window-buffer`, ran that hook, then cleared
all window parameters. Rotation succeeded, deleted the original pane, erased the
application's record, and enrolled the replacement as Dwindle-owned. Global hooks
claiming the temporary anchor or a newly split pane exposed the same problem.

Restoration now checks the destination before clearing metadata, restores saved
parameters before initializing its buffer, and validates application eligibility
afterward. Checks also surround temporary buffer initialization and native splits.
The independent reproduction now aborts and restores the original window objects.

Permanent regressions: `dwindle-tree-scroll-hook-ownership-marker-is-never-erased`,
`dwindle-tree-temporary-buffer-hook-claim-aborts-before-clearing`, and
`dwindle-tree-split-hook-claim-aborts-before-restoring-view`.

### P2: unmarked takeover of a temporary pane was silently overwritten — fixed

A global scroll hook replaced the renderer's private buffer with an ordinary
application buffer using `set-window-buffer`, without setting any ownership
parameter. Reconstruction previously overwrote that buffer with its captured
editor buffer and committed.

The renderer now verifies the exact expected buffer before further mutation and
after initialization/splitting. The marker-free reproduction aborts and restores
the original layout. Its permanent regression is
`dwindle-tree-unmarked-buffer-takeover-is-not-overwritten`.

## Automatic ownership boundary

Other packages need no Dwindle-specific flags or integration code. Structural
ownership is recorded privately by window identity:

- Enabling the mode enrolls only the selected eligible editor pane in each frame.
- An explicit Dwindle split enrolls the invoking pane and its new pane. The tail
  policy does not enroll an unrelated native tail merely because it was split.
- Preexisting siblings and raw native/package-created panes remain unowned,
  including ordinary panes with no identifying parameters.
- Automatic display-created panes remain unowned. Automatic display always uses
  a leaf split, even when an internal BSP node is focused.
- Reconstruction stops at unowned panes. Owned regions beside them retain Rotate,
  Swap, Equalize, Balance, and other BSP operations.
- Recognized application takeover revokes ownership. Dedicated, atomic, side,
  application-handler and special-mode state are checked automatically; Dired
  remains eligible as an ordinary navigation buffer.
- Saved configurations may revive previously owned objects. Unknown replacement
  objects created by `window-state-put` are not enrolled by observation.

Native `quit-restore` needs interpretation, not a blanket exclusion. Normal file
navigation also creates that parameter. The implementation allows a validated
existing-buffer restoration record for the same selected window; pane/frame/tab
deletion lifecycle records and background-window reuse remain protected. A
reconstructed pane's ordinary self-navigation reference is remapped to its new
window object. File navigation, continued splitting, and rotation were rechecked;
the public rotate binding is **`s-r`**, without Shift.

This boundary concerns reconstruction and object replacement. Ordinary native
splitting and divider resizing retain window objects and can intentionally alter
the geometry of eligible ordinary panes, including unmarked panes.

## Validation record

The original 28 tests passed before adversarial probing, demonstrating why the
additional callback cases mattered. The final independent combined run passed
**81 repository tests**, including all regression tests named above, ownership
boundaries, normal file navigation, and tree transformations. This was the suite
size at review time; later additions may increase it.

Additional independent probes passed:

- All four side-window positions survived ordinary split, resize, and deletion.
- Native three-way layouts were adopted without automatic reconstruction; final
  pair resizing preserved unrelated ordinary and application-owned siblings.
- A dedicated branch prevented crossing its boundary while resizing inside an
  adjacent managed subtree remained usable.
- Fixed width in a descendant of the neighboring subtree prevented inappropriate
  resizing.
- Serialized `window-state-put` and actual Winner undo/redo restored layouts that
  remained usable by subsequent Dwindle commands.
- Forty repeated enable/disable cycles left no duplicate integrations.
- **1,500 deterministic mixed external operations** completed on the baseline:
  native/Dwindle splits, deletions, resize, balance, state restoration, popup and
  dedication changes, and mode toggles. There were 106 expected refusals, with
  live root/master references verified after every step.
- **2,000 deterministic mixed BSP/external operations** completed after the
  initial BSP implementation in about 0.68 seconds: the same external disturbances combined
  with the new tree commands. There were 224 expected refusals, no stale root or
  master, and no leaked private working buffers.
- **1,000 additional mixed operations after the ownership changes** preserved an
  unmarked native pane throughout. Every structural attempt also checked all
  currently unowned panes for preserved identity, buffer, and pixel edges. Of 158
  structural attempts, 82 completed, including safe no-ops; 76 were safely refused.
  No private working buffers leaked.
- Eight independent ownership probes passed, covering automatic display with
  internal focus, tail provenance, recognized takeover and explicit reenrollment,
  state replacement versus known-object restoration, useful BSP operations beside
  an opaque pane, and both newly discovered callback takeovers.

The independent fuzz seeds were `astra-native-window-stress` and
`astra-bsp-and-external-windows`, followed by
`astra-private-ownership-mixed-tree`. Review-time probe files were kept under `/tmp`;
the permanent regression coverage is in the repository's test files.

Separate implementation validation also passed byte compilation with warnings
treated as errors, a terminal smoke run with 100 split/delete/resize steps,
10 rotations and 99 real window-hook calls, and a smoke run using installed Evil
with Doom's actual split overrides, including the resolved `s-r` binding.

To rerun the repository coverage in a disposable process:

```sh
timeout -k 2s 45s emacs -Q --batch -L . -L test \
  -l test/dwindle-tests.el -l test/dwindle-tree-tests.el \
  -f ert-run-tests-batch-and-exit
```

## Remaining compatibility limits

Ordinary splits and deletions preserve surviving native window objects. Explicit
BSP transformations reconstruct the chosen managed region and can replace its
window objects. The private ownership boundary automatically protects unknown
panes from that reconstruction. Outside windows are checked for preserved
identity, geometry, buffer, and view.

A different case remains intrinsically ambiguous: a package can reuse an already
owned editor pane to show an ordinary buffer, with no distinguishable application
state. That is observationally identical to normal buffer navigation. An actual
probe confirmed that such reuse retains ownership, and a subsequent rotation can
replace that pane's object while preserving its buffer. Protecting every such
buffer change would also prevent normal editing workflows from continuing to use
BSP. No public Emacs 30 API was found for arbitrary tree rotation/reparenting that
preserves every leaf object; `window-swap-states` exchanges displayed state and is
not equivalent. This limit must not be presented as universal package safety,
and does not impose a flag-setting requirement on packages.

Arbitrary internal-node metadata is not migrated through explicit reconstruction
of an owned region. Automatically detected application ancestors and unknown
panes prevent reconstruction across their boundaries.

Rollback restores window layout and recorded views. It cannot undo arbitrary
buffer text edits, killed buffers, external actions, in-place mutations of objects
stored inside parameter values, or a third-party hook that never returns. The
reentry guard prevents recursive Dwindle mutations; it cannot make unrelated Lisp
code terminate. Tests used Emacs 30.2, so Emacs 28/29, graphical pixel geometry,
and a complete live Doom/workspace session remain outside this independent pass.

## 2026-09-10: fresh buffers and terminal lifetime review

This follow-up reviewed only the new creation helper and terminal lifecycle
integration. The September 9 results above remain the historical layout review.
The extension adds `s-E` for a fresh empty buffer, Super+Enter for a new disposable
Ghostel terminal, Super+Shift+Enter for a new persistent terminal, and a command to
toggle persistence. New panes inherit the focused buffer's directory.

The scope included creation errors, synchronous callbacks, cleanup order,
Ghostel's normal kill queries, shared terminal views, explicit versus programmatic
closure, reconstruction/restoration, and Evil's close behavior. Production fixes
were made by the implementation agents and independently rechecked.

### Findings corrected during this follow-up

**Creation could reenter through the final selection callback.** The helper
temporarily disabled the insertion guard around `dwindle-split`; that command's
final `select-window` ran after the inner guard unwound. A real
`buffer-list-update-hook` could recursively open another fresh buffer. A bounded
probe observed six nested creations and seven panes before its injected stop.
The helper now calls the non-selecting split function during that allowance and
selects under the outer guard. The public split command also guards its final
selection. Independent repetition observed four callbacks, zero unguarded
callbacks, and exactly one added pane. Regression:
`dwindle-final-selection-hooks-cannot-reenter-window-creation`.

**A failed initializer's cleanup error could hide the original error and leak its
new process.** A throwing first kill hook prevented later cleanup, leaving the
new buffer and process alive after the window layout was restored. Failed-launch
cleanup now runs the remaining cleanup hooks, reports their failures, and attempts
to remove only the fresh buffer while preserving the initializer's original
error. A separate probe found that a hook changing the current buffer could make
later Ghostel cleanup read another buffer's local variables; each hook now runs
with the fresh buffer current. Repetition preserved the original failure, ran
the later cleanup hook, removed the new buffer/process, and restored the original
layout. Regression:
`dwindle-failed-terminal-cleanup-continues-after-a-throwing-kill-hook`.

**An exceptional terminal query could trigger Evil's frame-close fallback.**
Returning nil from a query was handled, but a query signaling an ordinary error
still escaped after successful rollback. Evil `:q` can interpret that error as a
request to close a frame, tab, or Emacs. The wrapper now reports errors from an
initially eligible disposable pane close without invoking that fallback, while
preserving normal last-frame behavior. Rechecking confirmed no fallback, unchanged
layout, and a live terminal process. Regressions:
`dwindle-terminal-evil-query-error-cannot-trigger-frame-fallback` and
`dwindle-terminal-evil-native-error-cannot-trigger-frame-fallback`.

**Native deletion changed the current buffer before Ghostel cleanup.** The first
kill hook deletes the pane only after all normal queries have accepted. The
implementation's actual Ghostel smoke discovered that this deletion selected the
editor buffer, so Ghostel's subsequent cleanup read the wrong buffer-local process
state. The deletion hook now preserves the current buffer and performs native
deletion only once. Independent native-PTY testing confirmed cleanup runs in the
terminal buffer and both the shell and its asynchronous lifecycle pipe exit.
The lifecycle regression also checks the cleanup hook's current buffer:
`dwindle-terminal-interactive-close-runs-query-before-losing-pane`.

The terminal implementation additionally confines close permission to the
intended pane and prevents nested application callbacks from inheriting it.
Permanent tests cover both an unrelated deletion inside Evil's close wrapper and
a nested deletion from a native application handler.

### Final evidence and lifetime boundary

The independent combined suite passed **106 tests**, including 18 terminal
lifecycle tests. Those tests use real Emacs buffer/process machinery with pipe
processes; that alone was insufficient to establish Ghostel's native cleanup
behavior, so a separate native test was required.

The independent native smoke used installed Ghostel 0.53.0 and its matching module
in a disposable Emacs 30.2 process, under a 25-second external timeout. It created
two real `/bin/sh` children and verified:

- The shell's working directory via `/proc/PID/cwd`.
- A declined normal Ghostel query preserves the pane and running shell.
- An accepted close runs cleanup in the terminal buffer, removes that buffer,
  and eventually removes both the child PID and its lifecycle pipe.
- Closing a persistent pane leaves its terminal running.
- Reopening, toggling persistence, and closing one of two views preserves the
  shared shell.
- Interactive rotation and `window-state-put` preserve the native PTY.
- Explicitly closing the final disposable view terminates the session.

The native smoke completed in about 0.19 seconds; its review-time artifact was
`/tmp/dwindle-native-lifecycle-adversarial.el`. The implementation's separate
installed-Evil/Ghostel smoke also passed actual `:q` refusal and acceptance, plus
an injected error after native process startup with successful cleanup.

Disposal applies only to terminals created by Dwindle and an explicit close of
their last live pane. Ordinary hiding, programmatic deletion, mode disabling,
workspace/layout restoration, and BSP reconstruction preserve sessions. Existing
terminals from other packages are excluded. Normal successful-session close
queries and Ghostel cleanup remain authoritative; the special best-effort cleanup
is restricted to a newly created buffer whose launch failed.

The native event pipe may remain live briefly after buffer deletion while the
child reaper finishes; bounded waiting verified termination rather than treating
that normal delay as a leak. As with the earlier review, arbitrary hook side
effects cannot be undone after they have terminated a process. No unresolved
accidental-disposal or recursive-creation defect was reproduced in the final
scoped probes.
