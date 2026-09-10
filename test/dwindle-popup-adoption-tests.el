;;; dwindle-popup-adoption-tests.el --- Popup adoption transactions -*- lexical-binding: t; -*-

(require 'dwindle-doom-tests)

(defvar +popup-default-display-buffer-actions)
(defvar +popup--inhibit-select)

(defmacro dwindle-popup-adoption-test--with-layout (&rest body)
  "Run BODY with automatic adoption and fixture Doom popup functions."
  (declare (indent 0))
  `(let ((dwindle-test--policy 'all))
     (dwindle-doom-test--with-popups
       (cl-letf (((symbol-function '+popup-kill-buffer-hook-h) #'ignore))
         ,@body))))

(ert-deftest dwindle-popup-adoption-failed-split-preserves-buffer-lifecycle ()
  (dwindle-popup-adoption-test--with-layout
    (with-temp-buffer
      (let* ((buffer (current-buffer))
             (pane (let ((dwindle-manage-windows 'ordinary)
                         (dwindle-doom-manage-popups nil))
                     (+popup-buffer buffer '((side . right)))))
             (timer (run-at-time 1000 nil #'ignore)))
        (unwind-protect
            (progn
              (setq-local +popup--timer timer)
              (add-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h nil t)
              (set-window-parameter pane 'mode-line-format 'none)
              (select-window pane)
              (let ((window-min-height 1000)
                    (window-min-width 1000))
                (should-error (dwindle-split)))
              (should (window-parameter pane 'popup))
              (should (window-dedicated-p pane))
              (should (eq (window-parameter pane 'mode-line-format) 'none))
              (with-current-buffer buffer
                (should +popup-buffer-mode)
                (should (eq +popup--timer timer))
                (should (memq timer timer-list))
                (should (memq #'+popup-kill-buffer-hook-h kill-buffer-hook))))
          (cancel-timer timer))))))

(ert-deftest dwindle-popup-adoption-success-releases-buffer-and-modeline ()
  (dwindle-popup-adoption-test--with-layout
    (with-temp-buffer
      (let* ((buffer (current-buffer))
             (pane (let ((dwindle-manage-windows 'ordinary)
                         (dwindle-doom-manage-popups nil))
                     (+popup-buffer buffer '((side . right)))))
             (timer (run-at-time 1000 nil #'ignore)))
        (unwind-protect
            (progn
              (setq-local +popup--timer timer)
              (add-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h nil t)
              (set-window-parameter pane 'mode-line-format 'none)
              (select-window pane)
              (should (window-live-p (dwindle-split)))
              (should-not (window-parameter pane 'popup))
              (should-not (window-parameter pane 'mode-line-format))
              (with-current-buffer buffer
                (should-not +popup-buffer-mode)
                (should-not +popup--timer)
                (should-not (memq timer timer-list))
                (should-not (memq #'+popup-kill-buffer-hook-h kill-buffer-hook))))
          (cancel-timer timer))))))

(ert-deftest dwindle-popup-adoption-preserves-shared-ignored-popup-lifecycle ()
  (dwindle-popup-adoption-test--with-layout
    (with-temp-buffer
      (let* ((buffer (current-buffer))
             (source (selected-window))
             (pane (split-window source nil 'right))
             (ignored (split-window pane nil 'below))
             (timer (run-at-time 1000 nil #'ignore)))
        (unwind-protect
            (progn
              (setq-local +popup-buffer-mode t)
              (setq-local +popup--timer timer)
              (add-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h nil t)
              (dolist (window (list pane ignored))
                (set-window-buffer window buffer)
                (set-window-parameter window 'popup t)
                (set-window-parameter window 'mode-line-format 'none)
                (set-window-dedicated-p window 'popup))
              (set-window-parameter ignored 'dwindle-ignore t)
              (select-window source)
              (should (window-live-p (dwindle-split)))
              (should-not (window-parameter pane 'popup))
              (should-not (window-parameter pane 'mode-line-format))
              (should (window-parameter ignored 'popup))
              (should (eq (window-dedicated-p ignored) 'popup))
              (should (eq (window-parameter ignored 'mode-line-format) 'none))
              (with-current-buffer buffer
                (should +popup-buffer-mode)
                (should (eq +popup--timer timer))
                (should (memq timer timer-list))
                (should (memq #'+popup-kill-buffer-hook-h kill-buffer-hook))))
          (cancel-timer timer))))))

(provide 'dwindle-popup-adoption-tests)
;;; dwindle-popup-adoption-tests.el ends here
