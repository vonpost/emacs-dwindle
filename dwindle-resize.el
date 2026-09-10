;;; dwindle-resize.el --- Directional resizing for Dwindle -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Resize the nearest native split on the requested edge of a managed window.
;; Moving an ancestor split resizes its whole subtree, as in XMonad's
;; BinarySpacePartition layout.  Expand at an outer edge follows XMonad's
;; fallback: shrink from the opposite edge.  Shrink has no such fallback.
;; Behavior reference: XMonad/Layout/BinarySpacePartition.hs in
;; https://github.com/xmonad/xmonad-contrib .

;;; Code:

(require 'window)

(declare-function dwindle--managed-window-p "dwindle" (window))
(declare-function dwindle--prepare-frame "dwindle" (&optional frame))
(defvar dwindle-manage-windows)
(declare-function dwindle--focused-node "dwindle-tree" (&optional window))
(declare-function dwindle--call-with-window-transaction "dwindle"
                  (function &optional frame))

(defcustom dwindle-resize-step 0.05
  "Fraction of the enclosing split to move with each resize command.
The value must be greater than zero and at most one.  A numeric prefix
argument multiplies this step.  Split ratios remain between 10% and 90%,
subject to Emacs window minimum sizes and fixed-size restrictions."
  :type 'number
  :group 'dwindle)

(defun dwindle--resize-managed-subtree-p (window)
  "Return non-nil if WINDOW contains only eligible managed windows.
Atomic groups participate under the `all' policy."
  (and (window-valid-p window)
       (or (eq dwindle-manage-windows 'all)
           (not (window-atom-root window)))
       (if (window-live-p window)
           (dwindle--managed-window-p window)
         (let ((child (window-child window))
               (eligible t))
           (while (and child eligible)
             (setq eligible (dwindle--resize-managed-subtree-p child)
                   child (window-next-sibling child)))
           eligible))))

(defun dwindle--resize-boundary (window direction)
  "Find WINDOW's nearest native split boundary in DIRECTION.
Return (CHILD NEIGHBOR), nil at the main window's outer edge, or
`blocked' for an edge belonging to an excluded window.  Ordinary pairs
remain usable even if a third sibling is owned by another package."
  (let ((horizontal (memq direction '(left right)))
        (before (memq direction '(left up)))
        (root (window-main-window (window-frame window)))
        (child window)
        parent neighbor found)
    (while (and (not found)
                (not (eq child root))
                (setq parent (window-parent child)))
      (if (and (window-combined-p child horizontal)
               (setq neighbor (if before
                                  (window-prev-sibling child)
                                (window-next-sibling child))))
          (setq found (if (and (dwindle--resize-managed-subtree-p child)
                               (dwindle--resize-managed-subtree-p neighbor))
                          (list child neighbor)
                        'blocked))
        (setq child parent)))
    found))

(defun dwindle--resize (direction shrink &optional count window)
  "Resize WINDOW at its DIRECTION edge by COUNT resize steps.
DIRECTION is `left', `right', `up', or `down'.  A non-nil SHRINK moves
that edge inwards; otherwise move it outwards.  WINDOW defaults to the
selected window, and COUNT defaults to one and must be positive.

At an outer edge, expansion instead shrinks from the opposite edge,
matching XMonad's ExpandTowards.  Shrinking at an outer edge does
nothing.  Return the signed applied change in columns or lines, or nil
when no boundary can move.  Never borrow space outside the chosen split."
  (when (bound-and-true-p dwindle--inhibit)
    (user-error "A dwindle window operation is already in progress"))
  (dwindle--prepare-frame (and window (window-frame window)))
  (setq window (or window (dwindle--focused-node))
        count (or count 1))
  (unless (memq direction '(left right up down))
    (user-error "Unknown resize direction: %s" direction))
  (unless (and (numberp count) (> count 0))
    (user-error "Resize count must be a positive number"))
  (unless (and (numberp dwindle-resize-step)
               (> dwindle-resize-step 0)
               (<= dwindle-resize-step 1))
    (user-error "dwindle-resize-step must be greater than 0 and at most 1"))
  (unless (dwindle--resize-managed-subtree-p window)
    (user-error "This window is not managed by Dwindle"))
  (let ((boundary (dwindle--resize-boundary window direction)))
    (when (and (not boundary) (not shrink))
      ;; This intentionally matches upstream ExpandTowards at an outer edge.
      (setq direction (pcase direction
                        ('left 'right) ('right 'left)
                        ('up 'down) ('down 'up))
            shrink t
            boundary (dwindle--resize-boundary window direction)))
    (when (consp boundary)
      (let* ((subtree (car boundary))
             (sibling (cadr boundary))
             (horizontal (memq direction '(left right)))
             ;; A pair in an imported n-ary layout acts as one local split.
             (parent-size (+ (window-size subtree horizontal)
                             (window-size sibling horizontal)))
             (size (window-size subtree horizontal))
             (ratio-room (max 0 (if shrink
                                    (- size (ceiling (* 0.1 parent-size)))
                                  (- (floor (* 0.9 parent-size)) size))))
             (amount (min ratio-room
                          (max 1 (round (* parent-size
                                           (min 1 (* count dwindle-resize-step))))))))
        (when (> amount 0)
          ;; Check both exact participants: the native edge mover must not
          ;; borrow room from another sibling when either participant is full.
          (let* ((available
                  (min (abs (window-sizable subtree
                                            (* (if shrink -1 1) amount)
                                            horizontal))
                       (abs (window-sizable sibling
                                            (* (if shrink 1 -1) amount)
                                            horizontal))))
                 (delta (* (if shrink -1 1) (min amount available)))
                 (before (memq direction '(left up)))
                 (window-combination-resize nil))
            (unless (zerop delta)
              (dwindle--call-with-window-transaction
               (lambda ()
                 (adjust-window-trailing-edge
                  (if before sibling subtree) (* (if before -1 1) delta) horizontal)
                 (let ((applied (- (window-size subtree horizontal) size)))
                   (unless (zerop applied) applied)))
               (window-frame subtree)))))))))

(defun dwindle--move-split (direction &optional count)
  "Move a BSP divider in DIRECTION by COUNT steps.
As in XMonad, prefer the first enclosing divider after the focused node
on this axis; if none exists, use the closest enclosing divider before it."
  (dwindle--prepare-frame)
  (let* ((window (dwindle--focused-node))
         (horizontal (memq direction '(left right)))
         (forward (if horizontal 'right 'down))
         (backward (if horizontal 'left 'up))
         (boundary (dwindle--resize-boundary window forward)))
    (cond ((eq boundary 'blocked) nil)
          (boundary
           (dwindle--resize forward (not (eq direction forward)) count window))
          (t
           (dwindle--resize backward (eq direction forward) count window)))))

;;;###autoload
(defun dwindle-move-split-left (&optional count)
  "Move an enclosing BSP divider left by COUNT resize steps."
  (interactive "p")
  (dwindle--move-split 'left count))

;;;###autoload
(defun dwindle-move-split-right (&optional count)
  "Move an enclosing BSP divider right by COUNT resize steps."
  (interactive "p")
  (dwindle--move-split 'right count))

;;;###autoload
(defun dwindle-move-split-up (&optional count)
  "Move an enclosing BSP divider up by COUNT resize steps."
  (interactive "p")
  (dwindle--move-split 'up count))

;;;###autoload
(defun dwindle-move-split-down (&optional count)
  "Move an enclosing BSP divider down by COUNT resize steps."
  (interactive "p")
  (dwindle--move-split 'down count))

;;;###autoload
(defun dwindle-expand-left (&optional count)
  "Expand the selected window left by COUNT `dwindle-resize-step's.
At the left outer edge, shrink from the right instead."
  (interactive "p")
  (dwindle--resize 'left nil count))

;;;###autoload
(defun dwindle-expand-right (&optional count)
  "Expand the selected window right by COUNT `dwindle-resize-step's.
At the right outer edge, shrink from the left instead."
  (interactive "p")
  (dwindle--resize 'right nil count))

;;;###autoload
(defun dwindle-expand-up (&optional count)
  "Expand the selected window up by COUNT `dwindle-resize-step's.
At the top outer edge, shrink from the bottom instead."
  (interactive "p")
  (dwindle--resize 'up nil count))

;;;###autoload
(defun dwindle-expand-down (&optional count)
  "Expand the selected window down by COUNT `dwindle-resize-step's.
At the bottom outer edge, shrink from the top instead."
  (interactive "p")
  (dwindle--resize 'down nil count))

;;;###autoload
(defun dwindle-shrink-left (&optional count)
  "Shrink from the selected window's left edge by COUNT resize steps."
  (interactive "p")
  (dwindle--resize 'left t count))

;;;###autoload
(defun dwindle-shrink-right (&optional count)
  "Shrink from the selected window's right edge by COUNT resize steps."
  (interactive "p")
  (dwindle--resize 'right t count))

;;;###autoload
(defun dwindle-shrink-up (&optional count)
  "Shrink from the selected window's top edge by COUNT resize steps."
  (interactive "p")
  (dwindle--resize 'up t count))

;;;###autoload
(defun dwindle-shrink-down (&optional count)
  "Shrink from the selected window's bottom edge by COUNT resize steps."
  (interactive "p")
  (dwindle--resize 'down t count))

(provide 'dwindle-resize)
;;; dwindle-resize.el ends here
