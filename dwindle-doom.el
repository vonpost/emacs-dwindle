;;; dwindle-doom.el --- Doom popup and Evil integration for dwindle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This adapter preserves Evil's command argument parsing, including :split
;; FILE and :vsplit FILE.  Its advice runs outside Doom's overriding split
;; advice.  Explicitly sized splits retain Evil/Doom's native behavior.
;; The mode's keymap takes precedence over Evil state maps, including Doom's
;; macOS Super+Return newline commands.  Other packages' maps are never edited.
;; `dwindle-mode' installs and removes the adapter; it does not require Evil.
;; Doom's standard popup rules display ordinary BSP panes while the automatic
;; management policy is active.  Custom display actions retain Doom's behavior.

;;; Code:

(require 'cl-lib)

(defvar dwindle-mode)
(defvar dwindle-mode-map)
(defvar dwindle-manage-windows)
(defvar dwindle--inhibit)
(defvar +popup-default-display-buffer-actions)
(defvar +popup--inhibit-select)
(defvar +popup--timer)

(defcustom dwindle-doom-manage-popups t
  "Display Doom's standard popups in ordinary managed BSP panes.
This applies while `dwindle-mode' is enabled and `dwindle-manage-windows'
is `all' or `ordinary'.  Popup dimensions and transient behavior are replaced by
normal Dwindle layout and buffer lifetimes.  Selection preferences are
preserved.  Under `ordinary', custom actions and existing popups are unchanged.
Set this to nil with the `ordinary' policy to retain Doom's popup behavior.
The `all' policy also routes native side actions and adopts existing windows."
  :type 'boolean
  :group 'dwindle)

(defvar dwindle-doom--inhibit-popup-routing nil
  "Non-nil while a popup display must retain Doom's native behavior.")

(defvar dwindle-doom--terminal-displays nil
  "Hash of panes routed during the current Doom terminal toggle, or nil.
Values are the buffers displayed by the popup adapter.  The hash is local
to one toggle command so later application dedication is never cleared.")

(declare-function dwindle-split "dwindle" (&optional buffer))
(declare-function dwindle--managed-window-p "dwindle" (window))
(declare-function dwindle--windows "dwindle" (&optional frame))
(declare-function dwindle--preferred-split "dwindle" (window))
(declare-function dwindle--claim-window "dwindle" (window))
(declare-function dwindle--pane-snapshot "dwindle" (frame))
(declare-function dwindle--call-with-window-transaction "dwindle"
                  (function &optional frame))
(declare-function +popup--normalize-alist "ext:popup" (alist))
(declare-function +popup-buffer-mode "ext:popup" (&optional arg))
(declare-function +popup-kill-buffer-hook-h "ext:popup" ())
(declare-function evil-edit "evil-commands" (file &optional bang))
(declare-function evil-view "evil-commands" (file &optional bang))
(declare-function evil-make-intercept-map "evil-core" (keymap &optional state aux))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))

(defun dwindle-doom--refresh-evil-keymaps ()
  "Refresh existing Evil buffers after changing dwindle's keymap priority.
This runs only when toggling the integration or loading Evil, never from
a command or redisplay hook.  New Evil buffers discover the map themselves."
  (when (featurep 'evil)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (bound-and-true-p evil-local-mode)
          (evil-normalize-keymaps))))))

(defun dwindle-doom--install-evil-keymap ()
  "Let dwindle's active mode map take precedence in every Evil state."
  (when (and (bound-and-true-p dwindle-mode)
             (boundp 'dwindle-mode-map) (featurep 'evil))
    ;; Evil retains the `dwindle-mode' activation condition when promoting
    ;; this map.  Disabling dwindle therefore also disables its intercept.
    (evil-make-intercept-map dwindle-mode-map)
    (dwindle-doom--refresh-evil-keymaps)))

(with-eval-after-load 'evil
  (dwindle-doom--install-evil-keymap))

