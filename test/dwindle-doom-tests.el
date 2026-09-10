;;; dwindle-doom-tests.el --- Doom popup integration checks -*- lexical-binding: t; -*-

(require 'dwindle-tests)

(defvar +popup-default-display-buffer-actions)
(defvar +popup--inhibit-select)
(defvar-local +popup-buffer-mode nil)
(defvar-local +popup--timer nil)
(defvar dwindle-doom-test--action-calls 0)
(defvar dwindle-doom-test--init-calls 0)

(defun dwindle-doom-test--normalize (alist)
  "Add the default parameters relevant to Doom popup ownership to ALIST."
  (cons (cons 'window-parameters
              (append (cdr (assq 'window-parameters alist))
                      '((transient . t) (quit . t) (select . ignore)
                        (no-other-window . t))))
        (assq-delete-all 'window-parameters (copy-sequence alist))))

(defun dwindle-doom-test--action (buffer alist)
  "Display BUFFER with ALIST using Doom's native side-window fallback."
  (cl-incf dwindle-doom-test--action-calls)
  (display-buffer-in-side-window buffer alist))

(defun dwindle-doom-test--buffer-mode (arg)
  "Set fixture popup buffer mode according to ARG."
  (setq-local +popup-buffer-mode (> arg 0)))

(defun dwindle-doom-test--terminal-toggle (buffer)
  "Display BUFFER and dedicate it as Doom's terminal toggles do."
  (let ((window (+popup-buffer buffer '((window-parameters (select . t))))))
    (set-window-dedicated-p window t)
    buffer))

(defun dwindle-doom-test--buffer (buffer &optional alist)
  "Run Doom's reuse/action/init sequence for BUFFER and ALIST."
  (let* ((alist (+popup--normalize-alist alist))
         (actions (or (cdr (assq 'actions alist))
                      +popup-default-display-buffer-actions)))
    (or (display-buffer-reuse-window buffer alist)
        (when-let* ((window (cl-loop for action in actions
                                    thereis (funcall action buffer alist))))
          (cl-incf dwindle-doom-test--init-calls)
          (set-window-parameter window 'popup t)
          (set-window-dedicated-p window 'popup)
          (with-current-buffer buffer (+popup-buffer-mode 1))
          window))))

(defmacro dwindle-doom-test--with-popups (&rest body)
  "Run BODY with isolated Doom popup functions and native windows."
  (declare (indent 0))
  `(let ((dwindle-manage-windows 'all)
         (dwindle-doom-manage-popups t)
         (+popup-default-display-buffer-actions
          '(+popup-display-buffer-stacked-side-window-fn))
         (+popup--inhibit-select nil)
         (dwindle-doom-test--action-calls 0)
         (dwindle-doom-test--init-calls 0))
     (cl-letf (((symbol-function '+popup--normalize-alist)
                #'dwindle-doom-test--normalize)
               ((symbol-function '+popup-buffer) #'dwindle-doom-test--buffer)
               ((symbol-function '+popup-buffer-mode)
                #'dwindle-doom-test--buffer-mode)
               ((symbol-function '+eshell/toggle) #'dwindle-doom-test--terminal-toggle)
               ((symbol-function '+vterm/toggle) #'dwindle-doom-test--terminal-toggle)
               ((symbol-function '+popup-display-buffer-stacked-side-window-fn)
                #'dwindle-doom-test--action))
       (dwindle-test--with-layout ,@body))))

(ert-deftest dwindle-doom-popup-rule-creates-an-ordinary-rotatable-help-pane ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (rename-buffer " *dwindle-doom-help*")
      (special-mode)
      (let* ((source (selected-window))
             (display-buffer-alist
              `((,(regexp-quote (buffer-name)) (+popup-buffer)
                 (side . bottom) (window-height . 0.2) (window-width . 40)
                 (window-parameters (select . t) (ttl . 0) (quit . t)
                                    (modeline . nil) (custom-marker . test)))))
             (window (display-buffer (current-buffer))))
        (should (eq (selected-window) window))
        (should (eq (window-buffer window) (current-buffer)))
        (should (dwindle--owned-window-p window))
        (should-not (window-dedicated-p window))
        (should (= (window-total-height source) (window-total-height window)))
        (should (eq (window-parameter window 'custom-marker) 'test))
        (dolist (parameter '(popup no-other-window ttl quit transient select
                            modeline window-side split-window delete-window))
          (should-not (window-parameter window parameter)))
        (should-not +popup-buffer-mode)
        (should (= dwindle-doom-test--action-calls 0))
        (should (= dwindle-doom-test--init-calls 0))
        (dwindle-focus-parent)
        (dwindle-rotate)
        (should (get-buffer-window (current-buffer)))
        (should (cl-every #'dwindle--owned-window-p (window-list nil 'nomini)))))))

(ert-deftest dwindle-doom-popup-selection-and-managed-reuse ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let* ((buffer (current-buffer))
             (source (selected-window))
             (window (+popup-buffer buffer
                                    '((window-parameters (select . nil))))))
        (should (eq (selected-window) source))
        (should (eq window (+popup-buffer buffer
                                         '((window-parameters (select . t))))))
        (should (eq (selected-window) window))
        (should (= (length (window-list nil 'nomini)) 2))
        (should-not (window-parameter window 'no-other-window))
        (let ((+popup--inhibit-select t))
          (select-window source)
          (+popup-buffer buffer '((window-parameters (select . t))))
          (should (eq (selected-window) source)))))))

(ert-deftest dwindle-doom-popup-splits-a-leaf-when-parent-is-focused ()
  (dwindle-doom-test--with-popups
    (let* ((first (selected-window))
           (second (dwindle-split))
           (first-edges (window-edges first)))
      (dwindle-focus-parent)
      (with-temp-buffer
        (let ((window (+popup-buffer (current-buffer))))
          (should (window-live-p first))
          (should (window-live-p second))
          (should (equal (window-edges first) first-edges))
          (should (eq (window-parent second) (window-parent window)))
          (should (= (length (window-list nil 'nomini)) 3)))))))

(ert-deftest dwindle-doom-direct-popup-action-routes-without-selecting ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let* ((source (selected-window))
             (window (+popup-display-buffer-stacked-side-window-fn
                      (current-buffer) '((side . bottom)
                                          (window-parameters (no-other-window . t))))))
        (should (dwindle--owned-window-p window))
        (should (eq (selected-window) source))
        (should-not (window-parameter window 'window-side))
        (should-not (window-parameter window 'no-other-window))))))

(ert-deftest dwindle-doom-popup-optouts-retain-native-side-windows ()
  (dolist (optout '(option explicit disabled ignore dedicated))
    (dwindle-doom-test--with-popups
      (with-temp-buffer
        (pcase optout
          ('option (setq dwindle-doom-manage-popups nil))
          ('explicit (setq dwindle-manage-windows 'explicit))
          ('disabled (dwindle-mode -1)))
        (let ((window (+popup-buffer
                       (current-buffer)
                       (pcase optout
                         ('ignore '((window-parameters (dwindle-ignore . t))))
                         ('dedicated '((dedicated . t)))))))
          (should (window-parameter window 'window-side))
          (should (window-parameter window 'popup))
          (should (= dwindle-doom-test--init-calls 1))
          (should (= dwindle-doom-test--action-calls 1)))))))

(ert-deftest dwindle-doom-custom-popup-actions-retain-their-lifecycle ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let* ((custom-called nil)
             (custom (lambda (buffer alist)
                       (setq custom-called t)
                       (+popup-display-buffer-stacked-side-window-fn buffer alist)))
             (window (+popup-buffer (current-buffer) `((actions ,custom)))))
        (should custom-called)
        (should (window-parameter window 'popup))
        (should (window-parameter window 'window-side))
        (should (= dwindle-doom-test--init-calls 1))))))

(ert-deftest dwindle-doom-custom-default-action-retains-its-lifecycle ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (cl-letf (((symbol-function '+popup--normalize-alist)
                 (lambda (alist)
                   (cons '(actions display-buffer-in-side-window)
                         (dwindle-doom-test--normalize alist)))))
        (let ((window (+popup-buffer (current-buffer))))
          (should (window-parameter window 'popup))
          (should (window-parameter window 'window-side))
          (should (= dwindle-doom-test--init-calls 1)))))))

(ert-deftest dwindle-doom-no-display-action-and-native-side-action-are-respected ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let ((display-buffer-overriding-action
             '((display-buffer-no-window) (allow-no-window . t)))
            (display-buffer-alist '(("." (+popup-buffer)))))
        (should-not (display-buffer (current-buffer))))
      (should (= (length (window-list nil 'nomini)) 1))
      (let ((window (display-buffer-in-side-window (current-buffer) nil)))
        (should (window-parameter window 'window-side))
        (should-not (dwindle--owned-window-p window))))))

(ert-deftest dwindle-doom-popup-from-protected-origin-splits-the-editor ()
  (dwindle-doom-test--with-popups
    (let ((editor (selected-window)))
      (with-temp-buffer
        (let* ((side (display-buffer-in-side-window (current-buffer) nil))
               (edges (window-edges side)))
          (select-window side)
          (with-temp-buffer
            (let ((window (+popup-buffer (current-buffer))))
              (should (dwindle--owned-window-p window))
              (should (eq (selected-window) side))
              (should (equal (window-edges side) edges))
              (should (eq (window-parent editor) (window-parent window)))
              (should (= dwindle-doom-test--action-calls 0)))))))))

(ert-deftest dwindle-doom-popup-small-focused-leaf-reuses-an-ordinary-pane ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let* ((source (selected-window))
             (window-min-width (window-total-width))
             (window (+popup-buffer (current-buffer) '((side . bottom)))))
        (should (eq window source))
        (should (dwindle--owned-window-p window))
        (should-not (window-parameter window 'popup))
        (should (= dwindle-doom-test--action-calls 0))))))

(ert-deftest dwindle-doom-no-usable-ordinary-pane-falls-back-to-doom ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      ;; Prevent an ordinary horizontal split while leaving room below
      ;; the root for Doom's original popup action.  Explicitly prevent
      ;; reuse of the only ordinary pane, too.
      (let* ((window-min-width (window-total-width))
             (window (+popup-buffer (current-buffer)
                                    '((side . bottom) (inhibit-same-window . t)))))
        (should (window-parameter window 'popup))
        (should (eq (window-parameter window 'window-side) 'bottom))
        (should (= dwindle-doom-test--action-calls 1))))))

(ert-deftest dwindle-doom-existing-popup-keeps-its-identity-and-parameters ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (let* ((window (let ((dwindle-doom-manage-popups nil))
                       (+popup-buffer (current-buffer))))
             (parameters (window-parameters window))
             (edges (window-edges window)))
        (should (eq window (+popup-buffer (current-buffer))))
        (should (equal parameters (window-parameters window)))
        (should (equal edges (window-edges window)))
        (should +popup-buffer-mode)
        (should-not (dwindle--owned-window-p window))))))

(ert-deftest dwindle-doom-reopened-popup-clears-stale-buffer-lifecycle ()
  (dwindle-doom-test--with-popups
    (with-temp-buffer
      (setq-local +popup-buffer-mode t)
      (setq-local +popup--timer (run-at-time 3600 nil #'ignore))
      (add-hook 'kill-buffer-hook #'+popup-kill-buffer-hook-h nil t)
      (let ((timer +popup--timer))
        (unwind-protect
            (progn
              (should (dwindle--owned-window-p (+popup-buffer (current-buffer))))
              (should-not +popup-buffer-mode)
              (should-not +popup--timer)
              (should-not (memq timer timer-list))
              (should-not (memq #'+popup-kill-buffer-hook-h kill-buffer-hook)))
          (cancel-timer timer))))))

(ert-deftest dwindle-doom-popup-callback-ownership-and-layout-failures-roll-back ()
  (dolist (callback '(claim replace insert select-error select-recurse))
    (dwindle-doom-test--with-popups
      (with-temp-buffer
        (let* ((snapshot (dwindle-test--snapshot))
               (function
                (lambda (window &rest _)
                  (pcase callback
                    ('claim (set-window-dedicated-p window t))
                    ('replace (set-window-buffer window (get-buffer-create "*scratch*")))
                    ('insert (split-window window nil 'below))
                    ('select-error (error "Selection failed"))
                    ('select-recurse (with-selected-window window (dwindle-split))))))
               (alist (if (memq callback '(select-error select-recurse))
                          `((window-parameters (select . ,function)))
                        `((body-function . ,function)))))
          (should-error (+popup-buffer (current-buffer) alist))
          (should (equal snapshot (dwindle-test--snapshot)))
          (should (= dwindle-doom-test--action-calls 0)))))))

(ert-deftest dwindle-doom-popup-advice-follows-mode-toggles ()
  (dwindle-doom-test--with-popups
    (dotimes (_ 2)
      (should (advice-member-p #'dwindle-doom--popup-buffer '+popup-buffer))
      (should (advice-member-p #'dwindle-doom--popup-action
                               '+popup-display-buffer-stacked-side-window-fn))
      (dolist (command '(+eshell/toggle +vterm/toggle))
        (should (advice-member-p #'dwindle-doom--terminal-toggle command)))
      (dwindle-mode -1)
      (should-not (advice-member-p #'dwindle-doom--popup-buffer '+popup-buffer))
      (should-not (advice-member-p #'dwindle-doom--popup-action
                                   '+popup-display-buffer-stacked-side-window-fn))
      (dolist (command '(+eshell/toggle +vterm/toggle))
        (should-not (advice-member-p #'dwindle-doom--terminal-toggle command)))
      (dwindle-mode 1))))

(ert-deftest dwindle-doom-terminal-toggles-keep-routed-panes-managed ()
  (dolist (command '(+eshell/toggle +vterm/toggle))
    (dwindle-doom-test--with-popups
      (with-temp-buffer
        (let ((buffer (current-buffer)))
          (should (eq (funcall command buffer) buffer))
          (let ((window (get-buffer-window buffer)))
            (should-not (window-dedicated-p window))
            (should (dwindle--owned-window-p window))
            (dwindle-focus-parent)
            (dwindle-rotate)
            (should (dwindle--owned-window-p (get-buffer-window buffer)))))))))

(ert-deftest dwindle-doom-terminal-toggles-retain-foreign-and-opted-out-panes ()
  (dolist (scenario '(existing-side optout explicit))
    (dwindle-doom-test--with-popups
      (with-temp-buffer
        (let ((buffer (current-buffer)))
          (pcase scenario
            ('existing-side (display-buffer-in-side-window buffer nil))
            ('optout (setq dwindle-doom-manage-popups nil))
            ('explicit (setq dwindle-manage-windows 'explicit)))
          (+eshell/toggle buffer)
          (let ((window (get-buffer-window buffer)))
            (should (window-dedicated-p window))
            (should (window-parameter window 'window-side))
            (should-not (dwindle--owned-window-p window))))))))

(ert-deftest dwindle-doom-real-popup-rules-and-late-load ()
  ;; Optional real integration, comparable to dwindle-evil-tests.  A fresh
  ;; process avoids installing Doom's global rules/hooks in the test runner.
  (let* ((directory
          (or (getenv "DWINDLE_DOOM_POPUP_DIR")
              (expand-file-name
               "~/.config/emacs/sources/doom+/modules/ui/popup/")))
         (config (expand-file-name "config.el" directory))
         (popup (expand-file-name "autoload/popup.el" directory))
         (settings (expand-file-name "autoload/settings.el" directory))
         (eshell (expand-file-name "../../term/eshell/autoload/eshell.el" directory))
         (vterm (expand-file-name "../../term/vterm/autoload.el" directory)))
    (unless (cl-every #'file-readable-p (list config popup settings))
      (ert-skip "Set DWINDLE_DOOM_POPUP_DIR to an installed Doom ui/popup module"))
    (let* ((output (generate-new-buffer " *dwindle-doom-real-output*"))
           (program
            `(progn
               (setq load-path ',load-path load-prefer-newer t)
               (require 'ert)
               (require 'dwindle)
               (require 'help-mode)
               ;; Only Doom's module/bootstrap macros are stubbed; the rule
               ;; builder, modes, actions and popup lifecycle are real.
               (defmacro modulep! (&rest _) nil)
               (defmacro load! (&rest _) nil)
               (dwindle-mode 1)
               (load ,popup nil t)
               (load ,settings nil t)
               (load ,config nil t)
               (+popup-mode 1)
               (set-frame-size (selected-frame) 160 90)
               (let* ((buffer (get-buffer-create "*dwindle-real-help*"))
                      (origin (selected-window))
                      (display-buffer-alist
                       (list (+popup-make-rule
                              "^\\*dwindle-real-help\\*$"
                              '(:select t :size 0.3 :ttl 0)))))
                 (with-current-buffer buffer (help-mode))
                 (let ((window (display-buffer buffer)))
                   (should (dwindle--owned-window-p window))
                   (should (eq (selected-window) window))
                   (should-not (window-parameter window 'popup))
                   (should-not (window-parameter window 'window-side))
                   (should-not (window-parameter window 'no-other-window))
                   (should-not (buffer-local-value '+popup-buffer-mode buffer))
                   (should (window-live-p origin))
                   (dwindle-focus-parent)
                   (dwindle-rotate)
                   (should (dwindle--owned-window-p (get-buffer-window buffer)))
                   (quit-window nil (get-buffer-window buffer))
                   (should (buffer-live-p buffer))
                   (should (= (length (window-list nil 'nomini)) 1))))
               ;; Disabling removes both wrappers and restores real popup
               ;; initialization, dedication and side-window geometry.
               (dwindle-mode -1)
               (let* ((buffer (get-buffer-create "*dwindle-real-popup*"))
                      (window (+popup-buffer buffer '((side . bottom)))))
                 (should (window-parameter window 'popup))
                 (should (eq (window-parameter window 'window-side) 'bottom))
                 (should (buffer-local-value '+popup-buffer-mode buffer)))
               ;; Exercise the real toggle commands when those modules are
               ;; installed too.  Eshell is real; Vterm's external backend
               ;; is stubbed so no native module or shell process is needed.
               (when (and (file-readable-p ,eshell) (file-readable-p ,vterm))
                 (dwindle-mode 1)
                 (require 'eshell)
                 (require 'esh-mode)
                 (load ,eshell nil t)
                 (load ,vterm nil t)
                 (defun doom-mark-buffer-as-real-h () nil)
                 (defun doom-project-root () nil)
                 (defun doom-buffers-in-mode (_mode) nil)
                 (defun vterm-mode () (setq major-mode 'vterm-mode))
                 (let ((eshell-directory-name (make-temp-file "dwindle-doom-eshell-" t))
                       (display-buffer-alist
                        (list (+popup-make-rule "." '(:select t)))))
                   (unwind-protect
                       (dolist (command '(+eshell/toggle +vterm/toggle))
                         (funcall command nil)
                         (let ((buffer (window-buffer)))
                           (should (dwindle--owned-window-p (selected-window)))
                           (should-not (window-dedicated-p (selected-window)))
                           (should-not (window-parameter nil 'popup))
                           (dwindle-focus-parent)
                           (dwindle-rotate)
                           (should (dwindle--owned-window-p (get-buffer-window buffer)))
                           (funcall command nil)
                           (should-not (get-buffer-window buffer))))
                     (delete-directory eshell-directory-name t))))
               (princ "PASS real Doom popup rules and delayed load\n"))))
      (unwind-protect
          (let ((status (call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil output nil "--batch" "-Q" "--eval"
                         (prin1-to-string program))))
            (unless (equal status 0)
              (ert-fail (with-current-buffer output (buffer-string))))
            (with-current-buffer output
              (should (string-match-p "PASS real Doom popup rules" (buffer-string)))))
        (kill-buffer output)))))

(provide 'dwindle-doom-tests)
;;; dwindle-doom-tests.el ends here
