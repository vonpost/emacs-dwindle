;;; dwindle-display.el --- Native buffer display in dwindle panes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Side and directional display actions normally bypass Emacs's preferred
;; split function.  Under Dwindle's `all' policy they use ordinary BSP panes
;; instead.  Applications can retain a native display action by specifying
;; the `dwindle-ignore' window parameter.

;;; Code:

(require 'cl-lib)

(defvar dwindle-mode)
(defvar dwindle-manage-windows)
(defvar dwindle--inhibit)
(defvar dwindle--defer-popup-cleanup)
(defvar dwindle--pending-popup-buffers)

(defvar dwindle-display--in-command nil
  "Non-nil while an explicit command already protects its preparation.")

(defconst dwindle-display--commands
  '(dwindle--split dwindle--open-fresh-buffer dwindle-delete-window
    dwindle--tree-command dwindle-focus-parent dwindle-select-node
    dwindle-move-node dwindle--split-shift dwindle--resize dwindle--move-split)
  "Entry points that release application restrictions before operating.")

(declare-function dwindle--managed-window-p "dwindle" (window))
(declare-function dwindle--windows "dwindle" (&optional frame))
(declare-function dwindle--prepare-frame "dwindle" (&optional frame))
(declare-function dwindle--finish-preparation "dwindle" ())
(declare-function dwindle--preferred-split "dwindle" (window))
(declare-function dwindle--claim-window "dwindle" (window))
(declare-function dwindle--pane-snapshot "dwindle" (frame))
(declare-function dwindle--call-with-window-transaction "dwindle"
                  (function &optional frame))

(defun dwindle-display--routable-p (buffer alist)
  "Whether BUFFER and action ALIST permit ordinary BSP display."
  (let ((reference (cdr (assq 'window alist))))
    (and (bound-and-true-p dwindle-mode)
         (eq dwindle-manage-windows 'all)
         (not dwindle--inhibit)
         (buffer-live-p buffer)
         (not (cdr (assq 'dwindle-ignore
                         (cdr (assq 'window-parameters alist)))))
         ;; An explicit window on another frame names a different display
         ;; destination.  Leave its handling to the original action.
         (or (not (window-valid-p reference))
             (eq (window-frame reference) (selected-frame))))))

(defun dwindle-display--action-alist (alist)
  "Copy ALIST without application geometry and window lifecycle controls."
  (let ((parameters
         (cl-remove-if
          (lambda (entry)
            (memq (car entry)
                  '(window-side window-slot window-vslot window-atom
                                window-preserved-size quit-restore no-other-window
                                no-delete-other-windows split-window delete-window
                                delete-other-windows popup ttl quit select modeline
                                autosave transient)))
          (cdr (assq 'window-parameters alist)))))
    (cons
     (cons 'window-parameters parameters)
     (cl-remove-if
      (lambda (entry)
        (memq (car entry)
              '(actions side slot vslot direction window size window-width
                        window-height window-size window-min-width window-min-height
                        preserve-size dedicated window-parameters)))
      alist))))

(defun dwindle-display--buffer (buffer alist)
  "Display BUFFER in an ordinary BSP pane using ALIST, or return nil.
Reuse a pane already showing BUFFER, otherwise split the focused leaf.
When that leaf cannot split, reuse an eligible existing pane.  Preserve
selection and honor `inhibit-same-window'.  Keep the operation on the
selected frame, so it never needs to override `inhibit-switch-frame'."
  (when (dwindle-display--routable-p buffer alist)
    (let* ((origin (selected-window))
           (frame (window-frame origin))
           (display-buffer-mark-dedicated nil)
           (display-alist (dwindle-display--action-alist alist))
           (dwindle-display--in-command t)
           (dwindle--defer-popup-cleanup t)
           (dwindle--pending-popup-buffers nil))
      (dwindle--call-with-window-transaction
       (lambda ()
         (prog1
             (save-selected-window
               (let ((dwindle--inhibit nil))
                 (dwindle--prepare-frame frame))
               (let* ((windows (dwindle--windows frame))
                      (source
                       (if (dwindle--managed-window-p origin)
                           origin
                         (car (sort (copy-sequence windows)
                                    (lambda (a b)
                                      (> (window-use-time a)
                                         (window-use-time b)))))))
                      (reusable-frames (cdr (assq 'reusable-frames alist)))
                      (eligible
                       (and (or (not (framep reusable-frames))
                                (eq reusable-frames frame))
                            (cl-remove-if
                             (lambda (window)
                               (and (eq window origin)
                                    (cdr (assq 'inhibit-same-window alist))))
                             windows)))
                      (reuse (cl-find-if
                              (lambda (window)
                                (eq (window-buffer window) buffer))
                              eligible))
                      (new (and (not reuse) source
                                (let ((dwindle--inhibit nil))
                                  (with-selected-window source
                                    (dwindle--preferred-split source)))))
                      (window (or reuse new
                                  (cl-find-if (lambda (pane) (not (eq pane origin)))
                                              eligible)
                                  (car eligible))))
                 (when window
                   (let ((expected (dwindle--pane-snapshot frame)))
                     (setf (nth 1 (assq window expected)) buffer)
                     (window--display-buffer buffer window
                                             (if new 'window 'reuse) display-alist)
                     ;; Native quit-restore bookkeeping belongs to this pane.
                     ;; Hooks may populate its buffer, but must not replace
                     ;; buffers or alter the surrounding layout silently.
                     (unless (and (equal expected (dwindle--pane-snapshot frame))
                                  (dwindle--claim-window window))
                       (error "An application changed the managed display layout"))
                     window))))
           (dwindle--finish-preparation)))
       frame))))

(defun dwindle-display--action (original buffer alist)
  "Route native BUFFER display with ALIST, or call ORIGINAL."
  (or (dwindle-display--buffer (get-buffer buffer) alist)
      (funcall original buffer alist)))

(defun dwindle-display--command (original &rest args)
  "Protect window preparation and the call of ORIGINAL with ARGS together.
Snapshot application restrictions before releasing them so a failed command
restores the original panes completely.  Nested commands share the outer
transaction; inhibited callbacks keep the original reentry protection."
  (if (not (and (bound-and-true-p dwindle-mode)
                (eq dwindle-manage-windows 'all)
                (not dwindle--inhibit)
                (not dwindle-display--in-command)))
      (apply original args)
    (let* ((window (cl-find-if #'window-valid-p args))
           (frame (if window (window-frame window) (selected-frame)))
           (dwindle-display--in-command t)
           (dwindle--defer-popup-cleanup t)
           (dwindle--pending-popup-buffers nil))
      (dwindle--call-with-window-transaction
       (lambda ()
         (prog1
             (let ((dwindle--inhibit nil))
               (dwindle--prepare-frame frame)
               (apply original args))
           (dwindle--finish-preparation)))
       frame))))

(defun dwindle-display--windmove (original &rest args)
  "Prepare every pane for directional focus, then call ORIGINAL with ARGS."
  (apply #'dwindle-display--command original args))

(defun dwindle-display-enable ()
  "Route native side and directional display actions through Dwindle."
  (dolist (action '(display-buffer-in-side-window display-buffer-in-direction))
    (advice-add action :around #'dwindle-display--action))
  (dolist (command dwindle-display--commands)
    (advice-add command :around #'dwindle-display--command))
  (advice-add 'windmove-do-window-select :around #'dwindle-display--windmove))

(defun dwindle-display-disable ()
  "Remove Dwindle's native display action integration."
  (dolist (action '(display-buffer-in-side-window display-buffer-in-direction))
    (advice-remove action #'dwindle-display--action))
  (dolist (command dwindle-display--commands)
    (advice-remove command #'dwindle-display--command))
  (advice-remove 'windmove-do-window-select #'dwindle-display--windmove))

(provide 'dwindle-display)
;;; dwindle-display.el ends here
