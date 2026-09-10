;;; dwindle-display-tests.el --- Native display integration checks -*- lexical-binding: t; -*-

(require 'dwindle-tests)
(require 'dwindle-display)
(require 'windmove)

(defmacro dwindle-display-test--with-layout (&rest body)
  "Run BODY in a layout managed by the universal policy."
  (declare (indent 0))
  `(let ((dwindle-test--policy 'all))
     (dwindle-test--with-layout ,@body)))

(ert-deftest dwindle-display-side-action-uses-ordinary-bsp-and-native-quit ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let* ((source (selected-window))
             (display-buffer-mark-dedicated t)
             (alist '((side . bottom) (window-height . 0.1)
                      (window-width . 13) (dedicated . t)
                      (preserve-size . (t . t))
                      (window-parameters
                       (window-side . bottom) (window-slot . 4)
                       (window-atom . t) (window-preserved-size . (t . t))
                       (no-other-window . t) (popup . t) (ttl . 0)
                       (quit-restore . foreign) (delete-window . ignore)
                       (custom-marker . kept))))
             (window (display-buffer-in-side-window (current-buffer) alist)))
        (should (eq (selected-window) source))
        (should (eq (window-buffer window) (current-buffer)))
        (should (dwindle--owned-window-p window))
        (should-not (window-dedicated-p window))
        (should (= (window-total-height source) (window-total-height window)))
        (should (eq (window-parameter window 'custom-marker) 'kept))
        (dolist (parameter '(window-side window-slot window-atom
                            window-preserved-size no-other-window popup ttl
                            delete-window))
          (should-not (window-parameter window parameter)))
        (should (dwindle--restorable-record-p
                 (window-parameter window 'quit-restore)))
        (should (eq (cdr (assq 'dedicated alist)) t))
        (quit-window nil window)
        (should-not (window-live-p window))
        (should (eq (selected-window) source))
        (should (= (length (window-list nil 'nomini)) 1))))))

(ert-deftest dwindle-display-reuses-visible-buffer-and-honors-same-window ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let* ((source (selected-window))
             (buffer (current-buffer))
             (window (display-buffer-in-direction buffer '((direction . right)))))
        (should (eq window (display-buffer-in-side-window buffer nil)))
        (should (= (length (window-list nil 'nomini)) 2))
        (select-window window)
        (should (eq window (display-buffer-in-direction
                            buffer '((direction . below)))))
        (let ((new (display-buffer-in-direction
                    buffer '((direction . below) (inhibit-same-window . t)))))
          (should (window-live-p new))
          (should-not (eq new window))
          (should-not (eq new source))
          (should (eq (selected-window) window))
          (should (= (length (window-list nil 'nomini)) 3)))))))

(ert-deftest dwindle-display-splits-a-leaf-when-its-parent-is-focused ()
  (dwindle-display-test--with-layout
    (let* ((first (selected-window))
           (second (dwindle-split))
           (first-edges (window-edges first)))
      (dwindle-focus-parent)
      (with-temp-buffer
        (let ((window (display-buffer-in-direction
                       (current-buffer) '((direction . right)))))
          (should (eq (selected-window) second))
          (should (window-live-p first))
          (should (window-live-p second))
          (should (equal (window-edges first) first-edges))
          (should (eq (window-parent second) (window-parent window)))
          (should (= (length (window-list nil 'nomini)) 3)))))))

(ert-deftest dwindle-display-small-leaf-reuses-another-pane ()
  (dwindle-display-test--with-layout
    (let* ((first (selected-window))
           (second (dwindle-split))
           (first-edges (window-edges first))
           (second-edges (window-edges second))
           (window-min-width 1000)
           (window-min-height 1000))
      (with-temp-buffer
        (let ((window (display-buffer-in-side-window
                       (current-buffer) '((inhibit-same-window . t)))))
          (should (eq window first))
          (should (eq (selected-window) second))
          (should (equal (window-edges first) first-edges))
          (should (equal (window-edges second) second-edges))
          (should (= (length (window-list nil 'nomini)) 2)))))))

(ert-deftest dwindle-display-native-fallback-without-an-eligible-pane ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let ((window-min-width 1000)
            (window-min-height 1000)
            (snapshot (dwindle-test--snapshot))
            called)
        (should
         (eq 'native
             (dwindle-display--action
              (lambda (_buffer _alist) (setq called t) 'native)
              (current-buffer) '((inhibit-same-window . t)))))
        (should called)
        (should (equal snapshot (dwindle-test--snapshot)))))))

(ert-deftest dwindle-display-ignore-parameter-keeps-a-native-side-window ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let ((window (display-buffer-in-side-window
                     (current-buffer)
                     '((side . bottom)
                       (window-parameters (dwindle-ignore . t))))))
        (should (eq (window-parameter window 'window-side) 'bottom))
        (should (window-parameter window 'dwindle-ignore))
        (should-not (dwindle--managed-window-p window))))))

(ert-deftest dwindle-display-callback-failures-restore-layout-and-selection ()
  (dolist (callback '(error replace insert select-error))
    (dwindle-display-test--with-layout
      (with-temp-buffer
        (let* ((source (selected-window))
               (snapshot (dwindle-test--snapshot))
               (function
                (lambda (window)
                  (pcase callback
                    ('error (error "Display failed"))
                    ('replace
                     (set-window-buffer window (get-buffer-create "*scratch*")))
                    ('insert (split-window window nil 'below))
                    ('select-error
                     (select-window window)
                     (error "Selection failed"))))))
          (should-error
           (display-buffer-in-direction (current-buffer)
                                        `((direction . right)
                                          (body-function . ,function))))
          (should (equal snapshot (dwindle-test--snapshot)))
          (should (eq (selected-window) source)))))))

