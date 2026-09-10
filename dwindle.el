;;; dwindle.el --- Dwindling window trees for Emacs and Doom -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: convenience, windows

;;; Commentary:

;; Enable `dwindle-mode' to split the focused ordinary window, alternating
;; axes as in XMonad BSP.  Emacs owns the tree: deleting a window promotes its
;; surviving sibling, without recreating any other live windows.  We only
;; observe window changes, never rebuild layouts during redisplay.
;;
;; Super-h/j/k/l moves focus; add Shift to expand or Control to shrink.
;; See README.md and doom/config.el for Doom configuration.

;;; Code:

(require 'cl-lib)
(require 'windmove)

(declare-function ghostel-create "ghostel" (&optional name display identity))
(declare-function dwindle-doom--release-popup "dwindle-doom" (buffer))
(defvar dwindle-terminal-managed)
(defvar dwindle-terminal-disposable)
(defvar dwindle--terminal-close-permitted)
(defvar dwindle--terminal-close-target)

(defgroup dwindle nil
  "Dwindling window trees with directional resizing."
  :group 'windows
  :prefix "dwindle-")

(defcustom dwindle-first-split 'right
  "Direction of the first dwindle split.
Later splits alternate axes, proceeding toward the bottom right.
Changing this option only affects a tree with no managed parent split."
  :type '(choice (const right) (const below))
  :group 'dwindle)

(defcustom dwindle-split-policy 'focused
  "Where to insert a new window.
`focused' follows XMonad BSP, splitting the focused window.  `tail'
retains the original dwindle chain by splitting its trailing leaf."
  :type '(choice (const focused) (const tail))
  :group 'dwindle)

(defcustom dwindle-manage-windows 'all
  "Which windows participate in Dwindle's BSP operations.
`all' includes side windows, dedicated panes, popups, atomic groups, and
application windows.  Dwindle commands release their placement and window
handlers before operating on them.  Native side and directional display
actions use BSP splits.  Existing layouts are not rearranged on enrollment.

`ordinary' manages existing ordinary windows, including special-mode
buffers, native splits, and workspace restoration, while respecting
application ownership, dedication, side windows, and atomic groups.

`explicit' restores conservative ownership: only the initially selected
editor pane and explicit Dwindle splits are enrolled, and special-mode
buffers other than Dired are excluded.

All policies exclude the minibuffer and respect `dwindle-ignore' on a
window or its ancestor.  Explicit tree commands may recreate panes."
  :type '(choice (const :tag "All windows" all)
                 (const :tag "Ordinary windows" ordinary)
                 (const :tag "Only explicit Dwindle panes" explicit))
  :group 'dwindle)

(defvar dwindle-mode)
(defvar dwindle--inhibit nil
  "Non-nil while a dwindle split is in progress.
This prevents display hooks from recursively creating dwindle windows.")
(defvar dwindle--installed nil
  "Whether dwindle's global integration is installed.")
(defvar dwindle--previous-splitter nil
  "Default splitting function saved when enabling `dwindle-mode'.")
(defvar dwindle--owned-windows (make-hash-table :test #'eq :weakness 'key)
  "Private record of panes enrolled for BSP reconstruction.
With `dwindle-manage-windows' set to `all', eligible panes are enrolled
automatically.  The `explicit' policy requires known provenance.")
(defvar dwindle--automatic-display nil
  "Non-nil while providing a leaf split to an external display action.
Internal node focus must not cause reconstruction during automatic display.")
(defvar dwindle--defer-popup-cleanup nil
  "Non-nil when an enclosing transaction will finish popup adoption.")
(defvar dwindle--pending-popup-buffers nil
  "Popup buffers whose lifecycle can be released after successful adoption.")

(defun dwindle--navigation-record-p (record window)
  "Whether RECORD describes ordinary buffer navigation within WINDOW.
Native `quit-restore' records also describe temporary window/frame/tab
lifecycles.  Permit only a standard existing-buffer restoration record
whose previously selected window is WINDOW itself.  This is the subset
accepted by the `explicit' policy and identifies self-references that
must follow a pane when its view is copied during reconstruction."
  (pcase record
    (`(,(or 'same 'other) (,old-buffer ,start ,point ,size)
       ,previous-window ,buffer)
     (and (bufferp old-buffer) (number-or-marker-p start)
          (number-or-marker-p point) (numberp size)
          (eq previous-window window) (bufferp buffer)))))

