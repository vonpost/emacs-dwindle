;;; dwindle-redisplay-smoke.el --- Exercise real redisplay -*- lexical-binding: t; -*-

;; Run through run-redisplay-smoke.sh, which supplies a fresh terminal,
;; a temporary result path, and an external timeout.

(setq load-prefer-newer t)
(require 'cl-lib)
(require 'dwindle)

(setq window-min-width 6
      window-min-height 3)
(dwindle-mode 1)

(let ((steps 0)
      (hooks 0)
      (rotations 0)
      (result-file (or (getenv "DWINDLE_SMOKE_RESULT")
                       (error "DWINDLE_SMOKE_RESULT is required"))))
  (add-hook 'window-configuration-change-hook
            (lambda () (setq hooks (1+ hooks))))
  (cl-labels
      ((tick ()
         (condition-case err
             (progn
               (if (< (length (dwindle--windows)) 4)
                   (progn
                     ;; With focused insertion, avoid exhausting a tiny pane
                     ;; while other panes still have room to split.
                     (select-window
                      (car (sort (dwindle--windows)
                                 (lambda (a b)
                                   (> (* (window-total-width a)
                                         (window-total-height a))
                                      (* (window-total-width b)
                                         (window-total-height b)))))))
                     (dwindle-split))
                 (select-window (nth (mod steps 4) (dwindle--windows)))
                 (dwindle-expand-left)
                 (delete-window))
               (setq steps (1+ steps))
               (when (zerop (% steps 10))
                 (dwindle-rotate)
                 (setq rotations (1+ rotations)))
               (if (< steps 100)
                   ;; Returning to the command loop lets Emacs redisplay
                   ;; and deliver window hooks between mutations.
                   (run-at-time 0.01 nil #'tick)
                 (cl-assert (> hooks 0) nil "Redisplay never delivered a window hook")
                 (cl-assert (window-live-p (dwindle-master-window))
                            nil "The master window is no longer live")
                 (cl-assert (eq (dwindle-root-window) (window-main-window))
                            nil "The tracked root differs from the native root")
                 (with-temp-file result-file
                   (insert (format
                            "PASS: %d interactive split/delete/resize steps; %d rotations; %d window hook calls; live master and native root.\n"
                            steps rotations hooks)))
                 (kill-emacs 0)))
           (error
            (with-temp-file result-file
              (insert (format "FAIL after %d steps: %S\n" steps err)))
            (kill-emacs 1)))))
    (run-at-time 0.01 nil #'tick)))

;;; dwindle-redisplay-smoke.el ends here
