;;; etaf-ascii-video-app.el --- Buffers, keys and commands for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The application face of the player: the mountable View over the native
;; `etaf-video' Component and the status Host, the buffer keymap, window
;; fitting and the public commands listed in the root entry.  Playback,
;; decoding and frame mapping belong to ETAF; this module keeps the canvas
;; size, the render mode, the status line and the user's keys.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ascii-video-grid)

(defconst etaf-ascii-video--buffer-name "*ASCII Video*"
  "Name of the single application buffer.")

(defconst etaf-ascii-video--hud-ref 'etaf-ascii-video-hud
  "Retained Host reference of the status line.")

(defconst etaf-ascii-video--hud-interval 0.25
  "Seconds between status line refreshes.")

(defconst etaf-ascii-video--speeds '(0.5 1 2 4 8)
  "Playback rates offered by the speed commands.")

(defvar etaf-ascii-video-grid-presets
  '((?1 . 64) (?2 . 96) (?3 . 128) (?4 . 176))
  "Grid width presets reached by the `1' to `4' keys.
Keys are characters, values are canvas widths in character cells; the row
count follows the video aspect.")

(defvar etaf-ascii-video-render-mode 'mono
  "Rendering mode for new players: `mono' or `color'.
`mono' maps each pixel to one density-ramp character.  `color' renders two
full color pixels per character cell with `▀' (top pixel as foreground,
bottom as background).  A `:mode' hint in the source plist overrides it.")

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
    (define-key map (kbd "o") #'etaf-ascii-video-open-file)
    (define-key map (kbd "u") #'etaf-ascii-video-open-url)
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
           (define-key map (kbd "o") #'etaf-ascii-video-open-file)
           (define-key map (kbd "u") #'etaf-ascii-video-open-url)
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

(cl-defstruct (etaf-ascii-video--player (:constructor etaf-ascii-video--player--make))
  "Application state for one ASCII video buffer.
Playback lives in the native `etaf-video' session addressed by HANDLE; this
record owns the canvas size, the render mode, the playback rate, the status
line and its refresh timer."
  buffer spec mode handle
  columns rows speed window-rows
  columns-ref rows-ref mode-ref speed-ref
  hud-text hud-text-ref hud-timer
  sample sample-fps)

(defun etaf-ascii-video--current ()
  "Return the current buffer's player, or signal `user-error'."
  (or etaf-ascii-video--player
      (user-error "Not an etaf-ascii-video buffer")))

(defun etaf-ascii-video--clock (seconds)
  "Format SECONDS as a playback clock, or `--:--' when it is nil."
  (if (numberp seconds)
      (let* ((whole (max 0 (floor seconds)))
             (hours (/ whole 3600))
             (minutes (/ (% whole 3600) 60))
             (rest (% whole 60)))
        (if (> hours 0)
            (format "%d:%02d:%02d" hours minutes rest)
          (format "%02d:%02d" minutes rest)))
    "--:--"))

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

(defun etaf-ascii-video--state (player)
  "Return PLAYER's native video state as a detached plist."
  (etaf-video-state (etaf-ascii-video--player-handle player)))

(defun etaf-ascii-video--sampled-fps (player state)
  "Update PLAYER's presented frame rate sample from STATE and return it."
  (let* ((now (float-time))
         (presented (plist-get state :presented))
         (sample (etaf-ascii-video--player-sample player))
         (fps (or (etaf-ascii-video--player-sample-fps player) 0.0)))
    (when (or (null sample) (>= (- now (car sample)) 0.5))
      (when sample
        (setq fps (/ (float (- presented (cdr sample)))
                     (max 0.001 (- now (car sample))))))
      (setf (etaf-ascii-video--player-sample player) (cons now presented)
            (etaf-ascii-video--player-sample-fps player) fps))
    fps))

(defun etaf-ascii-video--hud (player state)
  "Return PLAYER's one-line status text for STATE."
  (format "%s %s/%s  %2.0ffps  dropped %d  %dx%d  %s  %sx"
          (cond ((plist-get state :ended) "ended")
                ((plist-get state :playing) "playing")
                (t "paused"))
          (etaf-ascii-video--clock (plist-get state :position))
          (etaf-ascii-video--clock (plist-get state :duration))
          (etaf-ascii-video--sampled-fps player state)
          (or (plist-get state :dropped) 0)
          (etaf-ascii-video--player-columns player)
          (etaf-ascii-video--player-rows player)
          (symbol-name (etaf-ascii-video--player-mode player))
          (format "%s" (etaf-ascii-video--player-speed player))))

(defun etaf-ascii-video--player-render (player)
  "Publish PLAYER's status line from the live video state."
  (let ((state (etaf-ascii-video--state player)))
    (setf (etaf-ascii-video--player-hud-text player)
          (etaf-ascii-video--hud player state))
    (when-let* ((runtime (etaf-runtime-for-buffer
                          (etaf-ascii-video--player-buffer player))))
      (etaf-runtime-update-host-content
       runtime etaf-ascii-video--hud-ref
       (etaf-ascii-video--player-hud-text player)))))

(defun etaf-ascii-video--player-tick (player)
  "Refresh PLAYER's status line while its buffer is alive."
  (when (buffer-live-p (etaf-ascii-video--player-buffer player))
    (condition-case problem
        (etaf-ascii-video--player-render player)
      ((error quit)
       (when-let* ((timer (etaf-ascii-video--player-hud-timer player)))
         (cancel-timer timer)
         (setf (etaf-ascii-video--player-hud-timer player) nil))
       (message "etaf-ascii-video: %s" (error-message-string problem))))))

(cl-defun etaf-ascii-video--player-create (buffer spec mode columns rows speed)
  "Create a player for BUFFER, SPEC, MODE, COLUMNS, ROWS and SPEED.
The retained refs returned here are closed over by the application View."
  (let ((player (etaf-ascii-video--player--make
                 :buffer buffer :spec spec :mode mode
                 :handle (make-symbol "etaf-ascii-video")
                 :columns columns :rows rows :speed speed
                 :hud-text "paused 00:00/--:--")))
    (setf (etaf-ascii-video--player-columns-ref player) (etaf-ref columns)
          (etaf-ascii-video--player-rows-ref player) (etaf-ref rows)
          (etaf-ascii-video--player-mode-ref player) (etaf-ref mode)
          (etaf-ascii-video--player-speed-ref player) (etaf-ref speed)
          (etaf-ascii-video--player-hud-text-ref player)
          (etaf-ref (etaf-ascii-video--player-hud-text player)))
    player))

(defun etaf-ascii-video--view (player)
  "Return the mountable View of PLAYER."
  (etaf-view
   (flex :flex-direction 'column :width '(vw 100)
         :background-color "#0B0C0E" :color "#C9CDD3"
     (etaf-video :src (etaf-ascii-video--player-spec player)
                 :mode (if (eq (etaf-value (etaf-ascii-video--player-mode-ref player))
                              'color)
                           'color 'ascii)
                 :columns (etaf-value (etaf-ascii-video--player-columns-ref player))
                 :rows (etaf-value (etaf-ascii-video--player-rows-ref player))
                 :speed (etaf-value (etaf-ascii-video--player-speed-ref player))
                 :audio nil
                 :autoplay t
                 :handle (etaf-ascii-video--player-handle player))
     (box :height '(lh 1) :width '(vw 100) :wrap-mode 'none :overflow 'hidden
       (text :id "hud" :ref etaf-ascii-video--hud-ref
             (expr (etaf-value (etaf-ascii-video--player-hud-text-ref player))))))))

(defun etaf-ascii-video--window-size-changed (frame)
  "Refit every ASCII video shown on FRAME after a window resize.
Lines borrowed by the minibuffer keep the grid the player committed."
  (dolist (window (window-list frame))
    (with-current-buffer (window-buffer window)
      (when etaf-ascii-video--player
        (unless (etaf-transient-space-borrowed-p
                 window (etaf-ascii-video--player-window-rows
                         etaf-ascii-video--player))
          (etaf-ascii-video--refit etaf-ascii-video--player window))))))

(defun etaf-ascii-video--refit (player window)
  "Fit PLAYER's canvas grid to WINDOW; the mount follows the window itself."
  (setf (etaf-ascii-video--player-window-rows player) (window-body-height window))
  (let* ((spec (etaf-ascii-video--player-spec player))
         (grid (etaf-ascii-video--window-grid
                window (etaf-ascii-video--aspect spec)
                (and (eq (etaf-ascii-video--player-mode player) 'color)
                     etaf-ascii-video-color-columns))))
    (unless (equal grid (cons (etaf-ascii-video--player-columns player)
                              (etaf-ascii-video--player-rows player)))
      (etaf-ascii-video--player-set-grid player (car grid) (cdr grid)))))

(defun etaf-ascii-video--player-set-grid (player columns rows)
  "Resize PLAYER's canvas to COLUMNS by ROWS and restart the producer."
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (user-error "Canvas size must be positive integers: %S by %S" columns rows))
  (unless (and (= columns (etaf-ascii-video--player-columns player))
               (= rows (etaf-ascii-video--player-rows player)))
    (setf (etaf-ascii-video--player-columns player) columns
          (etaf-ascii-video--player-rows player) rows)
    (etaf-set-value (etaf-ascii-video--player-columns-ref player) columns)
    (etaf-set-value (etaf-ascii-video--player-rows-ref player) rows)))

(defun etaf-ascii-video--player-set-mode (player mode)
  "Switch PLAYER to MODE, one of `mono' or `color'."
  (unless (memq mode '(mono color))
    (user-error "Unknown etaf-ascii-video render mode: %S" mode))
  (unless (eq (etaf-ascii-video--player-mode player) mode)
    (setf (etaf-ascii-video--player-mode player) mode)
    (etaf-set-value (etaf-ascii-video--player-mode-ref player) mode)))

(defun etaf-ascii-video--player-set-speed (player speed)
  "Set PLAYER's rate to SPEED, a positive number."
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (setf (etaf-ascii-video--player-speed player) speed)
  (etaf-set-value (etaf-ascii-video--player-speed-ref player) speed))

(defun etaf-ascii-video--player-close (player)
  "Release PLAYER's status timer and buffer state."
  (when-let* ((timer (etaf-ascii-video--player-hud-timer player)))
    (cancel-timer timer)
    (setf (etaf-ascii-video--player-hud-timer player) nil)))

(defun etaf-ascii-video--install-size-hook ()
  "Install the application's window size hook once."
  (unless etaf-ascii-video--size-hook-installed
    (add-hook 'window-size-change-functions #'etaf-ascii-video--window-size-changed)
    (setq etaf-ascii-video--size-hook-installed t)))

;;;###autoload
(defun etaf-ascii-video-open (&optional source)
  "Open the ASCII video player and return its buffer.
SOURCE is nil for the built-in demo, a file name, an HTTP(S) URL, or a plist
accepted by `etaf-video-source-info'.  The display hints `:columns' and
`:rows' (canvas size in character cells), `:speed' (playback rate) and
`:mode' (`mono' or `color') are read from the plist form.  The canvas is
fitted to the selected window unless both size hints are given.  An existing
player is closed first; unreadable files, non-HTTP(S) URLs and unsupported
sources signal `user-error' before any process starts."
  (interactive (list (let ((name (read-file-name "Video file (empty for demo): " nil nil nil)))
                       (if (string-empty-p name) nil name))))
  (let* ((hints (and (consp source) source))
         (mode (or (plist-get hints :mode) etaf-ascii-video-render-mode))
         (speed (or (plist-get hints :speed) 1))
         (spec (etaf-video-source-info source)))
    (unless (memq mode '(mono color))
      (user-error "Unknown etaf-ascii-video render mode: %S (expected mono or color)"
                  mode))
    (unless (and (numberp speed) (> speed 0))
      (user-error "Playback speed must be a positive number: %S" speed))
    (when (get-buffer etaf-ascii-video--buffer-name)
      (with-current-buffer (get-buffer etaf-ascii-video--buffer-name)
        (when etaf-ascii-video--player
          (etaf-ascii-video-close))))
    (let* ((buffer (get-buffer-create etaf-ascii-video--buffer-name))
           (window (selected-window))
           (grid (if (and (integerp (plist-get hints :columns))
                          (integerp (plist-get hints :rows)))
                     (cons (plist-get hints :columns) (plist-get hints :rows))
                   (etaf-ascii-video--window-grid
                    window (etaf-ascii-video--aspect spec)
                    (and (eq mode 'color) etaf-ascii-video-color-columns))))
           (player (etaf-ascii-video--player-create
                    buffer spec mode (car grid) (cdr grid) speed)))
      (condition-case problem
          (progn
            (with-current-buffer buffer
              (setq-local etaf-ascii-video--player player)
              (setq-local truncate-lines t)
              (setq-local auto-hscroll-mode nil)
              ;; A video frame owns the whole canvas; a bar or box cursor over
              ;; an image cell would flash a border around the picture.
              (setq-local cursor-type nil)
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
              (etaf-mount buffer (etaf-ascii-video--view player)))
            (let ((display-buffer-overriding-action '((display-buffer-same-window))))
              (pop-to-buffer buffer))
            (when-let* ((shown (get-buffer-window buffer t)))
              (set-window-hscroll shown 0))
            (etaf-ascii-video--install-size-hook)
            (setf (etaf-ascii-video--player-hud-timer player)
                  (run-at-time 0.0 etaf-ascii-video--hud-interval
                               #'etaf-ascii-video--player-tick player))
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
(defun etaf-ascii-video-open-url (url)
  "Play the HTTP(S) video stream URL in the ASCII video player.
The stream is decoded directly by ffmpeg, so nothing is downloaded first.
Seeking depends on the server supporting range requests; a dropped
connection is retried up to five seconds.  The audio track is not played."
  (interactive "sVideo URL: ")
  (etaf-ascii-video-open (list :url url)))

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
  (let ((player (etaf-ascii-video--current)))
    (etaf-video-toggle-playback (etaf-ascii-video--player-handle player))
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-step ()
  "Pause the current player and present exactly one more frame."
  (interactive)
  (let ((player (etaf-ascii-video--current)))
    (etaf-video-step (etaf-ascii-video--player-handle player))
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-seek (seconds)
  "Move the current player to SECONDS and restart decoding there."
  (interactive "nSeconds: ")
  (let ((player (etaf-ascii-video--current)))
    (etaf-video-seek (etaf-ascii-video--player-handle player) seconds)
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-set-speed (speed)
  "Set the current player's rate to SPEED, a positive number."
  (interactive "nPlayback speed: ")
  (let ((player (etaf-ascii-video--current)))
    (etaf-ascii-video--player-set-speed player speed)
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-set-color (color)
  "Turn true-color half-block rendering on (non-nil) or off (nil).
Color mode renders two full color pixels per character cell with `▀' and
doubles the vertical resolution at the cost of one `face' per cell."
  (interactive "P")
  (let ((player (etaf-ascii-video--current)))
    (etaf-ascii-video--player-set-mode player (if color 'color 'mono))
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-set-render-mode (mode)
  "Switch the current player to MODE: `mono' or `color'.
`mono' uses the density ramp, and `color' renders two full color pixels per
cell with one `face' per cell.  The native session restarts at the current
position in the new mode."
  (interactive
   (list (intern (completing-read "Render mode: " '("mono" "color")
                                  nil t nil nil "mono"))))
  (let ((player (etaf-ascii-video--current)))
    (etaf-ascii-video--player-set-mode player mode)
    (etaf-ascii-video--player-render player))
  t)

(defun etaf-ascii-video-set-grid (columns rows)
  "Resize the current player's canvas to COLUMNS by ROWS cells."
  (interactive "nColumns: \nnRows: ")
  (let ((player (etaf-ascii-video--current)))
    (etaf-ascii-video--player-set-grid player columns rows)
    (etaf-ascii-video--player-render player))
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
`:columns', `:rows', `:mode', `:fps' (display rate), `:presented-fps'
(frames presented in the last sample window), `:source-fps', `:received',
`:presented', `:dropped' and `:ended'.  It reads the live player without
changing it, and signals `user-error' outside a player buffer."
  (let* ((player (etaf-ascii-video--current))
         (state (etaf-ascii-video--state player)))
    (list :source (plist-get state :source)
          :playing (plist-get state :playing)
          :position (plist-get state :position)
          :duration (plist-get state :duration)
          :speed (plist-get state :speed)
          :columns (etaf-ascii-video--player-columns player)
          :rows (etaf-ascii-video--player-rows player)
          :mode (etaf-ascii-video--player-mode player)
          :fps (plist-get state :display-fps)
          :presented-fps (or (etaf-ascii-video--player-sample-fps player) 0.0)
          :source-fps (plist-get state :source-fps)
          :received (plist-get state :received)
          :presented (plist-get state :presented)
          :dropped (plist-get state :dropped)
          :ended (plist-get state :ended))))

(defun etaf-ascii-video--forward-command ()
  "Seek five seconds forward."
  (interactive)
  (etaf-ascii-video-seek
   (+ (plist-get (etaf-ascii-video-state) :position) 5)))

(defun etaf-ascii-video--backward-command ()
  "Seek five seconds backward."
  (interactive)
  (etaf-ascii-video-seek
   (- (plist-get (etaf-ascii-video-state) :position) 5)))

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
  (let ((player (etaf-ascii-video--current)))
    (etaf-ascii-video--player-set-mode
     player (if (eq (etaf-ascii-video--player-mode player) 'color) 'mono 'color))
    (etaf-ascii-video--player-render player)))

(defun etaf-ascii-video--help-command ()
  "Show the ASCII video key bindings."
  (interactive)
  (message (concat "ASCII video: SPC play/pause, n step, f/b +-5s, +/- speed, "
                   "1-4 grid, c color, F fit, o open, u url, d demo, q close")))

(provide 'etaf-ascii-video-app)
;;; etaf-ascii-video-app.el ends here
