;;; config.el --- Example for your Doom config -*- lexical-binding: t; -*-

;; Add these forms to ~/.doom.d/config.el (or ~/.config/doom/config.el).
;; Adjust this path if you keep the checkout elsewhere.
(add-to-list 'load-path (expand-file-name "~/emacs-dwindle"))
(require 'dwindle)

;; Optional: start with a horizontal divider instead of a vertical divider.
;; (setq dwindle-first-split 'below)

;; Each resize moves the divider by 5% of the ancestor split's size.
;; (setq dwindle-resize-step 0.05)

;; Default insertion follows BSP by splitting the focused pane.
;; To restore the original trailing-pane dwindle chain:
;; (setq dwindle-split-policy 'tail)

(dwindle-mode 1)

;; The mode supplies Super+h/j/k/l to select windows,
;; Super+Shift+h/j/k/l to expand, and Super+Ctrl+h/j/k/l to shrink.
;; Super+r (s-r) toggles the focused pane's parent split axis.
;; Super+Shift+e (s-E) opens a fresh empty buffer in a Dwindle split.
;; Super+Enter opens a disposable Ghostel terminal in the focused directory;
;; Super+Shift+Enter opens a persistent one.  Requires :term ghostel.
;; M-x dwindle-toggle-terminal-persistence changes the current terminal's policy.
;; C-x 2, C-x 3, C-w s, C-w v, :split, and :vsplit use dwindle.
;; M-x dwindle-mode disables the integration and restores native splitting.