(defun dwindle-doom--evil-split (original &rest args)
  "Use dwindle for an unsized Evil split, otherwise call ORIGINAL with ARGS.
ARGS are Evil's optional COUNT, FILE and READ-ONLY arguments.  Preserve
Evil's file-opening behavior after selecting the new dwindle window."
  (if (and (bound-and-true-p dwindle-mode)
           (null (car args))
           (dwindle--managed-window-p (selected-window)))
      (let ((window (dwindle-split))
            (file (nth 1 args))
            (read-only (nth 2 args)))
        (when file
          (funcall (if read-only #'evil-view #'evil-edit) file))
        window)
    (apply original args)))

(defun dwindle-doom--release-popup (buffer)
  "Release Doom's popup lifecycle after BUFFER's windows are adopted."
  (with-current-buffer buffer
    (when (and (bound-and-true-p +popup-buffer-mode)
               (fboundp '+popup-buffer-mode))
      (+popup-buffer-mode -1))
    (when (timerp (bound-and-true-p +popup--timer))
      (cancel-timer +popup--timer)
      (setq +popup--timer nil))
    (remove-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h t)))

(defun dwindle-doom--popup-routable-p (buffer alist)
  "Whether BUFFER and popup ALIST permit ordinary Dwindle display."
  (let ((parameters (cdr (assq 'window-parameters alist))))
    (and (bound-and-true-p dwindle-mode)
         (memq dwindle-manage-windows '(all ordinary))
         dwindle-doom-manage-popups
         (not dwindle-doom--inhibit-popup-routing)
         (not dwindle--inhibit)
         (buffer-live-p buffer)
         (not (cdr (assq 'dedicated alist)))
         (not (cl-some (lambda (key) (cdr (assq key parameters)))
                       '(dwindle-ignore window-side no-delete-other-windows
                         split-window delete-window delete-other-windows)))
         ;; An existing application pane keeps its identity and lifecycle.
         ;; Also avoid disabling a buffer's popup mode while another frame
         ;; still displays it in an actual popup.
         (not (cl-some (lambda (window)
                         (not (dwindle--managed-window-p window)))
                       (get-buffer-window-list buffer nil t))))))

(defun dwindle-doom--popup-display-alist (alist)
  "Copy ALIST without Doom's popup geometry and lifecycle parameters."
  (let ((alist (cl-remove-if
                (lambda (entry)
                  (memq (car entry)
                        '(actions side slot vslot size window-width window-height
                          window-size preserve-size window-parameters)))
                alist))
        (parameters
         (cl-remove-if
          (lambda (entry)
            (memq (car entry)
                  '(ttl quit select modeline autosave transient no-other-window
                    popup window-slot window-vslot window-preserved-size)))
          (cdr (assq 'window-parameters alist)))))
    (cons (cons 'window-parameters parameters) alist)))

(defun dwindle-doom--display-popup (buffer alist &optional select-p)
  "Display BUFFER in a managed leaf using popup ALIST, or return nil.
Reuse an ordinary pane already showing BUFFER, otherwise split the focused
leaf.  If that leaf is too small, reuse another eligible pane or the source
when permitted.  SELECT-P applies Doom's selection preference.  Failure to
find a usable ordinary pane leaves the original Doom action available."
  (when (dwindle-doom--popup-routable-p buffer alist)
    (let* ((origin (selected-window))
           (frame (window-frame origin))
           (windows (dwindle--windows))
           (source (if (dwindle--managed-window-p origin)
                       origin
                     (car (sort (copy-sequence windows)
                                (lambda (a b)
                                  (> (window-use-time a) (window-use-time b)))))))
           (reuse (cl-find-if
                   (lambda (window)
                     (and (eq (window-buffer window) buffer)
                          (or (not (cdr (assq 'inhibit-same-window alist)))
                              (not (eq window origin)))))
                   windows))
           (fallback (or (cl-find-if (lambda (window) (not (eq window origin)))
                                     windows)
                         (and (not (cdr (assq 'inhibit-same-window alist)))
                              source)))
           (display-buffer-mark-dedicated nil)
           (display-alist (dwindle-doom--popup-display-alist alist)))
      (dwindle--call-with-window-transaction
       (lambda ()
         (let* ((new (and (not reuse) source
                          (let ((dwindle--inhibit nil))
                            (with-selected-window source
                              (dwindle--preferred-split source)))))
                (window (or reuse new fallback)))
           (when window
             (let ((expected (dwindle--pane-snapshot frame)))
               (setf (nth 1 (assq window expected)) buffer)
               (window--display-buffer buffer window
                                       (if new 'window 'reuse) display-alist)
               ;; A closed popup can leave a pending kill timer on its
               ;; buffer.  Managed panes have ordinary buffer lifetimes.
               (with-current-buffer buffer
                 (when (bound-and-true-p +popup-buffer-mode)
                   (+popup-buffer-mode -1))
                 (when (timerp (bound-and-true-p +popup--timer))
                   (cancel-timer +popup--timer)
                   (setq +popup--timer nil))
                 (remove-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h t))
               (when (and select-p (not (bound-and-true-p +popup--inhibit-select)))
                 (let ((select (cdr (assq 'select
                                          (cdr (assq 'window-parameters alist))))))
                   (if (functionp select)
                       (funcall select window origin)
                     (select-window (if select window origin)))))
               ;; Buffer and selection hooks run inside the transaction.
               ;; Reject lifecycle changes that would leave a stray pane.
               (unless (and (equal expected (dwindle--pane-snapshot frame))
                            (dwindle--claim-window window))
                 (error "An application changed the managed popup layout"))
               (when dwindle-doom--terminal-displays
                 (puthash window buffer dwindle-doom--terminal-displays))
               window))))
       frame))))

(defun dwindle-doom--popup-buffer (original buffer &optional alist)
  "Route Doom's ordinary popup BUFFER and ALIST before popup initialization.
Call ORIGINAL for custom display actions or when no managed pane is usable."
  (let* ((buffer (get-buffer buffer))
         (routable (dwindle-doom--popup-routable-p buffer alist))
         (normalized (and routable (+popup--normalize-alist alist)))
         (actions (or (cdr (assq 'actions normalized))
                      (bound-and-true-p +popup-default-display-buffer-actions))))
    (or (and routable
             (equal actions '(+popup-display-buffer-stacked-side-window-fn))
             (dwindle-doom--display-popup buffer normalized t))
        (let ((dwindle-doom--inhibit-popup-routing t))
          (funcall original buffer alist)))))

(defun dwindle-doom--popup-action (original buffer alist)
  "Route direct calls to Doom's stacked popup action, or call ORIGINAL."
  (or (dwindle-doom--display-popup (get-buffer buffer) alist)
      (funcall original buffer alist)))

(defun dwindle-doom--terminal-toggle (original &rest args)
  "Keep panes routed during Doom terminal ORIGINAL with ARGS managed.
Doom's Eshell and Vterm toggles dedicate their pane after buffer display
returns.  Remove that dedication only from panes routed by our adapter
during this command, still displaying the same buffer."
  (if (not (and (bound-and-true-p dwindle-mode)
                (memq dwindle-manage-windows '(all ordinary))
                dwindle-doom-manage-popups
                (not dwindle--inhibit)))
      (apply original args)
    (let ((dwindle-doom--terminal-displays (make-hash-table :test #'eq)))
      (unwind-protect
          (apply original args)
        (let ((dwindle--inhibit t))
          (maphash
           (lambda (window buffer)
             (when (and (bound-and-true-p dwindle-mode)
                        (memq dwindle-manage-windows '(all ordinary))
                        dwindle-doom-manage-popups
                        (window-live-p window)
                        (eq (window-buffer window) buffer)
                        (eq (window-dedicated-p window) t))
               (set-window-dedicated-p window nil)
               ;; Retain native ownership if another application claimed
               ;; the pane after display returned to the terminal command.
               (unless (dwindle--claim-window window)
                 (set-window-dedicated-p window t))))
           dwindle-doom--terminal-displays))))))

(defun dwindle-doom-enable ()
  "Install dwindle's optional Doom popup and Evil integration.
Advice can be installed before Doom or Evil loads.  Its depth places it outside
Doom's default overriding advice on the same commands."
  (dolist (command '(evil-window-split evil-window-vsplit))
    (advice-add command :around #'dwindle-doom--evil-split
                '((depth . -100))))
  (advice-add '+popup-buffer :around #'dwindle-doom--popup-buffer
              '((depth . -100)))
  (advice-add '+popup-display-buffer-stacked-side-window-fn
              :around #'dwindle-doom--popup-action '((depth . -100)))
  (dolist (command '(+eshell/toggle +vterm/toggle))
    (advice-add command :around #'dwindle-doom--terminal-toggle
                '((depth . -100))))
  (dwindle-doom--install-evil-keymap))

(defun dwindle-doom-disable ()
  "Remove dwindle's Doom/Evil advice and refresh the now-inactive keymap."
  (dolist (command '(evil-window-split evil-window-vsplit))
    (advice-remove command #'dwindle-doom--evil-split))
  (advice-remove '+popup-buffer #'dwindle-doom--popup-buffer)
  (advice-remove '+popup-display-buffer-stacked-side-window-fn
                 #'dwindle-doom--popup-action)
  (dolist (command '(+eshell/toggle +vterm/toggle))
    (advice-remove command #'dwindle-doom--terminal-toggle))
  (dwindle-doom--refresh-evil-keymaps))

(provide 'dwindle-doom)
;;; dwindle-doom.el ends here