(ert-deftest dwindle-display-failure-restores-application-window-restrictions ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let* ((side (let ((dwindle--inhibit t))
                     (display-buffer-in-side-window
                      (current-buffer)
                      '((side . bottom)
                        (window-parameters (no-other-window . t))))))
             (dedication (window-dedicated-p side)))
        (select-window side)
        (let ((snapshot (dwindle-test--snapshot)))
          (with-temp-buffer
            (should-error
             (display-buffer-in-direction
              (current-buffer)
              '((direction . right)
                (body-function . (lambda (_) (error "Display failed")))))))
          (should (equal snapshot (dwindle-test--snapshot)))
          (should (eq (selected-window) side))
          (should (eq (window-dedicated-p side) dedication))
          (should (eq (window-parameter side 'window-side) 'bottom))
          (should (window-parameter side 'no-other-window)))))))

(ert-deftest dwindle-display-failed-split-restores-application-restrictions ()
  (dwindle-display-test--with-layout
    (with-temp-buffer
      (let* ((side (let ((dwindle--inhibit t))
                     (display-buffer-in-side-window
                      (current-buffer)
                      '((side . bottom) (slot . 2)
                        (window-parameters (no-other-window . t))))))
             (dedication (window-dedicated-p side)))
        (select-window side)
        (let ((snapshot (dwindle-test--snapshot))
              (window-min-width 1000)
              (window-min-height 1000))
          (should-error (dwindle-split))
          (should (equal snapshot (dwindle-test--snapshot)))
          (should (eq (selected-window) side))
          (should (eq (window-dedicated-p side) dedication))
          (should (eq (window-parameter side 'window-side) 'bottom))
          (should (eql (window-parameter side 'window-slot) 2))
          (should (window-parameter side 'no-other-window)))))))

(ert-deftest dwindle-display-inhibited-command-keeps-application-restrictions ()
  (dwindle-display-test--with-layout
    (let ((window (selected-window)))
      (set-window-dedicated-p window t)
      (set-window-parameter window 'no-other-window t)
      (let ((dwindle--inhibit t))
        (should-error (dwindle-split)))
      (should (eq (window-dedicated-p window) t))
      (should (window-parameter window 'no-other-window)))))

(ert-deftest dwindle-display-windmove-includes-application-marked-panes ()
  (dwindle-display-test--with-layout
    (let ((first (selected-window)))
      (dwindle-split)
      (set-window-parameter first 'no-other-window t)
      (set-window-parameter first 'popup t)
      (windmove-left)
      (should (eq (selected-window) first))
      (should-not (window-parameter first 'no-other-window)))))

(ert-deftest dwindle-display-advice-follows-mode-toggles ()
  (dwindle-display-test--with-layout
    (dotimes (_ 2)
      (dolist (action '(display-buffer-in-direction display-buffer-in-side-window))
        (should (advice-member-p #'dwindle-display--action action)))
      (dolist (command dwindle-display--commands)
        (should (advice-member-p #'dwindle-display--command command)))
      (should (advice-member-p #'dwindle-display--windmove
                              'windmove-do-window-select))
      (dwindle-mode -1)
      (dolist (action '(display-buffer-in-direction display-buffer-in-side-window))
        (should-not (advice-member-p #'dwindle-display--action action)))
      (dolist (command dwindle-display--commands)
        (should-not (advice-member-p #'dwindle-display--command command)))
      (should-not (advice-member-p #'dwindle-display--windmove
                                  'windmove-do-window-select))
      (dwindle-mode 1))))

(provide 'dwindle-display-tests)
;;; dwindle-display-tests.el ends here
