;;; dwindle-evil-tests.el --- Optional real Evil keymap checks -*- lexical-binding: t; -*-

;; These tests skip when Evil is unavailable on load-path.  Add Evil and its
;; dependencies to Emacs's load-path to run them; no packages are installed.

(require 'dwindle-tests)

(defconst dwindle-evil-test--bindings
  '(("s-e" . dwindle-new-buffer)
    ("s-<return>" . dwindle-new-terminal)
    ("s-RET" . dwindle-new-terminal)
    ("s-S-<return>" . dwindle-new-persistent-terminal)
    ("s-S-RET" . dwindle-new-persistent-terminal)))

(defun dwindle-evil-test--require-evil ()
  "Load actual Evil or skip this optional integration test."
  (unless (require 'evil nil t)
    (ert-skip "Evil is not available on load-path")))

(defmacro dwindle-evil-test--with-editor (&rest body)
  "Run BODY with actual Evil enabled in a disposable editor buffer."
  (declare (indent 0))
  `(progn
     (dwindle-evil-test--require-evil)
     (dwindle-test--with-layout
       (let ((editor (generate-new-buffer " *dwindle-evil-editor*")))
         (unwind-protect
             (progn
               (set-window-buffer (selected-window) editor)
               (with-current-buffer editor
                 (evil-local-mode 1)
                 ,@body))
           (when (buffer-live-p editor)
             (with-current-buffer editor
               (evil-local-mode -1)
               (set-buffer-modified-p nil))
             (kill-buffer editor)))))))

(defun dwindle-evil-test--assert-bindings ()
  "Assert effective creation bindings in the current Evil buffer."
  (dolist (entry dwindle-evil-test--bindings)
    (should (eq (key-binding (kbd (car entry))) (cdr entry)))))

(ert-deftest dwindle-evil-global-state-conflicts-restore-when-disabled ()
  (dwindle-evil-test--with-editor
    (let (saved)
      (unwind-protect
          (progn
            (dolist (entry dwindle-evil-test--bindings)
              (let* ((key (kbd (car entry)))
                     ;; These are Doom's actual macOS normal-state bindings.
                     (normal-command
                      (cond ((string= (car entry) "s-e") #'ignore)
                            ((string-match-p "s-S-" (car entry)) '+default/newline-above)
                            (t '+default/newline-below))))
                (push (list evil-normal-state-map key (lookup-key evil-normal-state-map key)) saved)
                (push (list evil-insert-state-map key (lookup-key evil-insert-state-map key)) saved)
                (define-key evil-normal-state-map key normal-command)
                (define-key evil-insert-state-map key #'ignore)))
            (dolist (state '(normal insert))
              (evil-change-state state)
              (dwindle-mode 1)
              (dwindle-evil-test--assert-bindings)
              (dwindle-mode -1)
              (dolist (entry dwindle-evil-test--bindings)
                (should
                 (eq (key-binding (kbd (car entry)))
                     (lookup-key (if (eq state 'normal)
                                     evil-normal-state-map evil-insert-state-map)
                                 (kbd (car entry))))))))
        (dolist (entry saved)
          (define-key (nth 0 entry) (nth 1 entry) (nth 2 entry)))))))

(ert-deftest dwindle-evil-local-state-conflicts-refresh-existing-buffers ()
  (dwindle-evil-test--with-editor
    (let ((other (generate-new-buffer " *dwindle-evil-insert-editor*")))
      (unwind-protect
          (progn
            (dwindle-mode -1)
            (dolist (entry (list (cons editor 'normal) (cons other 'insert)))
              (with-current-buffer (car entry)
                (evil-local-mode 1)
                (evil-change-state (cdr entry))
                (let ((map (if (eq (cdr entry) 'normal)
                               evil-normal-state-local-map evil-insert-state-local-map)))
                  (dolist (binding dwindle-evil-test--bindings)
                    (define-key map (kbd (car binding)) #'ignore)))))
            ;; Neither existing buffer changes Evil state during these
            ;; toggles, so integration must refresh both cached keymap lists.
            (dotimes (_ 2)
              (dwindle-mode 1)
              (dolist (buffer (list editor other))
                (with-current-buffer buffer (dwindle-evil-test--assert-bindings)))
              (dwindle-mode -1)
              (dolist (buffer (list editor other))
                (with-current-buffer buffer
                  (dolist (binding dwindle-evil-test--bindings)
                    (should (eq (key-binding (kbd (car binding))) #'ignore)))))))
        (when (buffer-live-p other)
          (with-current-buffer other (evil-local-mode -1))
          (kill-buffer other))))))

(ert-deftest dwindle-evil-lowercase-scratch-key-invokes-the-command-in-normal-and-insert ()
  (dolist (state '(normal insert))
    (dwindle-evil-test--with-editor
      (let* ((scratch (get-buffer-create "*scratch*"))
             (contents (with-current-buffer scratch (buffer-string)))
             (source (selected-window)))
        (evil-change-state state)
        (let ((map (if (eq state 'normal)
                       evil-normal-state-local-map evil-insert-state-local-map)))
          (define-key map (kbd "s-e") #'ignore))
        (execute-kbd-macro (kbd "s-e"))
        (should-not (eq (selected-window) source))
        (should (eq (window-buffer (selected-window)) scratch))
        (should (window-live-p source))
        (should (= (length (window-list nil 'nomini)) 2))
        (should (buffer-live-p scratch))
        (with-current-buffer scratch
          (should (equal (buffer-string) contents)))))))

(ert-deftest dwindle-evil-delayed-load-activates-interception ()
  (dwindle-evil-test--require-evil)
  (let ((output (generate-new-buffer " *dwindle-evil-delayed-output*"))
        (program
         `(progn
            (setq load-path ',load-path
                  load-prefer-newer t)
            (require 'dwindle)
            (when (featurep 'evil) (error "Dwindle loaded Evil eagerly"))
            (dwindle-mode 1)
            (when (featurep 'evil) (error "Enabling Dwindle loaded Evil eagerly"))
            (require 'evil)
            (define-key evil-normal-state-map (kbd "s-RET") '+default/newline-below)
            (define-key evil-insert-state-map (kbd "s-RET") #'ignore)
            (with-temp-buffer
              (set-window-buffer (selected-window) (current-buffer))
              (evil-local-mode 1)
              (dolist (state '(normal insert))
                (evil-change-state state)
                (unless (eq (key-binding (kbd "s-RET")) #'dwindle-new-terminal)
                  (error "Delayed Evil activation hid Dwindle in %S" state))))
            (princ "PASS delayed Evil activation\n"))))
    (unwind-protect
        (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                    nil output nil "--batch" "-Q" "--eval"
                                    (prin1-to-string program))))
          (unless (equal status 0)
            (ert-fail (with-current-buffer output (buffer-string))))
          (with-current-buffer output
            (should (string-match-p "PASS delayed Evil activation" (buffer-string)))))
      (kill-buffer output))))

(provide 'dwindle-evil-tests)
;;; dwindle-evil-tests.el ends here
