;;; dwindle-tree.el --- Explicit BSP tree transformations -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native windows remain authoritative.  These explicit commands capture a
;; wholly managed subtree, transform an in-memory binary tree, check its
;; minimum sizes, and replace only that subtree.  No hooks rebuild windows.
;; XMonad's Rotate toggles the focused node's parent split; RotateL and
;; RotateR instead perform the usual binary-tree reassociation.

;;; Code:

(require 'cl-lib)
(require 'window)

(defvar dwindle--inhibit)
(declare-function dwindle--managed-window-p "dwindle" (window))
(declare-function dwindle--owned-window-p "dwindle" (window))
(declare-function dwindle--claim-window "dwindle" (window))
(declare-function dwindle--reconstruction-eligible-p "dwindle" (window))
(declare-function dwindle--navigation-record-p "dwindle" (record window))
(declare-function dwindle--restorable-record-p "dwindle" (record))
(declare-function dwindle--subtree-windows "dwindle" (window))
(declare-function dwindle--refresh "dwindle" (&optional frame))
(declare-function dwindle--prepare-frame "dwindle" (&optional frame))
(declare-function dwindle--next-side "dwindle" (window))
(declare-function dwindle--call-with-window-transaction "dwindle"
                  (function &optional frame))
(declare-function dwindle--resize-managed-subtree-p "dwindle-resize" (window))

(cl-defstruct (dwindle--tree (:constructor dwindle--tree-create))
  window axis ratio first second view width height size)

(defun dwindle--tree-managed-p (window)
  "Whether WINDOW is a valid subtree owned wholly by Dwindle.
The current management policy and native application boundaries determine
which leaves can participate in reconstruction."
  (and (window-valid-p window)
       (dwindle--resize-managed-subtree-p window)
       (cl-every #'dwindle--owned-window-p (dwindle--subtree-windows window))))

(defun dwindle--focused-node (&optional window)
  "Return WINDOW's validated BSP focus, defaulting to WINDOW itself.
WINDOW defaults to the selected live window.  A remembered internal focus
is usable only while the exact selected leaf, frame root, and native leaf
identities still agree.  Stale state is discarded without changing windows."
  (let* ((window (or window (selected-window)))
         (frame (window-frame window))
         (record (frame-parameter frame 'dwindle-focus))
         (node (nth 1 record)))
    (if (and (eq window (car record))
             (eq (frame-root-window frame) (nth 3 record))
             (dwindle--tree-managed-p node)
             (equal (dwindle--subtree-windows node) (nth 2 record))
             (memq window (nth 2 record)))
        node
      (set-frame-parameter frame 'dwindle-focus nil)
      window)))

(defun dwindle--remember-focus (node)
  "Remember NODE as the selected window's validated BSP focus."
  (set-frame-parameter
   (selected-frame) 'dwindle-focus
   (unless (window-live-p node)
     (list (selected-window) node (dwindle--subtree-windows node)
           (frame-root-window)))))

;;;###autoload
(defun dwindle-focus-window ()
  "Reset BSP node focus to the selected live window."
  (interactive)
  (set-frame-parameter (selected-frame) 'dwindle-focus nil)
  (selected-window))

;;;###autoload
(defun dwindle-focus-parent ()
  "Focus the next wholly managed parent without changing selected window.
After the managed root, cycle back to the selected leaf.  Subsequent tree
and resize commands operate on this node.  Changing selected windows or
changing the remembered subtree's leaves invalidates this focus."
  (interactive)
  (dwindle--prepare-frame)
  (unless (dwindle--owned-window-p (selected-window))
    (user-error "This window is outside the Dwindle-owned BSP region"))
  (let* ((node (dwindle--focused-node))
         (parent (window-parent node))
         (next (if (dwindle--tree-managed-p parent)
                   parent (selected-window))))
    (dwindle--remember-focus next)
    (when (called-interactively-p 'interactive)
      (message "Dwindle focus: %d window%s"
               (length (dwindle--subtree-windows next))
               (if (window-live-p next) "" "s")))
    next))

(defun dwindle--tree-copy-quit-restore (record)
  "Copy the native list structure of a recognized quit-restore RECORD.
Leave unrelated, potentially cyclic application values untouched."
  (if (dwindle--restorable-record-p record)
      (list (nth 0 record)
            (if (consp (nth 1 record))
                (copy-sequence (nth 1 record))
              (nth 1 record))
            (nth 2 record) (nth 3 record))
    record))

(defun dwindle--tree-remap-quit-restore (record windows)
  "Copy native RECORD, mapping its previous window through WINDOWS."
  (if (dwindle--restorable-record-p record)
      (let ((copy (dwindle--tree-copy-quit-restore record)))
        (setcar (cddr copy) (gethash (nth 2 record) windows (nth 2 record)))
        copy)
    record))

(defun dwindle--tree-view-quit-restore (view window windows)
  "Return VIEW's native restoration record for WINDOW using WINDOWS."
  (let ((record (dwindle--tree-remap-quit-restore
                 (plist-get view :quit-restore) windows)))
    ;; A freshly inserted leaf can inherit the source's navigation history.
    ;; Its ordinary same-pane return target remains that new leaf itself.
    (when (plist-get view :navigation)
      (setcar (cddr record) window))
    record))

(defun dwindle--tree-capture-view (window)
  "Capture WINDOW's buffer, view, history, and presentation settings."
  (list :buffer (window-buffer window)
        :point (window-point window) :start (window-start window)
        :hscroll (window-hscroll window)
        :vscroll (window-vscroll window t)
        :margins (window-margins window) :fringes (window-fringes window)
        :scroll-bars (window-scroll-bars window)
        :parameters (mapcar (lambda (pair) (cons (car pair) (cdr pair)))
                            (window-parameters window))
        :quit-restore (dwindle--tree-copy-quit-restore
                       (window-parameter window 'quit-restore))
        ;; Standard same-window navigation records contain a self-reference.
        ;; Snapshot only their known outer structure, never arbitrary values.
        :navigation (let ((record (window-parameter window 'quit-restore)))
                      (when (and record
                                 (dwindle--navigation-record-p record window))
                        (list (nth 0 record) (nth 1 record)
                              (nth 2 record) (nth 3 record))))
        :prev (mapcar #'copy-sequence (window-prev-buffers window))
        :next (copy-sequence (window-next-buffers window))
        :display-table (window-display-table window)
        :min-width (window-min-size window t)
        :min-height (window-min-size window)
        :fixed-width (and (window-size-fixed-p window t)
                          (window-total-width window))
        :fixed-height (and (window-size-fixed-p window)
                           (window-total-height window))))

(defun dwindle--tree-capture (window)
  "Capture managed WINDOW, representing ordinary n-ary splits as binary."
  (if (window-live-p window)
      (dwindle--tree-create
       :window window :view (dwindle--tree-capture-view window)
       :width (window-total-width window) :height (window-total-height window))
    (let* ((axis (if (window-combination-p window t) 'right 'below))
           (horizontal (eq axis 'right))
           (child (window-child window)) children)
      (while child
        (push (dwindle--tree-capture child) children)
        (setq child (window-next-sibling child)))
      (setq children (nreverse children))
      (cl-labels
          ((combine (nodes)
             (if (null (cdr nodes))
                 (car nodes)
               (let* ((first (car nodes))
                      (second (combine (cdr nodes)))
                      (width (if horizontal
                                 (+ (dwindle--tree-width first)
                                    (dwindle--tree-width second))
                               (dwindle--tree-width first)))
                      (height (if horizontal (dwindle--tree-height first)
                                (+ (dwindle--tree-height first)
                                   (dwindle--tree-height second)))))
                 (dwindle--tree-create
                  :axis axis :ratio (/ (float (if horizontal
                                                 (dwindle--tree-width first)
                                               (dwindle--tree-height first)))
                                      (if horizontal width height))
                  :first first :second second :width width :height height)))))
        (let ((tree (combine children)))
          (setf (dwindle--tree-window tree) window)
          tree)))))

(defun dwindle--tree-leaves (tree)
  "Return TREE's leaf records in native order."
  (if (dwindle--tree-view tree) (list tree)
    (append (dwindle--tree-leaves (dwindle--tree-first tree))
            (dwindle--tree-leaves (dwindle--tree-second tree)))))

(defun dwindle--tree-find (tree window)
  "Find the model node in TREE corresponding to native WINDOW."
  (if (eq window (dwindle--tree-window tree)) tree
    (unless (dwindle--tree-view tree)
      (or (dwindle--tree-find (dwindle--tree-first tree) window)
          (dwindle--tree-find (dwindle--tree-second tree) window)))))

(defun dwindle--tree-minimum (tree horizontal)
  "Compute TREE's minimum size along HORIZONTAL."
  (if (dwindle--tree-view tree)
      (plist-get (dwindle--tree-view tree)
                 (if horizontal :min-width :min-height))
    (let ((first (dwindle--tree-minimum (dwindle--tree-first tree) horizontal))
          (second (dwindle--tree-minimum (dwindle--tree-second tree) horizontal)))
      (if (eq (and horizontal t) (eq (dwindle--tree-axis tree) 'right))
          (+ first second) (max first second)))))

(defun dwindle--tree-plan (tree width height)
  "Preflight TREE into WIDTH columns and HEIGHT lines, storing split sizes.
Reject layouts that cannot fit.  Ratios round to native character units;
minimum sizes can clamp the divider within the available rectangle."
  (unless (and (>= width (dwindle--tree-minimum tree t))
               (>= height (dwindle--tree-minimum tree nil)))
    (user-error "The BSP transformation does not fit this managed region"))
  (setf (dwindle--tree-width tree) width (dwindle--tree-height tree) height)
  (if-let ((view (dwindle--tree-view tree)))
      (dolist (pair (list (cons :fixed-width width) (cons :fixed-height height)))
        (when (and (plist-get view (car pair))
                   (/= (plist-get view (car pair)) (cdr pair)))
          (user-error "The BSP transformation would resize a fixed-size window")))
    (let* ((horizontal (eq (dwindle--tree-axis tree) 'right))
           (total (if horizontal width height))
           (first (dwindle--tree-first tree))
           (second (dwindle--tree-second tree))
           (size (max (dwindle--tree-minimum first horizontal)
                      (min (- total (dwindle--tree-minimum second horizontal))
                           (floor (* total (dwindle--tree-ratio tree)))))))
      (setf (dwindle--tree-size tree) size)
      (dwindle--tree-plan first (if horizontal size width)
                          (if horizontal height size))
      (dwindle--tree-plan second (if horizontal (- total size) width)
                          (if horizontal height (- total size))))))

(defun dwindle--tree-check-destination (window expected-buffer &optional record)
  "Refuse WINDOW if an application claimed it or replaced EXPECTED-BUFFER.
RECORD is the expected native quit-restore value, nil for temporary panes.
This check must precede resetting parameters or assigning buffers, since
either action could otherwise erase the evidence of a package takeover."
  (unless (and (window-live-p window)
               (eq (window-buffer window) expected-buffer)
               (equal (window-parameter window 'quit-restore) record)
               (dwindle--reconstruction-eligible-p window))
    (error "An application claimed a pane during BSP reconstruction")))

(defun dwindle--tree-restore-view (window view temporary windows)
  "Restore VIEW into WINDOW displaying TEMPORARY, remapping through WINDOWS."
  (dwindle--tree-check-destination window temporary)
  ;; Restore old parameters before buffer initialization: application
  ;; scroll hooks can assign quit-restore, popup, or custom handlers, and
  ;; their newly installed ownership markers must never be overwritten.
  (dolist (parameter (window-parameters window))
    (set-window-parameter window (car parameter) nil))
  (let ((record (dwindle--tree-view-quit-restore view window windows)))
    (dolist (parameter (plist-get view :parameters))
      (set-window-parameter
       window (car parameter)
       (if (eq (car parameter) 'quit-restore)
           (dwindle--tree-copy-quit-restore record)
         (cdr parameter))))
    (set-window-buffer window (plist-get view :buffer))
    (dwindle--tree-check-destination window (plist-get view :buffer) record))
  (let ((margins (plist-get view :margins)))
    (set-window-margins window (car margins) (cdr margins)))
  (apply #'set-window-fringes window (plist-get view :fringes))
  (let ((bars (plist-get view :scroll-bars)))
    (set-window-scroll-bars window (nth 0 bars) (nth 2 bars)
                            (nth 3 bars) (nth 5 bars) (nth 6 bars)))
  (set-window-display-table window (plist-get view :display-table))
  (set-window-point window (plist-get view :point))
  (set-window-start window (plist-get view :start) t)
  (set-window-hscroll window (plist-get view :hscroll))
  (set-window-vscroll window (plist-get view :vscroll) t)
  (set-window-prev-buffers window (plist-get view :prev))
  (set-window-next-buffers window (plist-get view :next)))

(defun dwindle--tree-build (tree window mapping temporary)
  "Build TREE in WINDOW using TEMPORARY, recording identities in MAPPING."
  (dwindle--tree-check-destination window temporary)
  (if (dwindle--tree-view tree)
      (progn
        (puthash tree window mapping)
        window)
    (let* ((second (split-window window (dwindle--tree-size tree)
                                 (dwindle--tree-axis tree)))
           (parent (window-parent window)))
      (dwindle--tree-check-destination window temporary)
      (dwindle--tree-check-destination second temporary)
      (puthash tree parent mapping)
      (dwindle--tree-build (dwindle--tree-first tree) window mapping temporary)
      (dwindle--tree-build (dwindle--tree-second tree) second mapping temporary)
      parent)))

(defun dwindle--tree-verify (tree mapping windows)
  "Verify that TREE's final native MAPPING still matches the preflight plan.
Application callbacks may split or resize a window while its buffer is
being restored.  Such intervening changes must abort the transaction."
  (let ((window (gethash tree mapping)))
    (unless (and (window-valid-p window)
                 (= (window-total-width window) (dwindle--tree-width tree))
                 (= (window-total-height window) (dwindle--tree-height tree)))
      (error "An application callback changed the BSP window geometry"))
    (if (dwindle--tree-view tree)
        (unless (and (window-live-p window)
                     (dwindle--managed-window-p window)
                     (equal (window-parameter window 'quit-restore)
                            (dwindle--tree-view-quit-restore
                             (dwindle--tree-view tree) window windows))
                     (eq (window-buffer window)
                         (plist-get (dwindle--tree-view tree) :buffer))
                     (= (window-point window)
                        (plist-get (dwindle--tree-view tree) :point))
                     (= (window-start window)
                        (plist-get (dwindle--tree-view tree) :start))
                     (= (window-hscroll window)
                        (plist-get (dwindle--tree-view tree) :hscroll))
                     (= (window-vscroll window t)
                        (plist-get (dwindle--tree-view tree) :vscroll)))
          (error "An application callback replaced a BSP window"))
      (unless (and (= (window-child-count window) 2)
                   (window-combination-p window
                                         (eq (dwindle--tree-axis tree) 'right))
                   (eq (window-child window)
                       (gethash (dwindle--tree-first tree) mapping))
                   (eq (window-next-sibling (window-child window))
                       (gethash (dwindle--tree-second tree) mapping)))
        (error "An application callback changed the BSP tree"))
      (dwindle--tree-verify (dwindle--tree-first tree) mapping windows)
      (dwindle--tree-verify (dwindle--tree-second tree) mapping windows))))

(defun dwindle--tree-apply (region tree)
  "Transactionally replace managed REGION with TREE and return a node map.
Every leaf outside REGION must retain its native object, buffer, view
and geometry.  BSP node focus resets to the selected leaf on success.
On errors or quit, restore the exact pre-command window configuration."
  (when dwindle--inhibit
    (user-error "A Dwindle window operation is already in progress"))
  (unless (dwindle--tree-managed-p region)
    (user-error "This subtree contains windows managed by another application"))
  (dwindle--tree-plan tree (window-total-width region) (window-total-height region))
  (let* ((frame (window-frame region))
         (original (dwindle--subtree-windows region))
         (anchor (car original))
         (anchor-buffer (window-buffer anchor))
         (anchor-record (dwindle--tree-copy-quit-restore
                         (window-parameter anchor 'quit-restore)))
         (selected (selected-window))
         (selected-node (dwindle--tree-find tree selected))
         (edges (window-edges region nil nil t))
         (outside (mapcar (lambda (window)
                            (list window (window-edges window nil nil t)
                                  (window-buffer window) (window-point window)
                                  (window-start window) (window-hscroll window)
                                  (window-vscroll window t)
                                  (dwindle--tree-copy-quit-restore
                                   (window-parameter window 'quit-restore))))
                          (cl-set-difference (window-list frame 'nomini
                                                         (frame-first-window frame))
                                             original)))
         (remote-records
          (cl-loop for other-frame in (frame-list)
                   unless (eq other-frame frame)
                   append
                   (cl-loop for window in (window-list other-frame 'nomini)
                            for record = (window-parameter window 'quit-restore)
                            when (and (dwindle--restorable-record-p record)
                                      (memq (nth 2 record) original))
                            collect (list window record
                                          (dwindle--tree-copy-quit-restore record)))))
         (focus (frame-parameter frame 'dwindle-focus))
         (mapping (make-hash-table :test #'eq))
         (windows (make-hash-table :test #'eq))
         (dwindle--inhibit t)
         (temporary (let ((buffer-list-update-hook nil))
                      (generate-new-buffer " *dwindle-tree*")))
         (window-combination-limit t)
         (window-combination-resize nil)
         remote-changes
         complete)
    (unwind-protect
        (dwindle--call-with-window-transaction
         (lambda ()
          ;; Temporary buffer prevents inherited buffer-local window sizing
          ;; policies from affecting intermediate construction.  Presentation
          ;; and histories are restored after every split is complete.
          (dolist (window (cdr original)) (delete-window window))
          (unless (equal (window-edges anchor nil nil t) edges)
            (error "Collapsing the subtree changed its outer boundary"))
          (dwindle--tree-check-destination anchor anchor-buffer anchor-record)
          (dolist (parameter (window-parameters anchor))
            (set-window-parameter anchor (car parameter) nil))
          (set-window-buffer anchor temporary)
          (dwindle--tree-check-destination anchor temporary)
          (dwindle--tree-build tree anchor mapping temporary)
          (dolist (leaf (dwindle--tree-leaves tree))
            (when (dwindle--tree-window leaf)
              (puthash (dwindle--tree-window leaf) (gethash leaf mapping) windows)))
          (dolist (leaf (dwindle--tree-leaves tree))
            (dwindle--tree-restore-view (gethash leaf mapping)
                                       (dwindle--tree-view leaf) temporary windows))
          (when selected-node (select-window (gethash selected-node mapping)))
          (dwindle--tree-verify tree mapping windows)
          (unless (equal (window-edges (gethash tree mapping) nil nil t) edges)
            (error "An application callback moved the BSP region"))
          (unless (= (length (window-list frame 'nomini))
                     (+ (length outside) (length (dwindle--tree-leaves tree))))
            (error "An application callback added or removed windows"))
          (dolist (snapshot outside)
            (let ((window (car snapshot)))
              (unless (and (window-live-p window)
                           (equal (cdr snapshot)
                                  (list (window-edges window nil nil t)
                                        (window-buffer window) (window-point window)
                                        (window-start window)
                                        (window-hscroll window)
                                        (window-vscroll window t)
                                        (window-parameter window 'quit-restore))))
                (error "The BSP transformation affected an outside window"))))
          ;; A protected pane may return focus to a pane being reconstructed.
          ;; Repair that native reference without changing its other state.
          (dolist (snapshot outside)
            (let* ((window (car snapshot))
                   (record (nth 7 snapshot))
                   (remapped (dwindle--tree-remap-quit-restore record windows)))
              (unless (equal record remapped)
                (set-window-parameter window 'quit-restore remapped))))
          ;; Native popup frames can return focus across frame boundaries.
          ;; Only their restoration parameter needs repair; remote layouts
          ;; do not belong to this frame's reconstruction transaction.
          (dolist (snapshot remote-records)
            (let* ((window (car snapshot))
                   (record (nth 2 snapshot))
                   (remapped (dwindle--tree-remap-quit-restore record windows)))
              (when (and (window-live-p window) (not (equal record remapped)))
                (unless (equal (window-parameter window 'quit-restore) record)
                  (error "An application changed a remote restoration record"))
                (push snapshot remote-changes)
                (set-window-parameter window 'quit-restore remapped))))
          ;; Transfer the region's ownership to verified replacement leaves.
          ;; Recheck eligibility after application initialization callbacks.
          (dolist (leaf (dwindle--tree-leaves tree))
            (unless (dwindle--claim-window (gethash leaf mapping))
              (error "An application claimed a pane during BSP reconstruction")))
          (set-frame-parameter frame 'dwindle-focus nil)
          (set-frame-parameter frame 'dwindle-selected-node nil)
          (setq complete t)
          mapping)
         frame)
      (unless complete
        (dolist (snapshot remote-changes)
          (when (window-live-p (car snapshot))
            (set-window-parameter (car snapshot) 'quit-restore (nth 1 snapshot))))
        (set-frame-parameter frame 'dwindle-focus focus))
      (when (buffer-live-p temporary)
        (with-current-buffer temporary
          (let ((kill-buffer-hook nil) (kill-buffer-query-functions nil)
                (buffer-list-update-hook nil))
            (kill-buffer temporary)))))))

(defun dwindle--tree-command (operation &optional parent)
  "Apply OPERATION to the focused subtree, or its parent when PARENT.
OPERATION receives a model tree and returns its replacement."
  (when dwindle--inhibit
    (user-error "A Dwindle window operation is already in progress"))
  (dwindle--prepare-frame)
  (unless (dwindle--owned-window-p (selected-window))
    (user-error "This window is outside the Dwindle-owned BSP region"))
  (let* ((focused (dwindle--focused-node))
         (region (if parent (window-parent focused) focused)))
    (when (and (dwindle--tree-managed-p region)
               (not (window-live-p region)))
      (let* ((tree (dwindle--tree-capture region))
             (replacement (funcall operation tree)))
        (when replacement
          (dwindle--tree-apply region replacement))))))

;;;###autoload
(defun dwindle-rotate ()
  "Toggle the focused node's parent split between right and below.
Preserve child order and split ratio, as in XMonad BSP's Rotate.  A
focused root is unchanged.  Refuse layouts that cannot fit safely."
  (interactive)
  (dwindle--tree-command
   (lambda (tree)
     (setf (dwindle--tree-axis tree)
           (if (eq (dwindle--tree-axis tree) 'right) 'below 'right))
     tree) t))

;;;###autoload
(defun dwindle-swap ()
  "Swap the focused node with its sibling, retaining the parent's ratio."
  (interactive)
  (dwindle--tree-command
   (lambda (tree)
     (cl-rotatef (dwindle--tree-first tree) (dwindle--tree-second tree))
     tree) t))

(defun dwindle--tree-rotate (tree right)
  "Reassociate TREE to the RIGHT, or to the left when RIGHT is nil."
  (let ((child (if right (dwindle--tree-first tree)
                 (dwindle--tree-second tree))))
    (unless (dwindle--tree-view child)
      (if right
          (setf (dwindle--tree-first tree) (dwindle--tree-second child)
                (dwindle--tree-second child) tree)
        (setf (dwindle--tree-second tree) (dwindle--tree-first child)
              (dwindle--tree-first child) tree))
      child)))

;;;###autoload
(defun dwindle-rotate-left ()
  "Rotate the tree left around the focused node's parent, as BSP RotateL."
  (interactive)
  (dwindle--tree-command (lambda (tree) (dwindle--tree-rotate tree nil)) t))

;;;###autoload
(defun dwindle-rotate-right ()
  "Rotate the tree right around the focused node's parent, as BSP RotateR."
  (interactive)
  (dwindle--tree-command (lambda (tree) (dwindle--tree-rotate tree t)) t))

(defun dwindle--tree-equalize (tree)
  "Adjust TREE's ratios to give each leaf an equal share of area."
  (unless (dwindle--tree-view tree)
    (let ((first (dwindle--tree-first tree))
          (second (dwindle--tree-second tree)))
      (setf (dwindle--tree-ratio tree)
            (/ (float (length (dwindle--tree-leaves first)))
               (length (dwindle--tree-leaves tree))))
      (dwindle--tree-equalize first)
      (dwindle--tree-equalize second)))
  tree)

;;;###autoload
(defun dwindle-equalize ()
  "Equalize areas in the focused subtree, retaining its topology and axes.
Use `dwindle-focus-parent' to focus a subtree first; a leaf is unchanged."
  (interactive)
  (dwindle--tree-command #'dwindle--tree-equalize))

(defun dwindle--tree-balanced (leaves width height)
  "Build a balanced BSP from LEAVES, optimizing axes for WIDTH and HEIGHT."
  (if (null (cdr leaves)) (car leaves)
    (let* ((half (/ (length leaves) 2))
           ;; Upstream chooses the split producing more square rectangles.
           ;; At ratio 1/2 this is the longer pixel dimension (ties: right).
           (horizontal (>= width height))
           (child-width (if horizontal (/ width 2.0) width))
           (child-height (if horizontal height (/ height 2.0))))
      (dwindle--tree-create
       :axis (if horizontal 'right 'below) :ratio 0.5
       :first (dwindle--tree-balanced (cl-subseq leaves 0 half)
                                     child-width child-height)
       :second (dwindle--tree-balanced (nthcdr half leaves)
                                      child-width child-height)))))

;;;###autoload
(defun dwindle-balance ()
  "Balance the focused subtree, preserving leaf order and choosing axes.
Splits start at 1/2, matching BSP Balance; `dwindle-equalize' additionally
equalizes leaf areas for uneven leaf counts.  A focused leaf is unchanged."
  (interactive)
  (let ((node (dwindle--focused-node)))
    (dwindle--tree-command
     (lambda (tree)
       (dwindle--tree-balanced (dwindle--tree-leaves tree)
                               (window-pixel-width node)
                               (window-pixel-height node))))))

(defun dwindle--tree-toggle-splits (tree)
  "Toggle all split axes in TREE, as BSP splitCurrent does for a subtree."
  (unless (dwindle--tree-view tree)
    (setf (dwindle--tree-axis tree)
          (if (eq (dwindle--tree-axis tree) 'right) 'below 'right))
    (dwindle--tree-toggle-splits (dwindle--tree-first tree))
    (dwindle--tree-toggle-splits (dwindle--tree-second tree)))
  tree)

(defun dwindle--split-focused-node (source buffer)
  "Split SOURCE's focused internal node, displaying BUFFER in the new leaf.
Insert the new leaf first and toggle the old subtree's split axes, matching
BSP insertion at an internal node.  Return the new leaf; preserve selection."
  (setq buffer (get-buffer buffer))
  (let* ((node (dwindle--focused-node source))
         (axis (dwindle--next-side node))
         (view (dwindle--tree-capture-view source))
         (old (dwindle--tree-capture node)))
    (unless (and (buffer-live-p buffer) (not (window-live-p node)))
      (user-error "A live buffer and an internal BSP focus are required"))
    (unless (eq buffer (plist-get view :buffer))
      (setq view (plist-put view :buffer buffer))
      (setq view (plist-put view :point (with-current-buffer buffer (point))))
      (setq view (plist-put view :start (with-current-buffer buffer (point-min))))
      (setq view (plist-put view :hscroll 0))
      (setq view (plist-put view :vscroll 0)))
    (let* ((leaf (dwindle--tree-create :view view))
           (tree (dwindle--tree-create :axis axis :ratio 0.5 :first leaf
                                       :second (dwindle--tree-toggle-splits old)))
           (mapping (dwindle--tree-apply node tree)))
      (gethash leaf mapping))))

(defun dwindle--selected-node ()
  "Return the current frame's valid BSP selection, or nil when stale."
  (let* ((record (frame-parameter nil 'dwindle-selected-node))
         (node (car record)))
    (if (and (eq (nth 2 record) (frame-root-window))
             (dwindle--tree-managed-p node)
             (equal (cadr record) (dwindle--subtree-windows node)))
        node
      (set-frame-parameter nil 'dwindle-selected-node nil)
      nil)))

;;;###autoload
(defun dwindle-select-node ()
  "Mark the focused BSP node for `dwindle-move-node', or unmark it.
The mark survives focus changes and is discarded when its native subtree
changes.  Use `dwindle-focus-parent' first to mark a whole subtree."
  (interactive)
  (dwindle--prepare-frame)
  (unless (dwindle--owned-window-p (selected-window))
    (user-error "This window is outside the Dwindle-owned BSP region"))
  (let* ((node (dwindle--focused-node))
         (selected (dwindle--selected-node))
         (record (unless (eq selected node)
                   (list node (dwindle--subtree-windows node) (frame-root-window)))))
    (set-frame-parameter nil 'dwindle-selected-node record)
    (when (called-interactively-p 'interactive)
      (message (if record "BSP node selected for moving" "BSP node unselected")))
    (and record node)))

(defun dwindle--tree-parent (tree node)
  "Return NODE's model parent in TREE, or nil at its root."
  (unless (dwindle--tree-view tree)
    (if (or (eq node (dwindle--tree-first tree))
            (eq node (dwindle--tree-second tree))) tree
      (or (dwindle--tree-parent (dwindle--tree-first tree) node)
          (dwindle--tree-parent (dwindle--tree-second tree) node)))))

(defun dwindle--tree-replace (tree node replacement)
  "Replace NODE by REPLACEMENT in TREE and return its new root."
  (if (eq tree node) replacement
    (unless (dwindle--tree-view tree)
      (setf (dwindle--tree-first tree)
            (dwindle--tree-replace (dwindle--tree-first tree) node replacement)
            (dwindle--tree-second tree)
            (dwindle--tree-replace (dwindle--tree-second tree) node replacement)))
    tree))

(defun dwindle--tree-move (tree source target &optional after)
  "Move SOURCE alongside TARGET within TREE, returning the new model root.
Place SOURCE first, or second if AFTER.  SOURCE and TARGET must be disjoint."
  (let* ((parent (dwindle--tree-parent tree source))
         (sibling (if (eq source (dwindle--tree-first parent))
                      (dwindle--tree-second parent)
                    (dwindle--tree-first parent))))
    (setq tree (dwindle--tree-replace tree parent sibling))
    (let* ((target-parent (dwindle--tree-parent tree target))
           (axis (if (and target-parent
                          (eq (dwindle--tree-axis target-parent) 'right))
                     'below 'right))
           (replacement (dwindle--tree-create
                         :axis axis :ratio 0.5
                         :first (if after target source)
                         :second (if after source target))))
      (dwindle--tree-replace tree target replacement))))

(defun dwindle--tree-common-region (first second)
  "Return the smallest wholly managed ancestor of FIRST containing SECOND."
  (let ((region first))
    (while (and (dwindle--tree-managed-p region)
                (not (memq (car (dwindle--subtree-windows second))
                           (dwindle--subtree-windows region))))
      (setq region (window-parent region)))
    (and (dwindle--tree-managed-p region) region)))

;;;###autoload
(defun dwindle-move-node ()
  "Move the marked BSP node before the focused node, as BSP MoveNode.
The source and target must be disjoint and belong to one wholly managed
region.  Preserve leaf views and the currently focused buffer."
  (interactive)
  (dwindle--prepare-frame)
  (unless (dwindle--owned-window-p (selected-window))
    (user-error "This window is outside the Dwindle-owned BSP region"))
  (let* ((source (dwindle--selected-node))
         (target (dwindle--focused-node)))
    (unless source (user-error "Select a BSP node with dwindle-select-node first"))
    (when (cl-intersection (dwindle--subtree-windows source)
                           (dwindle--subtree-windows target))
      (user-error "The source and target BSP nodes must be disjoint"))
    (let ((region (dwindle--tree-common-region source target)))
      (unless region (user-error "Cannot move across an application-owned window split"))
      (let* ((tree (dwindle--tree-capture region))
             (replacement (dwindle--tree-move
                           tree (dwindle--tree-find tree source)
                           (dwindle--tree-find tree target))))
        (dwindle--tree-apply region replacement)))))

(defun dwindle--split-shift (previous)
  "Move the focused leaf's split towards PREVIOUS or the following leaf."
  (dwindle--prepare-frame)
  (unless (dwindle--owned-window-p (selected-window))
    (user-error "This window is outside the Dwindle-owned BSP region"))
  (let* ((source (dwindle--focused-node))
         (region source))
    (while (dwindle--tree-managed-p (window-parent region))
      (setq region (window-parent region)))
    (when (and (window-live-p source) (not (eq source region)))
      (let* ((tree (dwindle--tree-capture region))
             (node (dwindle--tree-find tree source))
             (parent (dwindle--tree-parent tree node))
             (leaves (dwindle--tree-leaves tree))
             (index (cl-position node leaves))
             (target-index (+ index (if previous -1 1)))
             (target (and (>= target-index 0) (nth target-index leaves))))
        (when (and target
                   (eq node (if previous (dwindle--tree-first parent)
                              (dwindle--tree-second parent))))
          (dwindle--tree-apply
           region (dwindle--tree-move tree node target previous)))))))

;;;###autoload
(defun dwindle-split-shift-previous ()
  "Move the focused leaf's split to the previous leaf, preserving leaf order.
Like BSP SplitShift Prev, this does nothing for a right child or at the
start of the managed region.  An internal focus is unchanged."
  (interactive)
  (dwindle--split-shift t))

;;;###autoload
(defun dwindle-split-shift-next ()
  "Move the focused leaf's split to the next leaf, preserving leaf order.
Like BSP SplitShift Next, this does nothing for a left child or at the
end of the managed region.  An internal focus is unchanged."
  (interactive)
  (dwindle--split-shift nil))

(provide 'dwindle-tree)
;;; dwindle-tree.el ends here
