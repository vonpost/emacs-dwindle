;;; dwindle-terminal-tests.el --- Explicit terminal close regression tests -*- lexical-binding: t; -*-

(require 'dwindle-terminal)
(defvar evil-auto-balance-windows nil)

(defmacro dwindle-terminal-test--with-terminal (&rest body)
  "Run BODY with BUFFER, WINDOW, and live pipe PROCESS modeling Ghostel."
  (declare (indent 0) (debug t))
  `(dwindle-test--with-layout
     (let ((buffer (generate-new-buffer " *dwindle-terminal-test*"))
           window process)
       (unwind-protect
           (progn
             (dwindle-terminal-enable)
             (with-current-buffer buffer
               ;; Lifecycle tests exercise Emacs's real buffer/process kill
               ;; machinery without starting a user's interactive shell.
               (setq major-mode 'ghostel-mode
                     dwindle-terminal-managed t
                     dwindle-terminal-disposable t)
               (setq process (make-pipe-process
                              :name "dwindle-terminal-test" :buffer buffer
                              :noquery t)))
             (setq window (dwindle-split buffer))
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((kill-buffer-query-functions nil))
               (kill-buffer buffer))))
         (when (process-live-p process) (delete-process process))
         (dwindle-terminal-disable)))))

(ert-deftest dwindle-terminal-interactive-close-runs-query-before-losing-pane ()
  (dwindle-terminal-test--with-terminal
    (let ((queries 0) (cleanup 0))
      (with-current-buffer buffer
        (add-hook 'kill-buffer-query-functions
                  (lambda ()
                    (cl-incf queries)
                    (should (window-live-p window))
                    (should (eq (window-buffer window) buffer))
                    (should (process-live-p process))
                    t)
                  nil t)
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (cl-incf cleanup)
                    (should (eq (current-buffer) buffer))
                    (should-not (window-live-p window)))
                  nil t))
      (call-interactively #'delete-window)
      (should (= queries 1))
      (should (= cleanup 1))
      (should-not (buffer-live-p buffer))
      (should-not (window-live-p window))
      (should-not (process-live-p process)))))

(ert-deftest dwindle-terminal-declined-query-preserves-layout-and-live-process ()
  (dwindle-terminal-test--with-terminal
    (let ((before (dwindle-test--snapshot)) (queries 0))
      (with-current-buffer buffer
        (add-hook 'kill-buffer-query-functions
                  (lambda () (cl-incf queries) nil) nil t))
      (call-interactively #'delete-window)
      (should (= queries 1))
      (should (equal before (dwindle-test--snapshot)))
      (should (eq (selected-window) window))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-persistent-close-keeps-terminal-alive ()
  (dwindle-terminal-test--with-terminal
    (with-current-buffer buffer (setq dwindle-terminal-disposable nil))
    (call-interactively #'delete-window)
    (should-not (window-live-p window))
    (should (buffer-live-p buffer))
    (should (process-live-p process))))

(ert-deftest dwindle-terminal-other-packages-buffers-are-never-disposed ()
  (dwindle-terminal-test--with-terminal
    (with-current-buffer buffer (setq dwindle-terminal-managed nil))
    (call-interactively #'delete-window)
    (should (buffer-live-p buffer))
    (should (process-live-p process))))

(ert-deftest dwindle-terminal-another-live-view-keeps-process-alive ()
  (dwindle-terminal-test--with-terminal
    (let ((other (dwindle-split buffer)))
      (select-window window)
      (call-interactively #'delete-window)
      (should (window-live-p other))
      (should (eq (window-buffer other) buffer))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-programmatic-removal-and-restore-never-dispose ()
  (dwindle-terminal-test--with-terminal
    (save-window-excursion
      ;; An interactive workspace/layout command still performs a
      ;; programmatic deletion; only delete-window itself is a close intent.
      (call-interactively (lambda () (interactive) (delete-window window)))
      (should (process-live-p process)))
    (should (window-live-p window))
    (should (eq (window-buffer window) buffer))
    (window-state-put (window-state-get (frame-root-window)) (frame-root-window))
    (should (buffer-live-p buffer))
    (should (process-live-p process))))

(ert-deftest dwindle-terminal-bsp-reconstruction-never-disposes-terminal ()
  (dwindle-terminal-test--with-terminal
    (dwindle-rotate)
    (should (buffer-live-p buffer))
    (should (process-live-p process))
    (should (eq (window-buffer (selected-window)) buffer))))

(ert-deftest dwindle-terminal-disabling-mode-leaves-existing-terminals-alive ()
  (dwindle-terminal-test--with-terminal
    (dwindle-mode -1)
    (call-interactively #'delete-window)
    (should (buffer-live-p buffer))
    (should (process-live-p process))))

(ert-deftest dwindle-terminal-failed-native-delete-cannot-kill-process ()
  (dwindle-terminal-test--with-terminal
    (set-window-parameter
     window 'delete-window
     (lambda (target)
       (let ((ignore-window-parameters t)) (delete-window target))
       (error "Injected failure after native deletion")))
    (let ((before (dwindle-test--snapshot)))
      (should-error (call-interactively #'delete-window))
      (should (equal before (dwindle-test--snapshot)))
      (should (window-live-p window))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-evil-query-error-cannot-trigger-frame-fallback ()
  (dwindle-terminal-test--with-terminal
    (let ((before (dwindle-test--snapshot)) fallback)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-query-functions
                  (lambda () (error "Application query failed")) nil t))
      (condition-case nil
          (dwindle--terminal-around-evil-close (lambda () (delete-window)))
        (error (setq fallback t)))
      (should-not fallback)
      (should (equal before (dwindle-test--snapshot)))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-evil-native-error-cannot-trigger-frame-fallback ()
  (dwindle-terminal-test--with-terminal
    (set-window-parameter window 'delete-window
                          (lambda (_) (error "Application close failed")))
    (let ((before (dwindle-test--snapshot)) fallback)
      (condition-case nil
          (dwindle--terminal-around-evil-close (lambda () (delete-window)))
        (error (setq fallback t)))
      (should-not fallback)
      (should (equal before (dwindle-test--snapshot)))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-explicit-close-does-not-authorize-other-panes ()
  (dwindle-terminal-test--with-terminal
    (let* ((editor (car (dwindle-test--windows)))
           (spare (split-window editor nil 'below)))
      (select-window editor)
      (dwindle--terminal-around-evil-close
       (lambda ()
         ;; A package intercepting the user's close command can remove an
         ;; unrelated terminal programmatically; that is not a disposal request.
         (delete-window window)
         (delete-window editor)))
      (should (window-live-p spare))
      (should-not (window-live-p window))
      (should (buffer-live-p buffer))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-native-callback-cannot-inherit-close-permission ()
  (dwindle-terminal-test--with-terminal
    (let* ((editor (car (dwindle-test--windows)))
           (spare (split-window editor nil 'below)))
      (set-window-parameter
       editor 'delete-window
       (lambda (target)
         (delete-window window)
         (let ((ignore-window-parameters t)) (delete-window target))))
      (select-window editor)
      (let ((dwindle--terminal-close-permitted t))
        (delete-window editor))
      (should (window-live-p spare))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-last-frame-pane-refusal-keeps-process-alive ()
  (dwindle-terminal-test--with-terminal
    (delete-other-windows window)
    (should-error (call-interactively #'delete-window))
    (should (window-live-p window))
    (should (process-live-p process))))

(ert-deftest dwindle-terminal-duplication-during-query-cancels-close ()
  (dwindle-terminal-test--with-terminal
    (let ((before (dwindle-test--snapshot)))
      (with-current-buffer buffer
        (add-hook 'kill-buffer-query-functions
                  (lambda ()
                    (set-window-buffer (split-window window nil 'below) buffer)
                    t)
                  nil t))
      (call-interactively #'delete-window)
      (should (equal before (dwindle-test--snapshot)))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-persistence-toggle-is-scoped-to-created-terminals ()
  (dwindle-terminal-test--with-terminal
    (with-current-buffer buffer
      (should (dwindle-toggle-terminal-persistence))
      (should-not dwindle-terminal-disposable)
      (should-not (dwindle-toggle-terminal-persistence))
      (should dwindle-terminal-disposable)
      (setq dwindle-terminal-managed nil)
      (should-error (dwindle-toggle-terminal-persistence) :type 'user-error))))

(ert-deftest dwindle-terminal-evil-query-cancellation-cannot-close-frame ()
  (dwindle-terminal-test--with-terminal
    (let ((before (dwindle-test--snapshot))
          (evil-auto-balance-windows t)
          fallback)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-query-functions (lambda () nil) nil t))
      (cl-letf (((symbol-function 'evil-window-delete)
                 (lambda ()
                   (delete-window)
                   (when evil-auto-balance-windows
                     (error "Canceled close incorrectly tried balancing"))))
                ((symbol-function 'delete-frame)
                 (lambda (&rest _) (setq fallback t))))
        (dwindle--terminal-install-evil)
        (unwind-protect
            ;; Actual Evil :q has this error-to-frame-close fallback.
            (condition-case nil (evil-window-delete) (error (delete-frame)))
          (advice-remove 'evil-window-delete #'dwindle--terminal-around-evil-close)))
      (should-not fallback)
      (should (equal before (dwindle-test--snapshot)))
      (should (process-live-p process)))))

(ert-deftest dwindle-terminal-own-close-command-permits-disposal ()
  (dwindle-terminal-test--with-terminal
    (dwindle-delete-window)
    (should-not (window-live-p window))
    (should-not (buffer-live-p buffer))
    (should-not (process-live-p process))))

(provide 'dwindle-terminal-tests)
;;; dwindle-terminal-tests.el ends here
