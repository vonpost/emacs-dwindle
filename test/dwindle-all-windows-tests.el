;;; dwindle-all-windows-tests.el --- Universal window management -*- lexical-binding: t; -*-

(require 'dwindle-tests)

(defmacro dwindle-all-test--with-layout (&rest body)
  "Run BODY with universal management and isolated display rules."
  (declare (indent 0) (debug t))
  `(let ((dwindle-test--policy 'all))
     (dwindle-test--with-layout
       (let ((dwindle-manage-windows 'all)
             (display-buffer-alist nil)
             (display-buffer-overriding-action nil)
             (display-buffer-base-action nil)
             (display-buffer-mark-dedicated nil)
             (display-buffer-reuse-frames nil)
             (pop-up-frames nil)
             (pop-up-windows t))
         (dwindle--refresh)
         ,@body))))

(defun dwindle-all-test--metadata ()
  "Record native ownership state without changing the window tree."
  (mapcar (lambda (window)
            (list window
                  (copy-tree (window-parameters window))
                  (and (window-live-p window) (window-dedicated-p window))))
          (dwindle-test--native-nodes (frame-root-window))))

(ert-deftest dwindle-all-observes-application-panes-without-changing-metadata ()
  (dwindle-all-test--with-layout
    (let* ((source (selected-window))
           (pane (let ((dwindle-manage-windows 'ordinary))
                   (display-buffer-in-side-window
                    (get-buffer-create " *dwindle-side-observer*")
                    '((side . right) (window-width . 40))))))
      (unwind-protect
          (progn
            (set-window-dedicated-p pane t)
            (set-window-parameter pane 'popup t)
            (set-window-parameter pane 'no-other-window t)
            (set-window-parameter pane 'no-delete-other-windows t)
            (set-window-parameter pane 'split-window #'ignore)
            (let ((metadata (dwindle-all-test--metadata))
                  (layout (dwindle-test--snapshot)))
              (dwindle--refresh)
              (should (dwindle--managed-window-p pane))
              (should (dwindle--owned-window-p pane))
              (should (dwindle--managed-window-p source))
              (should (equal (dwindle-all-test--metadata) metadata))
              (should (equal (dwindle-test--snapshot) layout))))
        (set-window-dedicated-p pane nil)
        (kill-buffer " *dwindle-side-observer*")))))

(ert-deftest dwindle-all-rotates-dedicated-popup-handler-and-atomic-panes ()
  (dolist (kind '(dedicated popup handler atomic))
    (dwindle-all-test--with-layout
      (let* ((source (selected-window))
             (buffer (generate-new-buffer " *dwindle-application-pane*"))
             (pane (split-window source nil 'right))
             (parent (window-parent pane))
             (handler-called nil))
        (unwind-protect
            (progn
              (set-window-buffer pane buffer)
              (with-current-buffer buffer
                (dotimes (line 200) (insert (format "Output line %d\n" line))))
              (set-window-start pane 31)
              (set-window-point pane 65)
              (set-window-hscroll pane 2)
              (set-window-margins pane 2 3)
              (set-window-parameter pane 'dwindle-test-application-state 'keep)
              (pcase kind
                ('dedicated (set-window-dedicated-p pane t))
                ('popup
                 (set-window-parameter pane 'popup '(:side right))
                 (set-window-parameter pane 'no-other-window t)
                 (set-window-parameter pane 'no-delete-other-windows t))
                ('handler
                 (dolist (parameter '(split-window delete-window delete-other-windows))
                   (set-window-parameter
                    parent parameter
                    (lambda (&rest _)
                      (setq handler-called t)
                      (error "Application handler unexpectedly called")))))
                ('atomic (window-make-atom parent)))
              (should (dwindle--managed-window-p pane))
              (select-window pane)
              (let ((start (window-start pane))
                    (point (window-point pane))
                    (scroll (window-hscroll pane)))
                (dwindle-rotate)
                (setq pane (get-buffer-window buffer))
                (should (window-live-p pane))
                (should (= (window-start pane) start))
                (should (= (window-point pane) point))
                (should (= (window-hscroll pane) scroll))
                (should (equal (window-margins pane) '(2 . 3)))
                (should (eq (window-parameter pane 'dwindle-test-application-state)
                            'keep)))
              (should-not handler-called)
              (should-not (window-dedicated-p pane))
              (should-not (window-atom-root pane))
              (should-not (window-parameter pane 'popup))
              (should (dwindle--owned-window-p pane))
              (select-window pane)
              (let ((new (dwindle-split)))
                (should (window-live-p new))
                (should (= (length (window-list)) 3))
                (dwindle-delete-window)
                (should-not (window-live-p new)))
              (select-window pane)
              (dwindle-delete-window)
              (should (= (length (window-list)) 1))
              (should (buffer-live-p buffer)))
          (kill-buffer buffer))))))

(ert-deftest dwindle-all-keeps-explicit-ignore-and-minibuffer-excluded ()
  (dwindle-all-test--with-layout
    (let* ((source (selected-window))
           (ignored (split-window source nil 'right)))
      (set-window-parameter ignored 'dwindle-ignore t)
      (dwindle--refresh)
      (should-not (dwindle--managed-window-p ignored))
      (should-not (dwindle--owned-window-p ignored))
      (should-not (dwindle--managed-window-p (minibuffer-window)))
      (select-window ignored)
      (let ((before (dwindle-test--snapshot)))
        (should-error (dwindle-split) :type 'user-error)
        (should-error (dwindle-rotate) :type 'user-error)
        (should-error (dwindle-delete-window) :type 'user-error)
        (should (equal before (dwindle-test--snapshot)))
        (should (window-parameter ignored 'dwindle-ignore))))))

(ert-deftest dwindle-all-native-side-window-supports-every-window-command ()
  (dwindle-all-test--with-layout
    (let* ((buffer (generate-new-buffer " *dwindle-native-side*"))
           (pane (let ((dwindle-manage-windows 'ordinary))
                   (display-buffer-in-side-window
                    buffer '((side . right) (window-width . 50))))))
      (unwind-protect
          (progn
            (should (window-parameter pane 'window-side))
            (set-window-dedicated-p pane 'side)
            (select-window pane)
            (dwindle-rotate)
            (setq pane (get-buffer-window buffer))
            (should (window-live-p pane))
            (should-not (window-parameter pane 'window-side))
            (should-not (window-dedicated-p pane))
            (select-window pane)
            (should (numberp (dwindle--resize 'up nil)))
            (let ((new (dwindle-split)))
              (should (window-live-p new))
              (dwindle-delete-window)
              (should-not (window-live-p new)))
            (select-window pane)
            (dwindle-delete-window)
            (should-not (get-buffer-window buffer))
            (should (= (length (window-list)) 1))
            (should (buffer-live-p buffer)))
        (kill-buffer buffer)))))

(ert-deftest dwindle-all-failed-split-preserves-application-restrictions ()
  (dwindle-all-test--with-layout
    (let* ((buffer (generate-new-buffer " *dwindle-side-failed-split*"))
           (pane (let ((dwindle-manage-windows 'ordinary))
                   (display-buffer-in-side-window
                    buffer '((side . right) (window-width . 50))))))
      (unwind-protect
          (progn
            (set-window-dedicated-p pane 'side)
            (select-window pane)
            (let ((metadata (dwindle-all-test--metadata))
                  (layout (dwindle-test--snapshot))
                  (window-min-height 1000))
              (should-error (dwindle-split))
              (should (equal (dwindle-test--snapshot) layout))
              (should (equal (dwindle-all-test--metadata) metadata))))
        (set-window-dedicated-p pane nil)
        (kill-buffer buffer)))))

(ert-deftest dwindle-all-ignored-leaf-protects-its-atomic-group ()
  (dwindle-all-test--with-layout
    (let* ((source (selected-window))
           (other (split-window source nil 'right))
           (ignored (split-window other nil 'below))
           (group (window-parent ignored)))
      (window-make-atom group)
      (set-window-parameter ignored 'dwindle-ignore t)
      (let ((other-edges (window-edges other))
            (ignored-edges (window-edges ignored)))
        (select-window source)
        (should (window-live-p (dwindle-split)))
        (should (eq (window-atom-root ignored) group))
        (should (eq (window-atom-root other) group))
        (should (window-parameter ignored 'dwindle-ignore))
        (should (equal (window-edges other) other-edges))
        (should (equal (window-edges ignored) ignored-edges))))))

(ert-deftest dwindle-all-failed-rotation-preserves-application-restrictions ()
  (dwindle-all-test--with-layout
    (let* ((buffer (generate-new-buffer " *dwindle-side-failed-rotate*"))
           (pane (let ((dwindle-manage-windows 'ordinary))
                   (display-buffer-in-side-window
                    buffer '((side . right) (window-width . 50))))))
      (unwind-protect
          (progn
            (set-window-dedicated-p pane 'side)
            (select-window pane)
            (let ((metadata (dwindle-all-test--metadata))
                  (layout (dwindle-test--snapshot))
                  (window-min-height 1000))
              (should-error (dwindle-rotate))
              (should (equal (dwindle-test--snapshot) layout))
              (should (equal (dwindle-all-test--metadata) metadata))))
        (set-window-dedicated-p pane nil)
        (kill-buffer buffer)))))

(defconst dwindle-all-test--notebook-directory
  (expand-file-name "../../emacs-jupyter-notebook"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Optional sibling package for real notebook display regression tests.")

(defun dwindle-all-test--code-cells-directory ()
  "Find optional code-cells in the configured, Doom, or Nix installation."
  (or (cl-find-if
       (lambda (directory)
         (and directory
              (file-readable-p (expand-file-name "code-cells.el" directory))))
       (list (getenv "CODE_CELLS_DIR")
             (expand-file-name "~/.config/emacs/.local/straight/repos/code-cells.el")
             (expand-file-name "~/.emacs.d/.local/straight/repos/code-cells.el")))
      (when (file-directory-p "/nix/store")
        (cl-loop
         for package in (directory-files "/nix/store" t "-emacs-code-cells-" t)
         for library = (and (file-directory-p package)
                            (car (directory-files-recursively
                                  package "/code-cells\\.el\\'")))
         when library return (file-name-directory library)))))

(defun dwindle-all-test--require-notebook ()
  "Load the actual sibling notebook panel, or skip when it is unavailable."
  (unless (featurep 'emacs-jupyter-notebook-result)
    (let* ((configured (unless (locate-library "code-cells")
                         (dwindle-all-test--code-cells-directory)))
           (load-path (append (list dwindle-all-test--notebook-directory)
                              (when configured (list configured))
                              load-path)))
      (unless (and (locate-library "emacs-jupyter-notebook-result")
                   (locate-library "code-cells"))
        (ert-skip "Optional sibling notebook package or code-cells is unavailable"))
      (require 'emacs-jupyter-notebook-result))))

(defmacro dwindle-all-test--with-notebook (&rest body)
  "Run BODY with a real SOURCE buffer and its notebook PANEL."
  (declare (indent 0) (debug t))
  `(progn
     (dwindle-all-test--require-notebook)
     (dwindle-all-test--with-layout
       (let* ((source (generate-new-buffer " *dwindle-notebook-source*"))
              (emacs-jupyter-notebook-panel-side 'right)
              (emacs-jupyter-notebook-panel-width 30)
              (panel (ejn-panel-ensure source)))
         (unwind-protect
             (progn
               (with-current-buffer source
                 (insert "# %% Result\nprint(42)\n")
                 (set-buffer-modified-p nil))
               (set-window-buffer nil source)
               ,@body
               (with-current-buffer source
                 (should (equal (buffer-string) "# %% Result\nprint(42)\n"))
                 (should-not (buffer-modified-p))))
           (kill-buffer source)
           (when (buffer-live-p panel) (kill-buffer panel)))))))

(ert-deftest dwindle-all-notebook-new-output-follows-focused-bsp-and-reuses ()
  (dwindle-all-test--with-notebook
    (let* ((source-window (selected-window))
           (other (dwindle-split))
           (other-edges (window-edges other)))
      (select-window source-window)
      (let* ((output (emacs-jupyter-notebook-panel--display panel))
             (input-edges (window-edges source-window))
             (output-edges (window-edges output)))
        ;; EJN requests right; the focused leaf's next BSP split is below.
        (should (= (nth 3 input-edges) (nth 1 output-edges)))
        (should (= (nth 0 input-edges) (nth 0 output-edges)))
        (should (equal (window-edges other) other-edges))
        (should (eq (selected-window) source-window))
        (should (dwindle--owned-window-p output))
        (should-not (window-parameter output 'window-side))
        (should-not (window-dedicated-p output))
        (window-resize output 2)
        (let ((before (dwindle-test--snapshot)))
          (should (eq output (emacs-jupyter-notebook-panel--display panel)))
          (should (equal before (dwindle-test--snapshot))))))))

(ert-deftest dwindle-all-notebook-existing-side-output-becomes-fully-usable ()
  (dwindle-all-test--with-notebook
    (let* ((source-window (selected-window))
           (output (let ((dwindle-manage-windows 'ordinary))
                     (display-buffer-in-side-window
                      panel '((side . right) (window-width . 50))))))
      (set-window-dedicated-p output 'side)
      (should (window-parameter output 'window-side))
      ;; Reloading EJN reuses its old side window, so conversion must also
      ;; cover panes that were created before Dwindle's display integration.
      (should (eq output (emacs-jupyter-notebook-panel--display panel)))
      (should (eq (selected-window) source-window))
      (select-window output)
      (dwindle-rotate)
      (setq output (get-buffer-window panel))
      (should (window-live-p output))
      (should-not (window-parameter output 'window-side))
      (should-not (window-dedicated-p output))
      (select-window output)
      (should (numberp (dwindle--resize 'up nil)))
      (let ((new (dwindle-split)))
        (should (window-live-p new))
        (dwindle-delete-window)
        (should-not (window-live-p new)))
      (select-window output)
      (dwindle-delete-window)
      (should-not (get-buffer-window panel))
      (should (get-buffer-window source))
      (should (buffer-live-p panel)))))

(provide 'dwindle-all-windows-tests)
;;; dwindle-all-windows-tests.el ends here
