;;; dwindle-tree-tests.el --- BSP transformation regression tests -*- lexical-binding: t; -*-

(require 'dwindle-tree)

(defun dwindle-tree-test--split (&optional window size side pixelwise)
  "Create an intentionally Dwindle-owned test pane with native geometry.
This also models explicit user ownership under the conservative policy,
while allowing imported n-ary and custom-ratio fixtures."
  (let* ((window (or window (selected-window)))
         (new (split-window window size side pixelwise)))
    (dwindle--claim-window window)
    (dwindle--claim-window new)
    new))

(defun dwindle-tree-test--buffers ()
  "Return managed buffers in tree order."
  (mapcar #'window-buffer (dwindle-test--windows)))

(defun dwindle-tree-test--label (windows)
  "Assign WINDOWS separate test buffers, returning those buffers."
  (cl-loop for window in windows for index from 1
           collect (let ((buffer (get-buffer-create (format " *bsp-%d*" index))))
                     (with-current-buffer buffer
                       (erase-buffer)
                       (dotimes (n 300) (insert (format "%03d example text\n" n))))
                     (set-window-buffer window buffer)
                     (dwindle--claim-window window)
                     buffer)))

(ert-deftest dwindle-tree-rotate-adopts-native-split-before-configuration-hook ()
  (dwindle-test--with-layout
    (let* ((left (selected-window))
           (right (split-window left nil 'right))
           (left-buffer (window-buffer left))
           (buffer (generate-new-buffer " *dwindle-native-pane*")))
      (unwind-protect
          (progn
            (set-window-buffer right buffer)
            (select-window right)
            ;; This is the first Dwindle query after native window creation.
            (dwindle-rotate)
            (should (window-combination-p (frame-root-window)))
            (should (equal (dwindle-tree-test--buffers)
                           (list left-buffer buffer)))
            (should (eq (window-buffer (selected-window)) buffer))
            (should (cl-every #'dwindle--owned-window-p
                              (dwindle-test--windows))))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-help-and-compilation-display-remain-usable ()
  (require 'help-mode)
  (require 'compile)
  (dolist (kind '(help compilation))
    (dwindle-test--with-layout
      (let* ((editor (selected-window))
             (editor-buffer (window-buffer editor))
             (buffer (generate-new-buffer " *dwindle-special-display*"))
             (display-buffer-overriding-action
              '(display-buffer-pop-up-window))
             (help-window-select nil))
        (unwind-protect
            (progn
              (if (eq kind 'help)
                  (with-help-window buffer
                    (princ "A normal Help buffer should participate in the tree.\n"))
                (with-current-buffer buffer
                  (insert "Compilation finished.\n")
                  (compilation-mode))
                (display-buffer buffer))
              (let ((displayed (get-buffer-window buffer)))
                (should (window-live-p displayed))
                (should-not (eq displayed editor))
                (should (eq (selected-window) editor))
                (with-current-buffer buffer
                  (should (eq major-mode (if (eq kind 'help)
                                             'help-mode 'compilation-mode)))
                  (when (eq kind 'help)
                    (should (derived-mode-p 'special-mode))))
                (should (window-parameter displayed 'quit-restore))
                (should (dwindle--owned-window-p displayed))
                (select-window displayed)
                (dwindle-rotate)
                (should (window-combination-p (frame-root-window)))
                (should (equal (dwindle-tree-test--buffers)
                               (list editor-buffer buffer)))
                (should (eq (window-buffer (selected-window)) buffer))
                (should (cl-every #'dwindle--owned-window-p
                                  (dwindle-test--windows)))))
          (kill-buffer buffer))))))

(ert-deftest dwindle-tree-rotate-toggles-parent-preserving-ratio-order-and-views ()
  (dwindle-test--with-layout
    (let* ((left (selected-window))
           (right (dwindle-tree-test--split left 96 'right))
           (buffers (dwindle-tree-test--label (list left right)))
           (ratio (/ (float (window-total-width left))
                     (window-total-width (window-parent left))))
           (height (window-total-height left)))
      (select-window right)
      (set-window-point right 200)
      (set-window-start right 100 t)
      (set-window-hscroll right 7)
      (set-window-parameter right 'bsp-test 'preserved)
      (dwindle-rotate)
      (let ((windows (dwindle-test--windows)))
        (should (window-combination-p (window-parent (car windows))))
        (should (= (window-total-height (car windows)) (floor (* height ratio))))
        (should (equal buffers (dwindle-tree-test--buffers)))
        (should (eq (window-buffer (selected-window)) (cadr buffers)))
        (should (= (window-point (selected-window)) 200))
        (should (= (window-start (selected-window)) 100))
        (should (= (window-hscroll (selected-window)) 7))
        (should (eq (window-parameter (selected-window) 'bsp-test) 'preserved))))))

(ert-deftest dwindle-tree-nested-rotate-preserves-outside-ordinary-and-side-windows ()
  (dwindle-test--with-layout
    (let* ((side (display-buffer-in-side-window
                  (get-buffer-create " *bsp-side*") '((side . bottom))))
           (a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (outside (mapcar (lambda (w) (list w (window-edges w) (window-buffer w)))
                            (list a side))))
      (select-window c)
      (dwindle-rotate)
      (should (equal outside
                     (mapcar (lambda (w) (list w (window-edges w) (window-buffer w)))
                             (list a side))))
      (should (= (length (window-list nil 'nomini)) 4)))))

(ert-deftest dwindle-tree-foreign-sibling-is-a-transformation-barrier ()
  (dwindle-test--with-layout
    (let* ((foreign (selected-window))
           (ordinary (dwindle-tree-test--split foreign nil 'right)))
      (set-window-dedicated-p foreign t)
      (select-window ordinary)
      (let ((before (dwindle-test--snapshot)))
        (dwindle-rotate)
        (dwindle-swap)
        (should (eq (dwindle-focus-parent) ordinary))
        (should (equal before (dwindle-test--snapshot)))))))

(ert-deftest dwindle-tree-explicit-policy-protects-unmarked-package-window ()
  (dwindle-test--with-layout
    (let* ((dwindle-manage-windows 'explicit)
           (owned (selected-window))
           ;; A package can create a plain window and retain its object
           ;; without installing ANY ownership or opt-out window parameter.
           (package-window (split-window owned nil 'right))
           (package-buffer (get-buffer-create " *opaque-package-window*"))
           (saved-reference package-window))
      (set-window-buffer package-window package-buffer)
      (should-not (dwindle--owned-window-p package-window))
      (select-window owned)
      (let ((before (dwindle-test--snapshot)))
        (dwindle-rotate)
        (dwindle-swap)
        (dwindle-focus-parent)
        (dwindle-balance)
        (should (equal before (dwindle-test--snapshot))))
      (should (window-live-p saved-reference))
      (should (eq (window-buffer saved-reference) package-buffer))
      (let ((tree (dwindle--tree-capture (frame-root-window))))
        (should-error (dwindle--tree-apply (frame-root-window) tree)
                      :type 'user-error)))))

(ert-deftest dwindle-tree-explicit-policy-rotates-beside-unmarked-package-window ()
  (dwindle-test--with-layout
    (let* ((dwindle-manage-windows 'explicit)
           (a (selected-window))
           (foreign (split-window a -40 'right))
           (foreign-buffer (get-buffer-create " *opaque-package-pane*"))
           (b (dwindle-tree-test--split a nil 'below)))
      (set-window-buffer foreign foreign-buffer)
      (select-window b)
      (let ((before (list foreign (window-edges foreign nil nil t)
                          (window-buffer foreign))))
        (dwindle-rotate)
        (should (equal before (list foreign (window-edges foreign nil nil t)
                                    (window-buffer foreign))))
        (should (window-combination-p (window-parent (selected-window)) t))
        (should (dwindle--owned-window-p (selected-window)))
        (should (dwindle--owned-window-p (window-prev-sibling (selected-window))))
        (should-not (dwindle--owned-window-p foreign))))))

(ert-deftest dwindle-tree-explicit-policy-protects-display-buffer-reference ()
  (dwindle-test--with-layout
    (let* ((dwindle-manage-windows 'explicit)
           (owned (selected-window))
           (buffer (get-buffer-create " *display-buffer-package*"))
           (foreign (display-buffer buffer '(display-buffer-pop-up-window))))
      (should (window-live-p foreign))
      (should (window-parameter foreign 'quit-restore))
      (should-not (dwindle--owned-window-p foreign))
      (select-window owned)
      (let ((before (dwindle-test--snapshot)))
        (dwindle-rotate)
        (should (equal before (dwindle-test--snapshot))))
      (should (window-live-p foreign))
      (should (eq (window-buffer foreign) buffer)))))

(ert-deftest dwindle-tree-commands-refuse-selected-foreign-window ()
  (dwindle-test--with-layout
    (dwindle-tree-test--split nil nil 'right)
    (unwind-protect
        (progn
          (set-window-parameter (selected-window) 'popup t)
          (dolist (command '(dwindle-rotate dwindle-swap dwindle-rotate-left
                             dwindle-rotate-right dwindle-focus-parent
                             dwindle-equalize dwindle-balance))
            (should-error (funcall command) :type 'user-error)))
      (set-window-parameter (selected-window) 'popup nil))))

(ert-deftest dwindle-tree-minimum-refusal-never-mutates-layout ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'below)))
      (dwindle-tree-test--split b nil 'right)
      (select-window a)
      (let ((window-min-width 70)
            (before (dwindle-test--snapshot)))
        (should-error (dwindle-rotate) :type 'user-error)
        (should (equal before (dwindle-test--snapshot)))))))

(ert-deftest dwindle-tree-fixed-buffer-size-refusal-never-mutates-layout ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffer (generate-new-buffer " *bsp-fixed*")))
      (unwind-protect
          (progn
            (set-window-buffer b buffer)
            (with-current-buffer buffer (setq-local window-size-fixed 'width))
            (dwindle--claim-window b)
            (let ((before (dwindle-test--snapshot)))
              (should-error (dwindle-rotate) :type 'user-error)
              (should (equal before (dwindle-test--snapshot)))))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-rotation-preserves-per-window-buffer-histories ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (old (get-buffer-create " *bsp-history-old*"))
           (current (get-buffer-create " *bsp-history-current*"))
           (next (get-buffer-create " *bsp-history-next*")))
      (set-window-buffer b old)
      (set-window-buffer b current)
      (dwindle--claim-window b)
      (set-window-next-buffers b (list next))
      (select-window b)
      (let ((previous (window-prev-buffers b))
            (following (window-next-buffers b)))
        (dwindle-rotate)
        (should (equal previous (window-prev-buffers (selected-window))))
        (should (equal following (window-next-buffers (selected-window))))))))

(ert-deftest dwindle-tree-failed-split-restores-window-identities-and-selection ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (native-split (symbol-function 'split-window)))
      (select-window c)
      (let ((before (dwindle-test--snapshot)))
        (cl-letf (((symbol-function 'split-window)
                   (lambda (&rest args)
                     (apply native-split args)
                     (error "Injected error after native split"))))
          (should-error (dwindle-rotate)))
        (should (equal before (dwindle-test--snapshot)))
        (should (eq (selected-window) c))
        (should (window-live-p a))
        (should (window-live-p b))))))

(ert-deftest dwindle-tree-swap-preserves-focused-buffer-and-ratio ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a 96 'right))
           (buffers (dwindle-tree-test--label (list a b))))
      (select-window b)
      (dwindle-swap)
      (should (equal (reverse buffers) (dwindle-tree-test--buffers)))
      (should (eq (window-buffer (selected-window)) (cadr buffers)))
      (should (= (window-total-width (car (dwindle-test--windows))) 96)))))

(ert-deftest dwindle-tree-focus-parent-cycles-and-invalidates-dead-subtrees ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below)))
      (select-window c)
      (should (eq (dwindle-focus-parent) (window-parent c)))
      (should (eq (dwindle-focus-parent) (frame-root-window)))
      (should (eq (dwindle-focus-parent) c))
      (dwindle-focus-parent)
      (delete-window b)
      (should (eq (dwindle--focused-node) c))
      (dwindle-focus-parent)
      (select-window a)
      (should (eq (dwindle--focused-node) a)))))

(ert-deftest dwindle-tree-root-rotate-and-leaf-equalize-are-noops ()
  (dwindle-test--with-layout
    (dwindle-tree-test--split nil nil 'right)
    (let ((before (dwindle-test--snapshot)))
      (dwindle-equalize)
      (dwindle-balance)
      (dwindle-focus-parent)
      (dwindle-rotate)
      (dwindle-swap)
      (should (equal before (dwindle-test--snapshot))))))

(ert-deftest dwindle-tree-equalize-apportions-area-by-leaf-count ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a 96 'right)))
      (dwindle-tree-test--split b nil 'below)
      (select-window a)
      (dwindle-focus-parent)
      (dwindle-equalize)
      (let* ((windows (dwindle-test--windows))
             (root (frame-root-window))
             (expected (floor (/ (window-total-width root) 3.0))))
        (should (= (window-total-width (car windows)) expected))
        (should (eq (dwindle--focused-node) (selected-window)))))))

(ert-deftest dwindle-tree-balance-normalizes-nary-tree-preserving-order ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (window-combination-limit nil)
           (b (dwindle-tree-test--split a 50 'right))
           (c (dwindle-tree-test--split b 50 'right))
           (buffers (dwindle-tree-test--label (list a b c))))
      (select-window a)
      (should (= (window-child-count (window-parent a)) 3))
      (dwindle-focus-parent)
      (dwindle-balance)
      (should (equal buffers (dwindle-tree-test--buffers)))
      (should (= (window-child-count (frame-root-window)) 2))
      (should (eq (dwindle--focused-node) (selected-window))))))

(ert-deftest dwindle-tree-left-right-reassociation-preserves-order ()
  (dwindle-test--with-layout
    (let* ((window-combination-limit t)
           (a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (buffers (dwindle-tree-test--label (list a b c))))
      (select-window a)
      (dwindle-rotate-left)
      (should (equal buffers (dwindle-tree-test--buffers)))
      (should (window-combination-p (frame-root-window)))
      (select-window (car (last (dwindle-test--windows))))
      (dwindle-rotate-right)
      (should (equal buffers (dwindle-tree-test--buffers)))
      (should (window-combination-p (frame-root-window) t)))))

(ert-deftest dwindle-tree-internal-focus-insertion-preserves-existing-views ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffers (dwindle-tree-test--label (list a b)))
           (new-buffer (get-buffer-create " *bsp-inserted*")))
      (select-window b)
      (dwindle-focus-parent)
      (let ((new (dwindle--split-focused-node b new-buffer)))
        (should (eq (window-buffer new) new-buffer))
        (should (equal (cons new-buffer buffers) (dwindle-tree-test--buffers)))
        (should (eq (window-buffer (selected-window)) (cadr buffers)))
        (should (window-combination-p (window-parent
                                      (cadr (dwindle-test--windows)))))))))

(ert-deftest dwindle-tree-private-buffer-hooks-cannot-reenter-or-leak ()
  (dwindle-test--with-layout
    (dwindle-tree-test--split nil nil 'right)
    (let ((calls 0)
          (before (length (buffer-list))))
      (let ((buffer-list-update-hook
             (list (lambda ()
                     (when (and (not dwindle--inhibit)
                                (cl-some
                                 (lambda (buffer)
                                   (string-prefix-p " *dwindle-tree*"
                                                    (buffer-name buffer)))
                                 (buffer-list)))
                       (cl-incf calls)
                       (when (> calls 3) (error "Unbounded private buffer recursion"))
                       (dwindle-rotate))))))
        (dwindle-rotate))
      (should (= calls 0))
      (should (= before (length (buffer-list)))))))

(ert-deftest dwindle-tree-cycle-valued-window-parameter-is-preserved ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (cycle (list 'cycle)))
      (setcdr cycle cycle)
      (set-window-parameter b 'bsp-cyclic cycle)
      (select-window b)
      (dwindle-rotate)
      (should (eq (window-parameter (selected-window) 'bsp-cyclic) cycle)))))

(ert-deftest dwindle-tree-rollback-restores-nonpersistent-parameters ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (native-split (symbol-function 'split-window)))
      (set-window-parameter a 'bsp-private 'old)
      (select-window b)
      (cl-letf (((symbol-function 'split-window)
                 (lambda (&rest args)
                   (apply native-split args)
                   (set-window-parameter a 'bsp-private 'poisoned)
                   (error "Injected failure"))))
        (should-error (dwindle-rotate)))
      (should (eq (window-parameter a 'bsp-private) 'old)))))

(ert-deftest dwindle-tree-callback-inserting-unexpected-window-rolls-back ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffers (dwindle-tree-test--label (list a b)))
           (native-set-buffer (symbol-function 'set-window-buffer))
           (before (dwindle-test--snapshot))
           fired)
      (cl-letf (((symbol-function 'set-window-buffer)
                 (lambda (window buffer &rest arguments)
                   (prog1 (apply native-set-buffer window buffer arguments)
                     (when (and (not fired) (eq buffer (car buffers)))
                       (setq fired t)
                       (split-window window nil 'right))))))
        (should-error (dwindle-rotate)))
      (should fired)
      (should (equal before (dwindle-test--snapshot))))))

(ert-deftest dwindle-tree-explicit-policy-special-mode-takeover-rolls-back ()
  (dwindle-test--with-layout
    (let* ((dwindle-manage-windows 'explicit)
           (a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffer (generate-new-buffer " *package-takeover*"))
           (native-set-buffer (symbol-function 'set-window-buffer))
           fired)
      (unwind-protect
          (progn
            (set-window-buffer b buffer)
            (dwindle--claim-window b)
            (let ((before (dwindle-test--snapshot)))
              (cl-letf (((symbol-function 'set-window-buffer)
                         (lambda (window displayed &rest arguments)
                           (prog1 (apply native-set-buffer window displayed arguments)
                             (when (and (not fired) (eq displayed buffer))
                               (setq fired t)
                               (with-current-buffer buffer (special-mode)))))))
                (should-error (dwindle-rotate)))
              (should fired)
              (should (equal before (dwindle-test--snapshot)))
              (should (window-live-p b))
              ;; Buffer-mode changes made by package code cannot be undone
              ;; by a window transaction, so protect this pane from now on.
              (should-not (dwindle--owned-window-p b))
              (should (dwindle--owned-window-p a))))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-scroll-hook-ownership-marker-is-never-erased ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffer (generate-new-buffer " *scroll-hook-owner*"))
           fired)
      (unwind-protect
          (progn
            (set-window-buffer b buffer)
            (dwindle--claim-window b)
            (with-current-buffer buffer
              (setq-local window-scroll-functions
                          (list (lambda (window _start)
                                  (setq fired t)
                                  (set-window-parameter
                                   window 'quit-restore
                                   (list 'window 'window window (window-buffer window)))))))
            (let ((before (dwindle-test--snapshot)))
              (should-error (dwindle-rotate))
              (should fired)
              (should (equal before (dwindle-test--snapshot)))
              (should (window-live-p a))
              (should (window-live-p b))
              (should-not (window-parameter b 'quit-restore))))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-native-navigation-record-follows-recreated-window ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffer (generate-new-buffer " *navigation-target*")))
      (unwind-protect
          (progn
            (select-window b)
            ;; Generate the same native reuse record produced by ordinary
            ;; navigation such as Evil's :split FILE, without synthesizing it.
            (display-buffer-record-window 'reuse b buffer)
            (set-window-buffer b buffer)
            (let ((record (window-parameter b 'quit-restore)))
              (should (dwindle--navigation-record-p record b))
              (should (dwindle--owned-window-p b))
              (dwindle-rotate)
              (let ((new (selected-window)))
                (should-not (window-live-p b))
                (should (eq (nth 2 record) b))
                (should (eq (nth 2 (window-parameter new 'quit-restore)) new))
                (should (dwindle--owned-window-p new))
                (should (eq (window-buffer new) buffer)))))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-temporary-buffer-hook-claim-aborts-before-clearing ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (before (dwindle-test--snapshot))
           fired)
      (let ((window-scroll-functions
             (list (lambda (window _start)
                     (when (string-prefix-p " *dwindle-tree*"
                                            (buffer-name (window-buffer window)))
                       (setq fired t)
                       (set-window-parameter window 'popup t))))))
        (should-error (dwindle-rotate)))
      (should fired)
      (should (equal before (dwindle-test--snapshot)))
      (should (window-live-p a))
      (should (window-live-p b))
      (should-not (window-parameter a 'popup)))))

(ert-deftest dwindle-tree-split-hook-claim-aborts-before-restoring-view ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (before (dwindle-test--snapshot))
           fired)
      (let ((window-scroll-functions
             (list (lambda (window _start)
                     (when (and (not (eq window a))
                                (string-prefix-p " *dwindle-tree*"
                                                 (buffer-name (window-buffer window))))
                       (setq fired t)
                       (set-window-parameter window 'quit-restore
                                             (list 'window 'window window
                                                   (window-buffer window))))))))
        (should-error (dwindle-rotate)))
      (should fired)
      (should (equal before (dwindle-test--snapshot)))
      (should (window-live-p a))
      (should (window-live-p b)))))

(ert-deftest dwindle-tree-unmarked-buffer-takeover-is-not-overwritten ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (buffer (generate-new-buffer " *plain-application-buffer*"))
           (before (dwindle-test--snapshot))
           fired)
      (unwind-protect
          (progn
            (let ((window-scroll-functions
                   (list (lambda (window _start)
                           (when (string-prefix-p " *dwindle-tree*"
                                                  (buffer-name (window-buffer window)))
                             (setq fired t)
                             ;; No opt-out marker, special mode, or custom
                             ;; window parameter identifies this takeover.
                             (set-window-buffer window buffer))))))
              (should-error (dwindle-rotate)))
            (should fired)
            (should (equal before (dwindle-test--snapshot)))
            (should (window-live-p a))
            (should (window-live-p b)))
        (kill-buffer buffer)))))

(ert-deftest dwindle-tree-move-leaf-preserves-view-and-target-selection ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (buffers (dwindle-tree-test--label (list a b c))))
      (select-window c)
      (dwindle-select-node)
      (select-window a)
      (dwindle-move-node)
      (should (equal (list (nth 2 buffers) (nth 0 buffers) (nth 1 buffers))
                     (dwindle-tree-test--buffers)))
      (should (eq (window-buffer (selected-window)) (car buffers)))
      (should-not (dwindle--selected-node)))))

(ert-deftest dwindle-tree-move-subtree-preserves-leaf-order-and-foreign-pane ()
  (dwindle-test--with-layout
    (let* ((side (display-buffer-in-side-window
                  (get-buffer-create " *bsp-side*") '((side . bottom))))
           (side-edges (window-edges side))
           (a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (buffers (dwindle-tree-test--label (list a b c))))
      (select-window c)
      (dwindle-focus-parent)
      (dwindle-select-node)
      (select-window a)
      (dwindle-move-node)
      (should (equal (list (nth 1 buffers) (nth 2 buffers) (nth 0 buffers))
                     (dwindle-tree-test--buffers)))
      (should (equal (window-edges side) side-edges))
      (should (window-live-p side)))))

(ert-deftest dwindle-tree-move-refuses-overlap-stale-mark-and-foreign-barrier ()
  (dwindle-test--with-layout
    (let* ((a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below)))
      (select-window c)
      (dwindle-focus-parent)
      (dwindle-select-node)
      (dwindle-focus-window)
      (let ((before (dwindle-test--snapshot)))
        (should-error (dwindle-move-node) :type 'user-error)
        (should (equal before (dwindle-test--snapshot))))
      (delete-window b)
      (should-not (dwindle--selected-node))
      (dwindle-select-node)
      (let ((foreign (dwindle-tree-test--split c nil 'below)))
        (set-window-dedicated-p foreign t)
        (select-window a)
        (let ((before (dwindle-test--snapshot)))
          (should-error (dwindle-move-node) :type 'user-error)
          (should (equal before (dwindle-test--snapshot))))))))

(ert-deftest dwindle-tree-split-shift-changes-topology-preserving-leaf-order ()
  (dwindle-test--with-layout
    (let* ((window-combination-limit t)
           (a (selected-window))
           (b (dwindle-tree-test--split a nil 'right))
           (c (dwindle-tree-test--split b nil 'below))
           (buffers (dwindle-tree-test--label (list a b c))))
      (select-window b)
      (dwindle-split-shift-previous)
      (let ((windows (dwindle-test--windows)))
        (should (equal buffers (dwindle-tree-test--buffers)))
        (should (eq (window-parent (car windows))
                    (window-parent (cadr windows))))
        (should-not (eq (window-parent (car windows))
                        (window-parent (nth 2 windows)))))
      (dwindle-split-shift-next)
      (let ((windows (dwindle-test--windows)))
        (should (equal buffers (dwindle-tree-test--buffers)))
        (should (eq (window-parent (cadr windows))
                    (window-parent (nth 2 windows))))))))

(ert-deftest dwindle-tree-split-shift-at-outer-edges-is-noop ()
  (dwindle-test--with-layout
    (let ((a (selected-window))
          (b (dwindle-tree-test--split nil nil 'right)))
      (let ((before (dwindle-test--snapshot)))
        (select-window a)
        (dwindle-split-shift-previous)
        (dwindle-split-shift-next)
        (select-window b)
        (dwindle-split-shift-next)
        (dwindle-split-shift-previous)
        (should (equal before (dwindle-test--snapshot)))))))

(provide 'dwindle-tree-tests)
;;; dwindle-tree-tests.el ends here
