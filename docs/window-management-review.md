Astra adversarial review (maximum reasoning), 2026-09-10.

Historical scope: this review predates the subsequent notebook/all-window fix.
Its ownership exclusions now describe `dwindle-manage-windows` set to `ordinary`.
The default `all` policy also adopts application windows; see the current
[window-management documentation](../README.md#doom-popups-and-existing-layouts)
and `test/dwindle-all-windows-tests.el` for that behavior.

The final changes passed this bounded review. The default policy now admits
ordinary native, package-created, restored, and special-mode panes. Doom's
standard popup path creates ordinary panes, and the concrete escape paths found
during review were corrected. This does not mean every Emacs window is managed.

The review examined the uncommitted ownership, reconstruction, Doom popup, and
terminal-toggle changes. Probes ran in disposable Emacs 30.2 processes, using
installed Doom, Evil, and Magit sources where noted. The running Emacs session
and user configuration were not changed.

The five reproduced defects below were P2 workflow/lifecycle failures and are
now fixed.

| Reproduction and impact | Final behavior |
| --- | --- |
| Request a standard Doom popup while an existing protected side pane has focus. The request created another unmanaged popup despite available editor space. | Routing chooses an ordinary pane on the same frame, preserving the protected origin and its selection preference. |
| Request a popup from a pane too small for the next BSP split. Falling back immediately to Doom created an unmanaged side pane. | Routing can reuse an eligible ordinary pane, honoring `inhibit-same-window`. |
| Run Doom's `+eshell/toggle` or `+vterm/toggle`. Each command added dedication after successful popup routing, immediately excluding the new pane. | A command-scoped wrapper removes that final dedication only from panes routed by the adapter and still showing the same buffer. |
| Use native `display-buffer-in-tab`, then split or navigate to another buffer. The native tab record excluded the pane, even after ordinary navigation. Frame display records had the same exclusion. | Validated native tab/frame records remain eligible, retain their lifetime type, and survive reconstruction. Native tab quitting still closes its tab. |
| Open a buffer in another frame, rotate its originating tree, select another source pane, then quit the displayed buffer. Its return record referenced the dead source window, so focus returned to the wrong pane. | Native return references in other live frames are remapped. An actual terminal-frame recheck restored the exact reconstructed source. |

The broader team also corrected two integrity gaps: native-looking restoration
records on internal combinations remain application boundaries (P3), and popup
display/cleanup/selection callbacks run within the guarded transaction (P2). A
callback that claims a pane, changes the layout, or fails cannot commit a stray
managed popup. Changes to remote return records are rolled back when the local
tree transaction fails.

Independent final evidence:

- **145/145 repository tests passed**, with installed Evil and the real Doom
  integration subprocess; no tests were skipped.
- Native tab display, ordinary navigation, splitting, rotation, and tab quitting
  passed. Permanent tests also cover both `frame` and `same` restoration records.
- Real Doom Eshell commands with real `eshell-mode` remained managed. Real Doom
  Vterm toggle/display commands passed with the Vterm process initializer
  substituted; this pass did not launch its native terminal backend.
- Installed Magit 4.7.0 opened status and revision buffers using Doom's actual
  display functions in a temporary Git repository. Both remained managed through
  rotation; `magit-mode-bury-buffer` left the remaining panes usable.
- Disposable terminal frames passed return-focus checks before and after source
  reconstruction. Native quit used its normal frame auto-hide behavior. A
  separate ownership-agent probe verified restoration of the original remote
  record and layout after failure following remapping.
- Popup requests from protected origins and cramped ordinary panes passed their
  focused probes. Existing tests cover native/sized splits, Help, compilation,
  restored layouts, opt-outs, and callback failures.

The review probes were `/tmp/dwindle-astra-common-probe.el`,
`/tmp/dwindle-astra-magit-probe.el`, and
`/tmp/dwindle-astra-frame-probe.el`. Permanent regressions are in
`test/dwindle-ownership-tree-tests.el`, `test/dwindle-doom-tests.el`, and the
terminal redisplay smoke. The test recipe in `Makefile` reruns the repository
coverage.

Deliberate exceptions remain: native side windows, existing Doom popups, custom
popup actions, independently dedicated panes, atomic groups, application window
handlers, and explicit exclusion parameters. Standard popup routing also retains
Doom's fallback when no eligible ordinary pane can satisfy the request. Existing
popups need closing and reopening to enter the new path; the conservative
`explicit` policy and popup opt-out remain available.

This pass did not validate a complete interactive Doom workspace session,
graphical frame geometry, Emacs 28/29, every terminal backend, or every package.
Explicit tree transformations still replace ordinary window objects; arbitrary
package references outside recognized native restoration records are not
automatically migrated. No further blocking defect was reproduced within the
tested scope.
