;;; dwindle-doom.el --- Evil split commands for dwindle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This adapter preserves Evil's command argument parsing, including :split
;; FILE and :vsplit FILE.  Its advice runs outside Doom's overriding split
;; advice.  Explicitly sized splits retain Evil/Doom's native behavior.
;; `dwindle-mode' installs and removes the adapter; it does not require Evil.

;;; Code:

(defvar dwindle-mode)

(declare-function dwindle-split "dwindle" (&optional buffer))
(declare-function dwindle--managed-window-p "dwindle" (window))
(declare-function evil-edit "evil-commands" (file &optional bang))
(declare-function evil-view "evil-commands" (file &optional bang))

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
                '((depth . -100)))))

(defun dwindle-doom-disable ()
  "Remove only the Evil advice installed by dwindle."
  (dolist (command '(evil-window-split evil-window-vsplit))
    (advice-remove command #'dwindle-doom--evil-split)))

(provide 'dwindle-doom)
;;; dwindle-doom.el ends here