(defun dwindle--restorable-record-p (record)
  "Whether RECORD is standard native `quit-restore' bookkeeping.
Native window, frame, tab, and reuse records do not prevent management.
Their close behavior is retained.  Conservative policies protect unknown
formats."
  (pcase record
    (`(,(or 'same 'other) (,old-buffer ,start ,point ,size)
       ,previous-window ,buffer)
     (and (bufferp old-buffer) (number-or-marker-p start)
          (number-or-marker-p point) (numberp size)
          (windowp previous-window) (bufferp buffer)))
    (`(,kind ,type ,previous-window ,buffer)
     (and (memq type '(window frame tab))
          (or (eq kind 'same) (eq kind type))
          (windowp previous-window) (bufferp buffer)))))

(defun dwindle--foreign-window-p (window)
  "Return non-nil when valid WINDOW carries application ownership markers.
This also accepts internal windows, whose parameters protect a whole
subtree.  `dwindle-ignore' is an optional user override, not an integration
requirement for packages."
  (or (window-parameter window 'dwindle-ignore)
      (window-parameter window 'window-side)
      (window-parameter window 'popup)
      (let ((record (window-parameter window 'quit-restore)))
        (and record
             (not (and (window-live-p window)
                       (if (memq dwindle-manage-windows '(all ordinary))
                           (dwindle--restorable-record-p record)
                         (dwindle--navigation-record-p record window))))))
      (window-parameter window 'no-other-window)
      (window-parameter window 'no-delete-other-windows)
      (cl-some (lambda (parameter)
                 (functionp (window-parameter window parameter)))
               '(split-window delete-window delete-other-windows))))

(defun dwindle--explicitly-ignored-window-p (window)
  "Whether valid WINDOW or an ancestor explicitly opts out of Dwindle."
  (let ((node window) ignored)
    (while (and node (not ignored))
      (setq ignored (window-parameter node 'dwindle-ignore)
            node (window-parent node)))
    ignored))

(defun dwindle--ignored-window-p (window)
  "Whether WINDOW is excluded, including a group containing an ignored pane.
Native atomic and side-window groups share restrictions.  Keep such a
group intact if any of its leaves explicitly opts out."
  (or (dwindle--explicitly-ignored-window-p window)
      (let ((group (window-atom-root window))
            (node window))
        (while node
          (when (memq (window-parameter node 'window-side)
                      '(left right top bottom))
            (setq group node))
          (setq node (window-parent node)))
        (and group
             (cl-some #'dwindle--explicitly-ignored-window-p
                      (dwindle--subtree-windows group))))))

(defun dwindle--managed-window-p (window)
  "Return non-nil if live WINDOW participates in the current policy.
This predicate only observes windows; commands release application
restrictions with `dwindle--prepare-frame' before changing the layout."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (dwindle--ignored-window-p window))
       (or (eq dwindle-manage-windows 'all)
           (and (not (window-dedicated-p window))
                (not (window-atom-root window))
                (let ((node window) foreign)
                  (while (and node (not foreign))
                    (setq foreign (dwindle--foreign-window-p node)
                          node (window-parent node)))
                  (not foreign))))))

(defun dwindle--reconstruction-eligible-p (window)
  "Whether ordinary WINDOW is suitable for a structural BSP operation.
The `explicit' policy excludes special-mode buffers other than Dired.
The other policies include special-mode buffers."
  (and (dwindle--managed-window-p window)
       (or (memq dwindle-manage-windows '(all ordinary))
           (with-current-buffer (window-buffer window)
             (or (not (derived-mode-p 'special-mode))
                 (derived-mode-p 'dired-mode))))))

(defun dwindle--owned-window-p (window)
  "Whether WINDOW participates in BSP reconstruction.
Check eligibility on demand so a newly opened or restored pane is usable
even before the next window configuration hook."
  (and (window-live-p window)
       (if (dwindle--reconstruction-eligible-p window)
           (or (gethash window dwindle--owned-windows)
               (and (bound-and-true-p dwindle-mode)
                    (memq dwindle-manage-windows '(all ordinary))
                    (not dwindle--inhibit)
                    (puthash window t dwindle--owned-windows)))
         (remhash window dwindle--owned-windows)
         nil)))

(defun dwindle--claim-window (window)
  "Internally enroll eligible WINDOW and return it, or return nil."
  (when (dwindle--reconstruction-eligible-p window)
    (puthash window t dwindle--owned-windows)
    window))

(defun dwindle--forget-window (window)
  "Forget Dwindle's private structural ownership of WINDOW."
  (remhash window dwindle--owned-windows))

(defun dwindle--initialize-frame (frame)
  "Enroll FRAME's windows according to `dwindle-manage-windows'."
  (when (frame-live-p frame)
    (dwindle--claim-window (frame-selected-window frame))
    (dwindle--refresh frame)))

(defun dwindle--windows (&optional frame)
  "Return FRAME's managed leaves in native tree order.
The order always starts at the first leaf, independent of focus."
  (let ((frame (or frame (selected-frame))))
    (cl-remove-if-not
     #'dwindle--managed-window-p
     (window-list frame 'no-minibuffer (frame-first-window frame)))))

(defun dwindle--refresh (&optional frame)
  "Observe FRAME's live tree and refresh root and master references.
This function does not split, delete, resize, select, or assign buffers
to windows.  It is safe to run from a window configuration hook.
References are snapshots only: commands revalidate them on every use."
  (let ((frame (or frame (selected-frame))))
    (when (frame-live-p frame)
      ;; Enrollment changes only private bookkeeping.  During an operation,
      ;; callbacks must not enroll intermediate reconstruction windows.
      (dolist (window (window-list frame 'no-minibuffer))
        (dwindle--owned-window-p window))
      (let ((windows (dwindle--windows frame)))
        (set-frame-parameter frame 'dwindle-root
                             (and windows
                                  (if (eq dwindle-manage-windows 'all)
                                      (frame-root-window frame)
                                    (window-main-window frame))))
        (set-frame-parameter frame 'dwindle-master (car windows))
        (set-frame-parameter frame 'dwindle-tail (car (last windows)))))))

(defun dwindle-root-window (&optional frame)
  "Return FRAME's current native root, or nil without managed leaves.
The root may be an internal window.  Under conservative policies, native
side windows are outside the managed main root.
Always refresh first, including after Winner or workspace restoration."
  (let ((frame (or frame (selected-frame))))
    (dwindle--refresh frame)
    (frame-parameter frame 'dwindle-root)))

(defun dwindle-master-window (&optional frame)
  "Return FRAME's first managed live window, or nil if there is none.
Deleting the master promotes the first surviving leaf in native order."
  (let ((frame (or frame (selected-frame))))
    (dwindle--refresh frame)
    (frame-parameter frame 'dwindle-master)))

(defun dwindle--subtree-windows (window)
  "Return live leaves beneath valid WINDOW, in native order."
  (if (window-live-p window)
      (list window)
    (let ((child (window-child window)) leaves)
      (while child
        (setq leaves (nconc leaves (dwindle--subtree-windows child))
              child (window-next-sibling child)))
      leaves)))

(defun dwindle--all-nodes (window)
  "Return valid WINDOW and every internal node and leaf below it."
  (let ((nodes (list window)) (child (window-child window)))
    (while child
      (setq nodes (nconc nodes (dwindle--all-nodes child))
            child (window-next-sibling child)))
    nodes))

(defun dwindle--prepare-frame (&optional frame)
  "Release application window restrictions in FRAME for the `all' policy.
Keep window identities, buffers, geometry, and display state.  Only explicit
operations and display actions call this; observation hooks never do.
The minibuffer and explicitly ignored windows retain their restrictions."
  (when (and (eq dwindle-manage-windows 'all) (not dwindle--inhibit))
    (let ((frame (or frame (selected-frame)))
          (dwindle--inhibit t)
          popups)
      (dolist (node (dwindle--all-nodes (frame-root-window frame)))
        (unless (dwindle--ignored-window-p node)
          (when (window-live-p node)
            (when (window-parameter node 'popup)
              (cl-pushnew (window-buffer node) popups)
              ;; Doom's disable hook only restores modelines on windows
              ;; still marked as popups.  Do this in the window transaction
              ;; before clearing the marker and deferring buffer cleanup.
              (when (with-current-buffer (window-buffer node)
                      (bound-and-true-p +popup-buffer-mode))
                (set-window-parameter node 'mode-line-format nil)))
            (set-window-dedicated-p node nil))
          (dolist (parameter '(window-side window-slot window-vslot window-atom
                              popup no-other-window no-delete-other-windows
                              split-window delete-window delete-other-windows
                              window-preserved-size))
            (when (window-parameter node parameter)
              (set-window-parameter node parameter nil)))))
      (dolist (buffer popups)
        (if dwindle--defer-popup-cleanup
            (cl-pushnew buffer dwindle--pending-popup-buffers)
          (let ((dwindle--pending-popup-buffers (list buffer)))
            (dwindle--finish-preparation))))
      (dwindle--refresh frame))))

(defun dwindle--finish-preparation ()
  "Release adopted popup buffer lifecycles after a successful operation.
Keep the lifecycle while another window still displays the same buffer
as a popup, including an explicitly ignored window on another frame."
  (dolist (buffer dwindle--pending-popup-buffers)
    (when (and (buffer-live-p buffer)
               (not (cl-some (lambda (window)
                               (window-parameter window 'popup))
                             (get-buffer-window-list buffer nil t))))
      (dwindle-doom--release-popup buffer)))
  (setq dwindle--pending-popup-buffers nil))

(defun dwindle--without-buffer-list-hooks (function)
  "Call FUNCTION without global or buffer-local buffer-list callbacks.
Use only while rolling back a failed operation.  Restoring a configuration
can switch buffers before running this hook, so a dynamic binding in the
current buffer alone is insufficient.  Restore every saved local value."
  (let ((locals
         (cl-loop for buffer in (buffer-list)
                  when (local-variable-p 'buffer-list-update-hook buffer)
                  collect (cons buffer (buffer-local-value
                                        'buffer-list-update-hook buffer)))))
    (cl-letf (((default-value 'buffer-list-update-hook) nil))
	     (unwind-protect
		 (progn
		   (dolist (entry locals)
		     (with-current-buffer (car entry)
                       (setq buffer-list-update-hook nil)))
		   (funcall function))
               (dolist (entry locals)
		 (when (buffer-live-p (car entry))
		   (with-current-buffer (car entry)
		     (setq-local buffer-list-update-hook (cdr entry)))))))))

(defun dwindle--call-with-window-transaction (function &optional frame)
  "Call FUNCTION, restoring FRAME's window layout if it exits abnormally.
This protects against a native split that signals from an application
hook before returning its new window, and against callbacks that turn a
new window into an atomic group.  Rollback uses a native configuration,
never application-specific deletion functions.  Window parameters and
views are restored separately because configurations omit some of them.
Buffer text edits made by application hooks are outside this transaction."
  (let* ((frame (or frame (selected-frame)))
         (configuration (current-window-configuration frame))
         (parameters
          (mapcar (lambda (window)
                    ;; Parameter values belong to other packages and may
                    ;; contain cyclic objects.  Never recursively copy them.
                    (cons window
                          (mapcar (lambda (entry) (cons (car entry) (cdr entry)))
                                  (window-parameters window))))
                  (dwindle--all-nodes (frame-root-window frame))))
         (views (mapcar (lambda (window)
                          (list window (window-point window) (window-start window)
                                (window-hscroll window) (window-vscroll window)))
                        (window-list frame 'no-minibuffer)))
         (ownership (mapcar (lambda (view)
                              (cons (car view)
                                    (gethash (car view) dwindle--owned-windows)))
                            views))
         (dwindle--inhibit t)
         complete)
    (unwind-protect
        (prog1 (funcall function)
          (setq complete t))
      (unless complete
        (dwindle--without-buffer-list-hooks
         (lambda ()
           ;; Restore the geometry that already existed, even if the failed
           ;; command temporarily raised the user minimum size above it.
           (let ((window-min-width window-safe-min-width)
                 (window-min-height window-safe-min-height))
             (set-window-configuration configuration))
           (dolist (entry parameters)
             (let ((window (car entry)))
               (when (window-valid-p window)
                 (dolist (parameter (window-parameters window))
                   (unless (assq (car parameter) (cdr entry))
                     (set-window-parameter window (car parameter) nil)))
                 (dolist (parameter (cdr entry))
                   (set-window-parameter window (car parameter) (cdr parameter))))))
           (dolist (view views)
             (when (window-live-p (car view))
               (set-window-point (car view) (nth 1 view))
               (set-window-start (car view) (nth 2 view) t)
               (set-window-hscroll (car view) (nth 3 view))
               (set-window-vscroll (car view) (nth 4 view)))))))
      (unless complete
        (dolist (entry ownership)
          (if (cdr entry)
              (puthash (car entry) t dwindle--owned-windows)
            (remhash (car entry) dwindle--owned-windows))))
      (dwindle--refresh frame))))

(defun dwindle--next-side (window)
  "Return the next BSP split direction for managed WINDOW."
  (let ((parent (window-parent window)))
    (if (and parent
             ;; A surrounding side/popup split does not define our axis.
             (cl-every #'dwindle--managed-window-p
                       (dwindle--subtree-windows parent)))
        (if (window-combination-p parent t) 'below 'right)
      dwindle-first-split)))

(defun dwindle--split (source &optional buffer)
  "Split a managed window according to `dwindle-split-policy'.
Show BUFFER, defaulting to SOURCE's buffer, and preserve selection.
The split is a single native operation.  If a native split or buffer
initialization hook fails, restore the original layout and views."
  (when dwindle--inhibit
    (user-error "A dwindle split is already in progress"))
  (dwindle--prepare-frame (window-frame source))
  (unless (dwindle--managed-window-p source)
    (user-error "This window is managed by another application"))
  (unless (memq dwindle-first-split '(right below))
    (user-error "`dwindle-first-split' must be right or below"))
  (unless (memq dwindle-split-policy '(focused tail))
    (user-error "`dwindle-split-policy' must be focused or tail"))
  (if (and (not dwindle--automatic-display)
           (eq dwindle-split-policy 'focused)
           (not (window-live-p (dwindle--focused-node source))))
      (save-selected-window
        (dwindle--split-focused-node source (or buffer (window-buffer source))))
    (let* ((frame (window-frame source))
           (buffer (if buffer (get-buffer buffer) (window-buffer source)))
           (target (if (eq dwindle-split-policy 'tail)
                       (car (last (dwindle--windows frame)))
                     source))
           (original (window-list frame 'no-minibuffer (frame-first-window frame)))
           (outside (mapcar (lambda (window)
                              (list window (window-buffer window)
                                    (window-edges window nil nil t)))
                            (delq target (copy-sequence original))))
           (target-edges (window-edges target nil nil t))
           (side (dwindle--next-side target))
           (same-buffer (eq buffer (window-buffer source)))
           (point (window-point source))
           (start (window-start source))
           (hscroll (window-hscroll source))
           (vscroll (window-vscroll source))
           (dwindle--inhibit t)
           ;; Keep each split binary, even after deletion makes adjacent
           ;; ancestors share an axis.  Do not borrow space from the master.
           (window-combination-limit t)
           (window-combination-resize nil)
           new)
      (unless (buffer-live-p buffer)
	(user-error "No live buffer to display"))
      (save-selected-window
	(dwindle--call-with-window-transaction
	 (lambda ()
           ;; A nil size enforces Emacs's real minimum sizes.  In particular
           ;; this does not use Doom's split-height/width thresholds.
           (setq new (split-window target nil side))
           (set-window-buffer new buffer)
           (when same-buffer
             (set-window-point new point)
             (set-window-start new start t)
             (set-window-hscroll new hscroll)
             (set-window-vscroll new vscroll))
           ;; Hooks may return normally after inserting a second pane or
           ;; deleting an existing one.  A successful split must still be
           ;; exactly our one binary insertion, within the original area.
           (unless (and (window-live-p new)
                        (cl-every #'window-live-p original)
                        (= (length (window-list frame 'no-minibuffer))
                           (1+ (length original)))
                        (eq (window-next-sibling target) new)
                        (= (window-child-count (window-parent new)) 2)
                        (equal (window-edges (window-parent new) nil nil t)
                               target-edges)
                        (eq (window-buffer new) buffer))
             (error "An application changed the layout during the BSP split"))
            (dolist (snapshot outside)
             (let ((window (car snapshot)))
               (unless (and (eq (window-buffer window) (nth 1 snapshot))
                            (equal (window-edges window nil nil t)
                                   (nth 2 snapshot)))
                  (error "The BSP split affected an outside window"))))
            (unless dwindle--automatic-display
              (dwindle--claim-window source)
              (dwindle--claim-window new))
            new)
	 frame)))))

;;;###autoload
(defun dwindle-split (&optional buffer)
  "Split the focused BSP window and select the new window.
BUFFER is an existing buffer or its name; default to the selected
window's buffer.  Leaf insertion retains all existing window identities.
An explicitly focused internal node is reconstructed within its region.
Refuse the split when the target is too small.
With `dwindle-split-policy' set to `tail', split the trailing leaf."
  (interactive)
  (let ((window (dwindle--split (selected-window) buffer)))
    (let ((dwindle--inhibit t))
      (select-window window))
    window))

(defun dwindle--pane-snapshot (frame)
  "Record FRAME's live pane objects, buffers and outer pixel geometry."
  (mapcar (lambda (window)
            (list window (window-buffer window) (window-edges window nil nil t)))
          (window-list frame 'no-minibuffer (frame-first-window frame))))

(defun dwindle--discard-failed-buffer (buffer)
  "Clean up only BUFFER after its creation failed, preserving the error.
Run every resource cleanup hook even if an earlier hook signals.  Normal
interactive terminal closes still use Ghostel's unmodified kill hooks."
  (when (buffer-live-p buffer)
    (condition-case failure
        (dwindle--without-buffer-list-hooks
         (lambda ()
           (with-current-buffer buffer
             (let ((kill-buffer-query-functions nil)
                   (confirm-kill-processes nil)
                   hook-errors)
               (set-buffer-modified-p nil)
               (run-hook-wrapped
                'kill-buffer-hook
                (lambda (function &rest arguments)
                  (condition-case err
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (apply function arguments)))
                    ((error quit) (push err hook-errors)))
                  nil))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (let ((kill-buffer-hook nil))
                     (kill-buffer buffer))))
               (when hook-errors
                 (message "Dwindle: cleaned up failed buffer despite hook error: %s"
                          (error-message-string (car hook-errors))))))))
      ((error quit)
       (message "Dwindle: failed buffer cleanup needs attention (%s): %s"
                (buffer-name buffer) (error-message-string failure))))))

(defun dwindle--open-fresh-buffer (factory)
  "Call FACTORY to create a buffer in one selected Dwindle split.
FACTORY receives a buffer display action function and must use it once,
then return the fresh buffer.  Inherit the focused buffer's directory.
Failed initialization restores the original layout and cleans up only
the fresh buffer, including its process via its normal cleanup hooks."
  (when dwindle--inhibit
    (user-error "A Dwindle window operation is already in progress"))
  (dwindle--prepare-frame)
  (unless (dwindle--managed-window-p (selected-window))
    (user-error "This window is managed by another application"))
  (let* ((source (selected-window))
         (frame (window-frame source))
         (directory (buffer-local-value 'default-directory (window-buffer source)))
         (original (dwindle--pane-snapshot frame))
         (old-buffers (buffer-list))
         (focus (frame-parameter frame 'dwindle-focus))
         (mark (frame-parameter frame 'dwindle-selected-node))
         buffer window expected complete)
    (unwind-protect
        (dwindle--call-with-window-transaction
         (lambda ()
           (unwind-protect
               (let ((result
                      (with-current-buffer (window-buffer source)
                        (let ((default-directory directory))
                          (funcall
                           factory
                           (lambda (fresh &optional _alist)
                             (when (or buffer (not (buffer-live-p fresh))
                                       (memq fresh old-buffers))
                               (error "Expected one fresh buffer for the Dwindle split"))
                             (setq buffer fresh)
                             (unless (equal original (dwindle--pane-snapshot frame))
                               (error "An application changed the layout before insertion"))
                             (with-current-buffer fresh
                               (setq-local default-directory directory))
                             (select-window source)
                             ;; This is the one deliberate insertion within
                             ;; the outer transaction.  Its own guard covers
                             ;; all native split and buffer callbacks.
                             (let ((dwindle--inhibit nil))
                               (setq window (dwindle--split source fresh)))
                             ;; Selecting the new pane runs buffer-list
                             ;; callbacks too; keep the outer guard here.
                             (select-window window)
                             (setq expected (dwindle--pane-snapshot frame))
                             window))))))
                 (unless (and (eq result buffer) (buffer-live-p buffer)
                              (window-live-p window))
                   (error "The buffer initializer did not finish its Dwindle split"))
                 (select-window window)
                 (unless (equal expected (dwindle--pane-snapshot frame))
                   (error "An application changed the layout during initialization"))
                 (setq complete t)
                 window)
             (unless complete
               ;; Keep Ghostel's resource cleanup hooks, but never prompt
               ;; about terminating a terminal whose launch just failed.
               ;; Cleanup occurs before the enclosing layout rollback.
               (dwindle--discard-failed-buffer buffer))))
         frame)
      (unless complete
        (set-frame-parameter frame 'dwindle-focus focus)
        (set-frame-parameter frame 'dwindle-selected-node mark)))))

;;;###autoload
(defun dwindle-new-buffer ()
  "Open the shared `*scratch*' buffer in a new Dwindle split.
Return the selected new window.  Preserve an existing scratch buffer's
contents, major mode and directory.  If it does not exist, create it
with `initial-major-mode' and the focused buffer's `default-directory'."
  (interactive)
  (when dwindle--inhibit
    (user-error "A Dwindle window operation is already in progress"))
  (if-let ((buffer (get-buffer "*scratch*")))
      (let* ((source (selected-window))
             (frame (window-frame source))
             (focus (frame-parameter frame 'dwindle-focus))
             (mark (frame-parameter frame 'dwindle-selected-node))
             complete)
        (unwind-protect
            (dwindle--call-with-window-transaction
             (lambda ()
               (let* ((window (let ((dwindle--inhibit nil))
                                (dwindle--split source buffer)))
                      (expected (dwindle--pane-snapshot frame)))
                 ;; Selection can invoke application callbacks.  Keep it
                 ;; guarded and inside rollback, just like new creation.
                 (select-window window)
                 (unless (equal expected (dwindle--pane-snapshot frame))
                   (error "An application changed the layout during scratch selection"))
                 (setq complete t)
                 window))
             frame)
          (unless complete
            (set-frame-parameter frame 'dwindle-focus focus)
            (set-frame-parameter frame 'dwindle-selected-node mark))))
    (dwindle--open-fresh-buffer
     (lambda (display)
       (let ((buffer (let ((buffer-list-update-hook nil))
                       (get-buffer-create "*scratch*"))))
         ;; Register the new buffer for failure cleanup before mode hooks
         ;; run.  The shared helper owns the whole initialization transaction.
         (funcall display buffer)
         (with-current-buffer buffer
           (funcall initial-major-mode))
         buffer)))))

;;;###autoload
(defun dwindle-new-terminal (&optional persistent)
  "Open a fresh Ghostel terminal in a Dwindle split and return its window.
Start in the focused buffer's `default-directory', including Dired or
shell directory tracking.  Always create a new terminal, never reuse one.
With PERSISTENT (interactively, a prefix), keep the session when closing
its pane.  Otherwise an explicit close of its last pane also kills it,
subject to Ghostel's normal confirmation checks.  Ghostel is optional
and is loaded only when this command is invoked."
  (interactive "P")
  (dwindle--open-fresh-buffer
   (lambda (display)
     (unless (and (require 'ghostel nil t) (fboundp 'ghostel-create))
       (user-error "Install Ghostel with ghostel-create support to open a terminal"))
     ;; An explicit Dwindle terminal belongs in this split.  Let the
     ;; supplied action run before any general popup or project rule.
     (let ((display-buffer-overriding-action nil)
           (display-buffer-alist nil))
       (let ((buffer (ghostel-create nil (list display))))
         (with-current-buffer buffer
           (setq-local dwindle-terminal-managed t
                       dwindle-terminal-disposable (not persistent)))
         buffer)))))

;;;###autoload
(defun dwindle-new-persistent-terminal ()
  "Open a fresh persistent Ghostel terminal in a Dwindle split.
Use the focused buffer's directory.  Closing its pane keeps the session."
  (interactive)
  (dwindle-new-terminal t))

;;;###autoload
(defun dwindle-delete-window ()
  "Delete the selected ordinary window and promote its native sibling.
Emacs preserves surviving windows and collapses the empty tree branch.
The last ordinary window cannot be deleted with this command."
  (interactive)
  (when dwindle--inhibit
    (user-error "A dwindle window operation is already in progress"))
  (dwindle--prepare-frame)
  (unless (dwindle--managed-window-p (selected-window))
    (user-error "This window is managed by another application"))
  (when (length= (dwindle--windows) 1)
    (user-error "Cannot delete the last dwindle window"))
  (let ((frame (selected-frame))
        (dwindle--terminal-close-permitted t)
        (dwindle--terminal-close-target (selected-window)))
    (dwindle--call-with-window-transaction #'delete-window frame)))

(defun dwindle--preferred-split (window)
  "Try a dwindle split on WINDOW's frame for `display-buffer'.
Return nil if WINDOW is excluded, a split is already in progress, or
the focused leaf cannot split.  Let `display-buffer' choose its normal
fallback; never retry splitting recursively."
  (when (and (not dwindle--inhibit) (dwindle--managed-window-p window))
    ;; Emacs suggests its largest or least-recently-used window.  BSP splits
    ;; the focused leaf instead, without redirecting a popup into the editor.
    (let ((source (frame-selected-window (window-frame window))))
      (when (dwindle--managed-window-p source)
        ;; `display-buffer' may subsequently install application state on
        ;; the returned pane.  Providing geometry does not make it ours.
        (let ((dwindle--automatic-display t))
          (condition-case nil
              (dwindle--split source)
            (error nil)))))))

(require 'dwindle-resize)
(require 'dwindle-doom)
(require 'dwindle-tree)
(require 'dwindle-terminal)
(require 'dwindle-display)

(defun dwindle--observe-selection (frame)
  "Discard FRAME's node focus if another leaf was selected.
This hook only updates bookkeeping; it never changes the window tree."
  (when (and (frame-live-p frame) (frame-parameter frame 'dwindle-focus))
    (dwindle--focused-node (frame-selected-window frame))))

(defvar dwindle-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s-r") #'dwindle-rotate)
    (define-key map (kbd "s-e") #'dwindle-new-buffer)
    (define-key map (kbd "s-<return>") #'dwindle-new-terminal)
    (define-key map (kbd "s-RET") #'dwindle-new-terminal)
    (define-key map (kbd "s-S-<return>") #'dwindle-new-persistent-terminal)
    (define-key map (kbd "s-S-RET") #'dwindle-new-persistent-terminal)
    (define-key map [remap split-window-below] #'dwindle-split)
    (define-key map [remap split-window-right] #'dwindle-split)
    (dolist (binding '(("h" "H" left) ("j" "J" down)
                       ("k" "K" up) ("l" "L" right)))
      (let ((key (nth 0 binding))
            (shifted (nth 1 binding))
            (direction (nth 2 binding)))
        (define-key map (kbd (concat "s-" key))
                    (intern (format "windmove-%s" direction)))
        ;; Graphical Emacs reports Shift+letter as the uppercase letter.
        (define-key map (kbd (concat "s-" shifted))
                    (intern (format "dwindle-expand-%s" direction)))
        (define-key map (kbd (concat "C-s-" key))
                    (intern (format "dwindle-shrink-%s" direction)))))
    map)
  "Keymap active while `dwindle-mode' is enabled.")

;;;###autoload
(define-minor-mode dwindle-mode
  "Use native dwindle window splits and directional Super bindings.
Existing layouts are observed without rebuilding windows.  All non-minibuffer
panes participate by default, including automatic display and workspace
restoration; see `dwindle-manage-windows' for conservative ownership.
Interactive splits divide the focused leaf and enroll the new pane.
Explicit low-level `split-window' calls retain their semantics.
Disabling the mode removes the integration and leaves windows in place."
  :global t
  :group 'dwindle
  :keymap dwindle-mode-map
  (if dwindle-mode
      (unless dwindle--installed
        (setq dwindle--previous-splitter
              (default-value 'split-window-preferred-function)
              dwindle--installed t)
        (setq-default split-window-preferred-function #'dwindle--preferred-split)
        (add-hook 'window-configuration-change-hook #'dwindle--refresh)
        (add-hook 'after-make-frame-functions #'dwindle--initialize-frame)
        (add-hook 'window-selection-change-functions #'dwindle--observe-selection)
        (dwindle-doom-enable)
        (dwindle-terminal-enable)
        (dwindle-display-enable)
        (mapc #'dwindle--initialize-frame (frame-list)))
    (when dwindle--installed
      (when (eq (default-value 'split-window-preferred-function)
                #'dwindle--preferred-split)
        (setq-default split-window-preferred-function dwindle--previous-splitter))
      (remove-hook 'window-configuration-change-hook #'dwindle--refresh)
      (remove-hook 'after-make-frame-functions #'dwindle--initialize-frame)
      (remove-hook 'window-selection-change-functions #'dwindle--observe-selection)
      (dwindle-doom-disable)
      (dwindle-terminal-disable)
      (dwindle-display-disable)
      (dolist (frame (frame-list))
        (dolist (parameter '(dwindle-root dwindle-master dwindle-tail
					  dwindle-focus dwindle-selected-node))
          (set-frame-parameter frame parameter nil)))
      (setq dwindle--installed nil
            dwindle--previous-splitter nil)
      (clrhash dwindle--owned-windows))))

(defun dwindle-unload-function ()
  "Disable dwindle integrations before unloading the package."
  (dwindle-mode -1)
  nil)

(provide 'dwindle)
;;; dwindle.el ends here
