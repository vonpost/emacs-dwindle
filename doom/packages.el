;;; packages.el --- Example for your Doom packages -*- lexical-binding: t; -*-

;; Add this declaration to ~/.config/doom/packages.el (or ~/.doom.d/packages.el).
;; Then run doom sync and restart Emacs.
(package! dwindle
  :recipe (:host github
           :repo "vonpost/emacs-dwindle"
           :files ("dwindle*.el")))

;; For terminal shortcuts, enable ghostel under :term in the existing doom!
;; form in init.el, or keep your existing Ghostel installation.
