;;; config.el --- Example for your Doom config -*- lexical-binding: t; -*-

;; Add these forms to ~/.config/doom/config.el (or ~/.doom.d/config.el).
;; Declare the GitHub package as shown in doom/packages.el, run doom sync,
;; then restart Emacs.  No manual load-path entry is needed.

;; Optional: start with a horizontal divider instead of a vertical divider.
;; (setq dwindle-first-split 'below)

;; Each resize moves the divider by 5% of the ancestor split's size.
;; Use smaller steps for finer key-repeat control (no animation overhead).
;; (setq dwindle-resize-step 0.02)

;; Default insertion follows BSP by splitting the focused pane.
;; To restore the original trailing-pane dwindle chain:
;; (setq dwindle-split-policy 'tail)

(use-package! dwindle
  :demand t
  :config
  (dwindle-mode 1))

;; The mode supplies Super+h/j/k/l to select windows,
;; Super+Shift+h/j/k/l to expand, and Super+Ctrl+h/j/k/l to shrink.
;; Super+r (s-r) toggles the focused pane's parent split axis.
;; Super+e (s-e) opens the shared *scratch* buffer in a Dwindle split.
;; Super+Enter opens a disposable Ghostel terminal in the focused directory;
;; Super+Shift+Enter opens a persistent one.  Requires :term ghostel.
;; These bindings also work in Evil insert state and take precedence over
;; Doom's macOS Super+Enter / Super+Shift+Enter newline bindings.
;; M-x dwindle-toggle-terminal-persistence changes the current terminal's policy.
;; C-x 2, C-x 3, C-w s, C-w v, :split, and :vsplit use dwindle.
;; M-x dwindle-mode disables the integration and restores native splitting.
