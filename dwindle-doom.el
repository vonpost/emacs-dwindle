;;; dwindle-doom.el --- Evil keys and split commands for dwindle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This adapter preserves Evil's command argument parsing, including :split
;; FILE and :vsplit FILE.  Its advice runs outside Doom's overriding split
;; advice.  Explicitly sized splits retain Evil/Doom's native behavior.
;; The mode's keymap takes precedence over Evil state maps, including Doom's
;; macOS Super+Return newline commands.  Other packages' maps are never edited.
;; `dwindle-mode' installs and removes the adapter; it does not require Evil.

;;; Code:

(defvar dwindle-mode)
(defvar dwindle-mode-map)

(declare-function dwindle-split "dwindle" (&optional buffer))
(declare-function dwindle--managed-window-p "dwindle" (window))
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

(defun dwindle-doom-enable ()
  "Install dwindle's optional Evil integration.
Advice can be installed before Evil loads.  Its depth places it outside
Doom's default overriding advice on the same commands."
  (dolist (command '(evil-window-split evil-window-vsplit))
    (advice-add command :around #'dwindle-doom--evil-split
                '((depth . -100))))
  (dwindle-doom--install-evil-keymap))

(defun dwindle-doom-disable ()
  "Remove dwindle's Evil advice and refresh the now-inactive keymap."
  (dolist (command '(evil-window-split evil-window-vsplit))
    (advice-remove command #'dwindle-doom--evil-split))
  (dwindle-doom--refresh-evil-keymaps))

(provide 'dwindle-doom)
;;; dwindle-doom.el ends here
