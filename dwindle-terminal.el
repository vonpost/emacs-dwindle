;;; dwindle-terminal.el --- Lifetimes for Dwindle terminals -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only terminals explicitly created by Dwindle participate.  Disposal follows
;; an explicit pane-close command, never redisplay, buffer hiding, workspace
;; changes, or structural reconstruction.  Ghostel's normal kill-buffer query
;; and cleanup hooks remain authoritative for its process lifecycle.

;;; Code:

(require 'cl-lib)

(defvar dwindle-mode)
(defvar dwindle--inhibit)
(defvar evil-auto-balance-windows)
(declare-function dwindle--call-with-window-transaction "dwindle"
                  (function &optional frame))

(defvar-local dwindle-terminal-managed nil
  "Non-nil only in a terminal successfully created by Dwindle.
Preexisting terminals and buffers created by other packages are excluded.")

(defvar-local dwindle-terminal-disposable nil
  "Non-nil means explicitly closing this terminal's last pane kills it.
Ordinary buffer hiding, layout restoration, and workspace switching keep
the terminal alive.  Ghostel's normal kill-buffer queries still apply.")

(defvar dwindle--terminal-close-permitted nil
  "Non-nil around an explicit Dwindle or Evil pane-close command.
Structural window operations must not bind this variable.")

(defvar dwindle--terminal-closing nil
  "Non-nil while a terminal close is already being processed.")

(defvar dwindle--terminal-close-target nil
  "The selected pane targeted by an explicit Evil close, when known.")

(defvar dwindle--terminal-installed nil
  "Non-nil when terminal lifecycle advice is installed.")

(defconst dwindle--terminal-mode-line-entry
  '(dwindle-terminal-managed
    (:eval (when (bound-and-true-p dwindle-mode)
             (if dwindle-terminal-disposable " Disposable" " Persistent"))))
  "Persistence indicator for managed terminals whose mode line is visible.")

(define-error 'dwindle-terminal-close-aborted "Terminal close canceled")

(defun dwindle--terminal-disposable-window-p (window)
  "Whether WINDOW is the last live view of a disposable Dwindle terminal.
Include views on invisible and iconified frames when checking sharing."
  (and (window-live-p window)
       (let ((buffer (window-buffer window)))
         (with-current-buffer buffer
           (and dwindle-terminal-managed dwindle-terminal-disposable
                (derived-mode-p 'ghostel-mode)
                (equal (get-buffer-window-list buffer nil t) (list window)))))))

(defun dwindle--terminal-around-delete (original &optional window)
  "Dispose a terminal only when ORIGINAL closes its pane with explicit intent.
Run normal buffer queries before losing the pane.  The first kill hook
then deletes the native window, before Ghostel terminates its PTY."
  (setq window (or window (selected-window)))
  (if (not (and dwindle-mode dwindle--terminal-installed
                (not dwindle--terminal-closing)
                (or (and dwindle--terminal-close-permitted
                         (or (not dwindle--terminal-close-target)
                             (eq dwindle--terminal-close-target window)))
                    (and (not dwindle--inhibit)
                         (called-interactively-p 'any)))
                (dwindle--terminal-disposable-window-p window)
                (eq (window-deletable-p window) t)))
      ;; Consume close permission while invoking the native operation:
      ;; unrelated nested deletions by package hooks are programmatic work.
      (let ((dwindle--terminal-close-permitted nil))
        (funcall original window))
    (let ((buffer (window-buffer window))
          (frame (window-frame window))
          (dwindle--terminal-closing t)
          closed)
      (condition-case nil
          (dwindle--call-with-window-transaction
           (lambda ()
             (with-current-buffer buffer
               ;; kill-buffer runs every query before any kill hook.  Put
               ;; native deletion first so a failed delete never reaches
               ;; Ghostel's native-process termination hook.
               (let ((kill-buffer-hook
                      (cons
                       (lambda ()
                         ;; A query can enter a recursive edit: revalidate
                         ;; mode, persistence, and sharing immediately before
                         ;; performing either destructive action.
                         (unless closed
                           (unless (and dwindle-mode dwindle--terminal-installed
                                        (window-live-p window)
                                        (eq (window-buffer window) buffer)
                                        (dwindle--terminal-disposable-window-p window))
                             (signal 'dwindle-terminal-close-aborted nil))
                           ;; Deleting the selected pane changes current-buffer.
                           ;; Ghostel's following kill hooks must still run in
                           ;; the terminal to detach and terminate its native PTY.
                           (save-current-buffer (funcall original window))
                           (when (window-live-p window)
                             (signal 'dwindle-terminal-close-aborted nil))
                           (setq closed t)))
                       kill-buffer-hook)))
                 (unless (kill-buffer buffer)
                   (signal 'dwindle-terminal-close-aborted nil))))
             nil)
           frame)
        ;; Evil :q interprets any escaping error as a request to close a
        ;; frame/tab/Emacs.  A declined query must therefore return normally.
        (dwindle-terminal-close-aborted nil)))))

(defun dwindle--terminal-around-evil-close (original &rest arguments)
  "Give Evil's explicit close ORIGINAL permission to dispose a terminal."
  (let* ((dwindle--terminal-close-target (selected-window))
         (dwindle--terminal-close-permitted (not dwindle--inhibit))
         (disposal (and dwindle-mode dwindle--terminal-installed
                        dwindle--terminal-close-permitted
                        (dwindle--terminal-disposable-window-p
                         dwindle--terminal-close-target)
                        (eq (window-deletable-p dwindle--terminal-close-target) t)))
        ;; Evil balances after delete-window returns even when its buffer
        ;; query was declined.  Preserve the layout on that cancellation.
         (evil-auto-balance-windows
          (and (not disposal) (bound-and-true-p evil-auto-balance-windows))))
    (if (not disposal)
        (apply original arguments)
      ;; Evil :q treats any error from its close command as a frame/tab/Emacs
      ;; exit request.  Report failures from queries or native close hooks
      ;; here instead; the window transaction has already restored the pane.
      (condition-case problem
          (apply original arguments)
        (error
         (message "Terminal close failed: %s" (error-message-string problem))
         nil)))))

(defun dwindle--terminal-install-evil ()
  "Install the narrow Evil close wrapper when its command is available."
  (when (and dwindle--terminal-installed (fboundp 'evil-window-delete))
    (advice-add 'evil-window-delete :around #'dwindle--terminal-around-evil-close)))

(with-eval-after-load 'evil
  (dwindle--terminal-install-evil))

(defun dwindle-terminal-enable ()
  "Enable explicit pane-close handling for Dwindle-created terminals."
  (unless dwindle--terminal-installed
    (setq dwindle--terminal-installed t)
    (advice-add 'delete-window :around #'dwindle--terminal-around-delete)
    (add-to-list 'minor-mode-alist dwindle--terminal-mode-line-entry))
  (force-mode-line-update t)
  (dwindle--terminal-install-evil))

(defun dwindle-terminal-disable ()
  "Disable terminal disposal, leaving all existing terminals alive."
  (setq dwindle--terminal-installed nil)
  (advice-remove 'delete-window #'dwindle--terminal-around-delete)
  (advice-remove 'evil-window-delete #'dwindle--terminal-around-evil-close)
  (setq minor-mode-alist (assq-delete-all 'dwindle-terminal-managed minor-mode-alist))
  (force-mode-line-update t))

;;;###autoload
(defun dwindle-toggle-terminal-persistence ()
  "Toggle whether explicitly closing this terminal's last pane kills it.
Only terminals created by Dwindle can be toggled.  Ghostel's existing
process query and cleanup hooks are preserved in both cases."
  (interactive)
  (unless (and dwindle-terminal-managed (derived-mode-p 'ghostel-mode))
    (user-error "This terminal was not created by Dwindle"))
  (setq dwindle-terminal-disposable (not dwindle-terminal-disposable))
  (force-mode-line-update)
  (message (if dwindle-terminal-disposable
               "Terminal will close with its last pane"
             "Terminal will stay alive when its pane closes"))
  (not dwindle-terminal-disposable))

(provide 'dwindle-terminal)
;;; dwindle-terminal.el ends here
