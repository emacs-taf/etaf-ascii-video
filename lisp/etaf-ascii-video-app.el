;;; etaf-ascii-video-app.el --- Buffers, keys and commands for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application face of the player: the mountable View over the retained
;; grid and status Hosts, the buffer keymap, window fitting and the public
;; commands listed in the root entry.  The View reads player refs, so a canvas
;; resize is an ordinary ETAF publication while frames keep flowing through
;; the retained content path.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ascii-video-grid)
(require 'etaf-ascii-video-player)
(require 'etaf-ascii-video-source)

(defconst etaf-ascii-video--buffer-name "*ASCII Video*"
  "Name of the single application buffer.")

(defvar etaf-ascii-video-grid-presets
  '((?1 . 64) (?2 . 96) (?3 . 128) (?4 . 176))
  "Grid width presets reached by the `1' to `4' keys.
Keys are characters, values are canvas widths in character cells; the row
count follows the video aspect.")

(defvar etaf-ascii-video-render-mode 'mono
  "Rendering mode for new players: `mono', `color' or `graphics'.
`mono' maps each pixel to one density-ramp character.  `color' renders two
full color pixels per character cell with `▀' (top pixel as foreground,
bottom as background).  `graphics' publishes one scaled JPEG per frame as an
image display and needs a graphical frame.")

(defvar etaf-ascii-video-color-columns 32
  "Column limit used when a true-color player fits a new window.
Nil fits the window like the monochrome mode.  Color content carries one
`face' property per cell and EBox publishes one property operation per run,
so larger grids cost proportionally more per frame; 32 columns keeps color
playback responsive (about 14 frames per second in a graphical session) and
can be raised for sharper, slower pictures.")

(defvar etaf-ascii-video-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'etaf-ascii-video-toggle-playback)
    (define-key map (kbd "n") #'etaf-ascii-video-step)
    (define-key map (kbd "f") #'etaf-ascii-video--forward-command)
    (define-key map (kbd "b") #'etaf-ascii-video--backward-command)
    (define-key map (kbd "+") #'etaf-ascii-video--speed-up-command)
    (define-key map (kbd "-") #'etaf-ascii-video--speed-down-command)
    (define-key map (kbd "1") #'etaf-ascii-video--preset-command)
    (define-key map (kbd "2") #'etaf-ascii-video--preset-command)
    (define-key map (kbd "3") #'etaf-ascii-video--preset-command)
    (define-key map (kbd "4") #'etaf-ascii-video--preset-command)
    (define-key map (kbd "F") #'etaf-ascii-video-fit)
    (define-key map (kbd "c") #'etaf-ascii-video--toggle-color-command)
    (define-key map (kbd "i") #'etaf-ascii-video--toggle-graphics-command)
    (define-key map (kbd "o") #'etaf-ascii-video-open-file)
    (define-key map (kbd "d") #'etaf-ascii-video-demo)
    (define-key map (kbd "?") #'etaf-ascii-video--help-command)
    (define-key map (kbd "q") #'etaf-ascii-video-close)
    map)
  "Keymap of a buffer opened by `etaf-ascii-video-open'.")

(defvar etaf-ascii-video--command-maps
  (list
   (cons 'etaf-ascii-video--player
         (let ((map (make-sparse-keymap)))
           ;; The renderer's minor-mode map owns these keys and wins over a
           ;; major-mode map; an `emulation-mode-map-alists' entry wins over
           ;; every minor mode, so the application replaces them here.
           (set-keymap-parent map etaf-ascii-video-mode-map)
           (define-key map (kbd "SPC") #'etaf-ascii-video-toggle-playback)
           (define-key map (kbd "n") #'etaf-ascii-video-step)
           (define-key map (kbd "f") #'etaf-ascii-video--forward-command)
           (define-key map (kbd "b") #'etaf-ascii-video--backward-command)
           (define-key map (kbd "+") #'etaf-ascii-video--speed-up-command)
           (define-key map (kbd "-") #'etaf-ascii-video--speed-down-command)
           (define-key map (kbd "1") #'etaf-ascii-video--preset-command)
           (define-key map (kbd "2") #'etaf-ascii-video--preset-command)
           (define-key map (kbd "3") #'etaf-ascii-video--preset-command)
           (define-key map (kbd "4") #'etaf-ascii-video--preset-command)
           (define-key map (kbd "F") #'etaf-ascii-video-fit)
           (define-key map (kbd "c") #'etaf-ascii-video--toggle-color-command)
           (define-key map (kbd "i") #'etaf-ascii-video--toggle-graphics-command)
           (define-key map (kbd "o") #'etaf-ascii-video-open-file)
           (define-key map (kbd "d") #'etaf-ascii-video-demo)
           (define-key map (kbd "?") #'etaf-ascii-video--help-command)
           (define-key map (kbd "q") #'etaf-ascii-video-close)
           map)))
  "Application bindings that must beat the renderer's own minor-mode map.
The alist's key is `etaf-ascii-video--player', the buffer-local variable
every application buffer owns, so the entry is active exactly there.")

(defvar-local etaf-ascii-video--player nil
  "Player owned by the current application buffer.")

(defvar etaf-ascii-video--size-hook-installed nil
  "Whether the window size hook was installed.")

(defun etaf-ascii-video--current ()
  "Return the current buffer's player, or signal `user-error'."
  (or etaf-ascii-video--player
      (user-error "Not an etaf-ascii-video buffer")))

(defun etaf-ascii-video--aspect (spec)
  "Return SPEC's video aspect ratio as a float."
  (let ((width (plist-get spec :width))
        (height (plist-get spec :height)))
    (if (and (numberp width) (numberp height) (> width 0) (> height 0))
        (/ (float width) height)
      (/ 16.0 9))))

(defun etaf-ascii-video--window-grid (window aspect &optional limit-columns)
  "Return the (COLUMNS . ROWS) fitting WINDOW for an ASPECT frame.
One row is reserved for the status line.  LIMIT-COLUMNS, when non-nil, caps
the canvas width."
  (let* ((frame (window-frame window))
         (cell-aspect (/ (float (frame-char-height frame))
                         (max 1 (frame-char-width frame))))
         (max-columns (max 8 (window-body-width window)))
         (max-columns (if limit-columns (min max-columns limit-columns) max-columns))
         (max-rows (max 3 (1- (window-body-height window)))))
    (etaf-ascii-video--fit-grid aspect max-columns max-rows cell-aspect)))

(defun etaf-ascii-video--view (player)
  "Return the mountable View of PLAYER."
  (etaf-view
   (flex :flex-direction 'column :width '(vw 100)
         :background-color "#0B0C0E" :color "#C9CDD3"
     (box :width (etaf-value (etaf-ascii-video--player-columns-ref player))
          :height (etaf-value (etaf-ascii-video--player-rows-ref player))
          :wrap-mode 'none :overflow 'hidden :background-color "#050607"
       (text :id "grid" :ref etaf-ascii-video--grid-ref
             (expr (etaf-value (etaf-ascii-video--player-grid-text-ref player)))))
     (box :height '(lh 1) :width '(vw 100) :wrap-mode 'none :overflow 'hidden
       (text :id "hud" :ref etaf-ascii-video--hud-ref
             (expr (etaf-value (etaf-ascii-video--player-hud-text-ref player))))))))

(defun etaf-ascii-video--window-size-changed (frame)
  "Refit every ASCII video shown on FRAME after a window resize."
  (dolist (window (window-list frame))
    (with-current-buffer (window-buffer window)
      (when etaf-ascii-video--player
        (etaf-ascii-video--refit etaf-ascii-video--player window)))))

(defun etaf-ascii-video--refit (player window)
  "Fit PLAYER to WINDOW and republish its canvas size."
  (when-let* ((runtime (etaf-runtime-for-buffer (etaf-ascii-video--player-buffer player))))
    (etaf-runtime-refit runtime (window-body-width window t) (window-body-height window)))
  (let* ((spec (etaf-ascii-video--player-spec player))
         (grid (etaf-ascii-video--window-grid
                window (etaf-ascii-video--aspect spec)
                (and (eq (plist-get spec :mode) 'color)
                     etaf-ascii-video-color-columns))))
    (unless (equal grid (cons (etaf-ascii-video--player-columns player)
                              (etaf-ascii-video--player-rows player)))
      (etaf-ascii-video--player-set-grid player (car grid) (cdr grid)))))

(defun etaf-ascii-video--install-size-hook ()
  "Install the application's window size hook once."
  (unless etaf-ascii-video--size-hook-installed
    (add-hook 'window-size-change-functions #'etaf-ascii-video--window-size-changed)
    (setq etaf-ascii-video--size-hook-installed t)))

;;;###autoload
(defun etaf-ascii-video-open (&optional source)
  "Open the ASCII video player and return its buffer.
SOURCE is nil for the built-in demo, a file name, or a plist accepted by
`etaf-ascii-video--normalize-source'.  An existing player is closed first.
The canvas is fitted to the selected window unless SOURCE carries `:columns'
and `:rows'."
  (interactive (list (let ((name (read-file-name "Video file (empty for demo): " nil nil nil)))
                       (if (string-empty-p name) nil name))))
  (let* ((spec (etaf-ascii-video--normalize-source source))
         (spec (plist-put spec :mode
                          (or (plist-get spec :mode) etaf-ascii-video-render-mode))))
    (when (get-buffer etaf-ascii-video--buffer-name)
      (with-current-buffer (get-buffer etaf-ascii-video--buffer-name)
        (when etaf-ascii-video--player
          (etaf-ascii-video-close))))
    (let* ((buffer (get-buffer-create etaf-ascii-video--buffer-name))
           (window (selected-window))
           (grid (if (and (integerp (plist-get spec :columns))
                          (integerp (plist-get spec :rows)))
                     (cons (plist-get spec :columns) (plist-get spec :rows))
                   (etaf-ascii-video--window-grid
                    window (etaf-ascii-video--aspect spec)
                    (and (eq (plist-get spec :mode) 'color)
                         etaf-ascii-video-color-columns))))
           (player (etaf-ascii-video--player-create buffer spec (car grid) (cdr grid))))
      (condition-case problem
          (progn
            (with-current-buffer buffer
              (setq-local etaf-ascii-video--player player)
              (setq-local truncate-lines t)
              (setq-local auto-hscroll-mode nil)
              (setq-local emulation-mode-map-alists
                          (cons 'etaf-ascii-video--command-maps
                                (remq 'etaf-ascii-video--command-maps
                                      emulation-mode-map-alists)))
              (setq-local buffer-display-table
                          (let ((table (copy-sequence (or standard-display-table
                                                          (make-display-table)))))
                            (set-display-table-slot table 'truncation ?\s)
                            table))
              (use-local-map etaf-ascii-video-mode-map)
              (etaf-mount buffer (etaf-ascii-video--view player)
                          (list :viewport-width (window-body-width window t)
                                :viewport-height (window-body-height window))))
            (let ((display-buffer-overriding-action '((display-buffer-same-window))))
              (pop-to-buffer buffer))
            (when-let* ((shown (get-buffer-window buffer t)))
              (set-window-hscroll shown 0))
            (etaf-ascii-video--install-size-hook)
            (etaf-ascii-video--player-play player)
            buffer)
        ((error)
         (etaf-ascii-video--teardown buffer player)
         (signal (car problem) (cdr problem)))))))

;;;###autoload
(defun etaf-ascii-video-open-file (file)
  "Play the local video FILE in the ASCII video player."
  (interactive "fVideo file: ")
  (etaf-ascii-video-open (list :file file)))

;;;###autoload
(defun etaf-ascii-video-demo ()
  "Play the built-in generated test pattern."
  (interactive)
  (etaf-ascii-video-open '(:demo)))

(defun etaf-ascii-video--teardown (buffer player)
  "Release PLAYER and close BUFFER without signaling."
  (when player
    (ignore-errors (etaf-ascii-video--player-close player)))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local etaf-ascii-video--player nil)
      (ignore-errors
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime)))
      (kill-buffer buffer))))

(defun etaf-ascii-video-close ()
  "Close the ASCII video player in the current buffer."
  (interactive)
  (etaf-ascii-video--teardown (current-buffer) etaf-ascii-video--player)
  t)

(defun etaf-ascii-video-toggle-playback ()
  "Toggle the current player between playing and paused."
  (interactive)
  (etaf-ascii-video--player-toggle (etaf-ascii-video--current))
  t)

(defun etaf-ascii-video-step ()
  "Pause the current player and present exactly one more frame."
  (interactive)
  (etaf-ascii-video--player-step (etaf-ascii-video--current))
  t)

(defun etaf-ascii-video-seek (seconds)
  "Move the current player to SECONDS and restart decoding there."
  (interactive "nSeconds: ")
  (etaf-ascii-video--player-seek (etaf-ascii-video--current) seconds)
  t)

(defun etaf-ascii-video-set-speed (speed)
  "Set the current player's rate to SPEED, a positive number."
  (interactive "nPlayback speed: ")
  (etaf-ascii-video--player-set-speed (etaf-ascii-video--current) speed)
  t)

(defun etaf-ascii-video-set-color (color)
  "Turn true-color half-block rendering on (non-nil) or off (nil).
Color mode renders two full color pixels per character cell with `▀' and
doubles the vertical resolution at the cost of one `face' per cell."
  (interactive "P")
  (etaf-ascii-video--player-set-mode (etaf-ascii-video--current)
                                     (if color 'color 'mono))
  t)

(defun etaf-ascii-video-set-render-mode (mode)
  "Switch the current player to MODE: `mono', `color' or `graphics'.
`mono' uses the density ramp, `color' renders two full color pixels per cell
with one `face' per cell, and `graphics' publishes one scaled JPEG per frame
as an image display (graphical frames only)."
  (interactive
   (list (intern (completing-read "Render mode: " '("mono" "color" "graphics")
                                  nil t nil nil "mono"))))
  (etaf-ascii-video--player-set-mode (etaf-ascii-video--current) mode)
  t)

(defun etaf-ascii-video-set-grid (columns rows)
  "Resize the current player's canvas to COLUMNS by ROWS cells."
  (interactive "nColumns: \nnRows: ")
  (etaf-ascii-video--player-set-grid (etaf-ascii-video--current) columns rows)
  t)

(defun etaf-ascii-video-fit ()
  "Fit the current player's canvas to the window showing it."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (window (get-buffer-window (etaf-ascii-video--player-buffer player) t)))
    (if window
        (progn
          (etaf-ascii-video--refit player window)
          t)
      (user-error "The ASCII video buffer is not shown in a window"))))

(defun etaf-ascii-video-state ()
  "Return the current player's state as a detached plist.
Keys are `:source', `:playing', `:position', `:duration', `:speed',
`:columns', `:rows', `:mode', `:fps' (display rate), `:presented-fps',
`:source-fps', `:received', `:presented', `:dropped', `:frame-ms' and
`:ended'."
  (let* ((player (etaf-ascii-video--current))
         (spec (etaf-ascii-video--player-spec player)))
    (list :source (pcase (plist-get spec :kind)
                    ('file (plist-get spec :file))
                    (_ 'demo))
          :playing (and (etaf-ascii-video--player-playing player) t)
          :position (etaf-ascii-video--player-position player)
          :duration (plist-get spec :duration)
          :speed (etaf-ascii-video--player-speed player)
          :columns (etaf-ascii-video--player-columns player)
          :rows (etaf-ascii-video--player-rows player)
          :mode (or (plist-get spec :mode) 'mono)
          :fps etaf-ascii-video-display-fps
          :presented-fps (etaf-ascii-video--player-presented-fps player)
          :source-fps (plist-get spec :fps)
          :received (etaf-ascii-video--player-received player)
          :presented (etaf-ascii-video--player-presented player)
          :dropped (etaf-ascii-video--player-dropped player)
          :frame-ms (etaf-ascii-video--player-frame-ms player)
          :ended (and (etaf-ascii-video--player-ended player) t))))

(defun etaf-ascii-video--forward-command ()
  "Seek five seconds forward."
  (interactive)
  (etaf-ascii-video-seek (+ (etaf-ascii-video--player-position (etaf-ascii-video--current)) 5)))

(defun etaf-ascii-video--backward-command ()
  "Seek five seconds backward."
  (interactive)
  (etaf-ascii-video-seek (- (etaf-ascii-video--player-position (etaf-ascii-video--current)) 5)))

(defun etaf-ascii-video--speed-up-command ()
  "Raise the playback rate to the next supported value."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (speed (etaf-ascii-video--player-speed player))
         (next (or (cl-find-if (lambda (candidate) (> candidate speed))
                               etaf-ascii-video--speeds)
                   (car (last etaf-ascii-video--speeds)))))
    (etaf-ascii-video-set-speed next)))

(defun etaf-ascii-video--speed-down-command ()
  "Lower the playback rate to the next supported value."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (speed (etaf-ascii-video--player-speed player))
         (next (or (car (last (cl-remove-if (lambda (candidate) (>= candidate speed))
                                            etaf-ascii-video--speeds)))
                   (car etaf-ascii-video--speeds))))
    (etaf-ascii-video-set-speed next)))

(defun etaf-ascii-video--preset-command ()
  "Apply the grid preset named by the key that invoked this command."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (key last-command-event)
         (columns (cdr (assq key etaf-ascii-video-grid-presets))))
    (unless columns
      (user-error "No ASCII video grid preset for %S" key))
    (etaf-ascii-video-set-grid
     columns
     (etaf-ascii-video--rows-for-columns
      (etaf-ascii-video--aspect (etaf-ascii-video--player-spec player)) columns))))

(defun etaf-ascii-video--toggle-color-command ()
  "Toggle true-color half-block rendering."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (spec (etaf-ascii-video--player-spec player)))
    (etaf-ascii-video--player-set-mode
     player (if (eq (plist-get spec :mode) 'color) 'mono 'color))))

(defun etaf-ascii-video--toggle-graphics-command ()
  "Toggle graphics (image) rendering."
  (interactive)
  (let* ((player (etaf-ascii-video--current))
         (spec (etaf-ascii-video--player-spec player)))
    (etaf-ascii-video--player-set-mode
     player (if (eq (plist-get spec :mode) 'graphics) 'mono 'graphics))))

(defun etaf-ascii-video--help-command ()
  "Show the ASCII video key bindings."
  (interactive)
  (message (concat "ASCII video: SPC play/pause, n step, f/b +-5s, +/- speed, "
                   "1-4 grid, c color, i image, F fit, o open, d demo, q close")))

(provide 'etaf-ascii-video-app)
;;; etaf-ascii-video-app.el ends here
