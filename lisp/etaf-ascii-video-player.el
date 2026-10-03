;;; etaf-ascii-video-player.el --- Playback state for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One player owns a buffer's mounted canvas, its frame producer and its
;; display timer.  Every displayed frame is published as the text of the
;; retained grid Host through `etaf-runtime-update-host-contents', so one tick
;; is one retained publication instead of an ordinary ETAF render.  The timer
;; always claims only the newest complete frame; when decoding is faster than
;; display, older frames are dropped instead of replayed.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ascii-video-grid)
(require 'etaf-ascii-video-source)

(defvar etaf-ascii-video-display-fps 30
  "Display timer rate in frames per second.
It caps the presented frame rate; the producer's own rate may be lower or
higher.  Values below 1 are raised to 1.")

(defconst etaf-ascii-video--grid-ref 'etaf-ascii-video-grid
  "Retained Host reference of the video canvas.")

(defconst etaf-ascii-video--hud-ref 'etaf-ascii-video-hud
  "Retained Host reference of the status line.")

(defconst etaf-ascii-video--speeds '(0.5 1 2 4 8)
  "Playback rates offered by the speed commands.")

(cl-defstruct (etaf-ascii-video--player (:constructor etaf-ascii-video--player--make))
  "A mounted ASCII video player."
  buffer spec columns rows speed timer source base playing stepping ended finished
  frame-ms error grid-text hud-text presented-times
  received-total presented-total dropped-total
  columns-ref rows-ref grid-text-ref hud-text-ref)

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

(defun etaf-ascii-video--player-position (player)
  "Return PLAYER's current position in seconds.
The value is the seek base plus the frames the current producer delivered,
so a dropped display frame still advances the clock."
  (let* ((spec (etaf-ascii-video--player-spec player))
         (source (etaf-ascii-video--player-source player))
         (fps (float (or (plist-get spec :fps) 25)))
         (received (if source (etaf-ascii-video--source-received source) 0))
         (position (+ (etaf-ascii-video--player-base player)
                      (/ received fps)))
         (duration (plist-get spec :duration)))
    (if duration (min position duration) position)))

(defun etaf-ascii-video--player-presented-fps (player)
  "Return PLAYER's presented frames in the last second."
  (length (etaf-ascii-video--player-presented-times player)))

(defun etaf-ascii-video--player-received (player)
  "Return PLAYER's lifetime frame count, including the live producer."
  (+ (etaf-ascii-video--player-received-total player)
     (let ((source (etaf-ascii-video--player-source player)))
       (if source (etaf-ascii-video--source-received source) 0))))

(defun etaf-ascii-video--player-presented (player)
  "Return PLAYER's lifetime presented frame count."
  (+ (etaf-ascii-video--player-presented-total player)
     (let ((source (etaf-ascii-video--player-source player)))
       (if source (etaf-ascii-video--source-presented source) 0))))

(defun etaf-ascii-video--player-dropped (player)
  "Return PLAYER's lifetime dropped frame count."
  (+ (etaf-ascii-video--player-dropped-total player)
     (let ((source (etaf-ascii-video--player-source player)))
       (if source (etaf-ascii-video--source-dropped source) 0))))

(defun etaf-ascii-video--player-hud (player)
  "Return PLAYER's one-line status text."
  (format "%s %s/%s  %dfps  %.1fms  dropped %d  %dx%d  %s  %sx"
          (cond ((etaf-ascii-video--player-error player) "error")
                ((etaf-ascii-video--player-ended player) "ended")
                ((etaf-ascii-video--player-stepping player) "step")
                ((etaf-ascii-video--player-playing player) "playing")
                (t "paused"))
          (etaf-ascii-video--clock (etaf-ascii-video--player-position player))
          (etaf-ascii-video--clock
           (plist-get (etaf-ascii-video--player-spec player) :duration))
          (etaf-ascii-video--player-presented-fps player)
          (or (etaf-ascii-video--player-frame-ms player) 0.0)
          (etaf-ascii-video--player-dropped player)
          (etaf-ascii-video--player-columns player)
          (etaf-ascii-video--player-rows player)
          (if (plist-get (etaf-ascii-video--player-spec player) :color)
              "color"
            "mono")
          (format "%s" (etaf-ascii-video--player-speed player))))

(cl-defun etaf-ascii-video--player-create (buffer spec columns rows)
  "Create a player for BUFFER, SPEC, COLUMNS and ROWS without starting it.
The view refs returned here are closed over by the application View."
  (let* ((speed (or (plist-get spec :speed) 1))
         (player (etaf-ascii-video--player--make
                  :buffer buffer :spec spec :columns columns :rows rows
                  :speed speed :base 0 :playing nil :stepping nil
                  :ended nil :finished nil :frame-ms nil
                  :received-total 0 :presented-total 0 :dropped-total 0
                  :grid-text " " :hud-text "paused 00:00/--:--")))
    (setf (etaf-ascii-video--player-columns-ref player) (etaf-ref (list 'ch columns))
          (etaf-ascii-video--player-rows-ref player) (etaf-ref (list 'lh rows))
          (etaf-ascii-video--player-grid-text-ref player)
          (etaf-ref (etaf-ascii-video--player-grid-text player))
          (etaf-ascii-video--player-hud-text-ref player)
          (etaf-ref (etaf-ascii-video--player-hud-text player)))
    player))

(defun etaf-ascii-video--player-runtime (player)
  "Return PLAYER's mounted Runtime, or nil when the buffer is gone."
  (let ((buffer (etaf-ascii-video--player-buffer player)))
    (and (buffer-live-p buffer) (etaf-runtime-for-buffer buffer))))

(defun etaf-ascii-video--player-present (player grid-text hud-text)
  "Publish GRID-TEXT and HUD-TEXT as PLAYER's retained Host contents."
  (when-let* ((runtime (etaf-ascii-video--player-runtime player)))
    (etaf-runtime-update-host-contents
     runtime
     (list (cons etaf-ascii-video--grid-ref grid-text)
           (cons etaf-ascii-video--hud-ref hud-text)))
    t))

(defun etaf-ascii-video--player-refresh (player)
  "Publish PLAYER's current grid and status text without a new frame.
Used for pause, seek, speed and grid changes, when the picture is unchanged
but the status line must follow."
  (when (etaf-ascii-video--player-grid-text player)
    (condition-case problem
        (etaf-ascii-video--player-present
         player (etaf-ascii-video--player-grid-text player)
         (setf (etaf-ascii-video--player-hud-text player)
               (etaf-ascii-video--player-hud player)))
      (etaf-runtime-error (etaf-ascii-video--player-fail player problem)))))

(defun etaf-ascii-video--player-fail (player problem)
  "Stop PLAYER and surface PROBLEM in the status line."
  (setf (etaf-ascii-video--player-playing player) nil
        (etaf-ascii-video--player-stepping player) nil
        (etaf-ascii-video--player-error player) (error-message-string problem))
  (when-let* ((timer (etaf-ascii-video--player-timer player)))
    (cancel-timer timer)
    (setf (etaf-ascii-video--player-timer player) nil))
  (ignore-errors (etaf-ascii-video--player-refresh player))
  (message "etaf-ascii-video: %s" (error-message-string problem)))

(defun etaf-ascii-video--player-render (player frame)
  "Render FRAME through PLAYER's retained grid."
  (condition-case problem
      (progn
        (let ((begin (float-time)))
          (setf (etaf-ascii-video--player-grid-text player)
                (if (plist-get (etaf-ascii-video--player-spec player) :color)
                    (etaf-ascii-video--color-grid-text
                     frame (etaf-ascii-video--player-columns player)
                     (etaf-ascii-video--player-rows player))
                  (etaf-ascii-video--grid-text
                   frame (etaf-ascii-video--player-columns player)
                   (etaf-ascii-video--player-rows player)
                   (and (etaf-ascii-video--player-source player)
                        (etaf-ascii-video--source-work
                         (etaf-ascii-video--player-source player))))))
          (etaf-ascii-video--player-present
           player (etaf-ascii-video--player-grid-text player)
           (setf (etaf-ascii-video--player-hud-text player)
                 (etaf-ascii-video--player-hud player)))
          (setf (etaf-ascii-video--player-frame-ms player)
                (* 1000 (- (float-time) begin)))
          (let ((now (float-time)))
            (setf (etaf-ascii-video--player-presented-times player)
                  (cons now (cl-delete-if (lambda (at) (> (- now at) 1.0))
                                          (etaf-ascii-video--player-presented-times player)))))))
    (etaf-runtime-error (etaf-ascii-video--player-fail player problem))))

(defun etaf-ascii-video--player-stop-source (player)
  "Close PLAYER's producer, keeping the position it reached.
The position is folded into PLAYER's base and the producer's counters into
its lifetime totals before the process is released."
  (when-let* ((source (etaf-ascii-video--player-source player)))
    (setf (etaf-ascii-video--player-base player)
          (etaf-ascii-video--player-position player))
    (setf (etaf-ascii-video--player-received-total player)
          (+ (etaf-ascii-video--player-received-total player)
             (etaf-ascii-video--source-received source)))
    (setf (etaf-ascii-video--player-presented-total player)
          (+ (etaf-ascii-video--player-presented-total player)
             (etaf-ascii-video--source-presented source)))
    (setf (etaf-ascii-video--player-dropped-total player)
          (+ (etaf-ascii-video--player-dropped-total player)
             (etaf-ascii-video--source-dropped source)))
    (etaf-ascii-video--source-close source)
    (setf (etaf-ascii-video--player-source player) nil)))

(defun etaf-ascii-video--player-finish (player)
  "Stop PLAYER after its producer ended, keeping the last picture visible."
  (unless (etaf-ascii-video--player-finished player)
    (setf (etaf-ascii-video--player-ended player) t
          (etaf-ascii-video--player-finished player) t
          (etaf-ascii-video--player-playing player) nil)
    (when-let* ((timer (etaf-ascii-video--player-timer player)))
      (cancel-timer timer)
      (setf (etaf-ascii-video--player-timer player) nil))
    (etaf-ascii-video--player-stop-source player)
    (etaf-ascii-video--player-refresh player)))

(defun etaf-ascii-video--player-tick (player)
  "One display timer tick: claim the newest frame and update the Hosts."
  (when (buffer-live-p (etaf-ascii-video--player-buffer player))
    (let ((source (etaf-ascii-video--player-source player))
          (frame nil))
      (when (and source
                 (or (etaf-ascii-video--player-playing player)
                     (etaf-ascii-video--player-stepping player)))
        (setq frame (etaf-ascii-video--source-claim source)))
      (when frame
        (etaf-ascii-video--player-render player frame)
        (when (etaf-ascii-video--player-stepping player)
          (setf (etaf-ascii-video--player-stepping player) nil
                (etaf-ascii-video--player-playing player) nil)
          (etaf-ascii-video--player-stop-source player)
          (etaf-ascii-video--player-refresh player)))
      (when (and (or (etaf-ascii-video--player-ended player)
                     (and source (etaf-ascii-video--source-ended source)))
                 (or (null source)
                     (null (etaf-ascii-video--source-latest source))))
        (etaf-ascii-video--player-finish player)))))

(defun etaf-ascii-video--player-start-timer (player)
  "Start PLAYER's display timer when it is not running."
  (unless (etaf-ascii-video--player-timer player)
    (setf (etaf-ascii-video--player-timer player)
          (run-at-time 0.0 (/ 1.0 (max 1 (round etaf-ascii-video-display-fps)))
                       #'etaf-ascii-video--player-tick player))))

(defun etaf-ascii-video--player-spawn (player &optional start)
  "Create PLAYER's producer at START seconds and apply its play state.
Callers only spawn a producer they intend to consume: pause releases it, so
a resume or step can seek back instead of catching up to wall-clock time."
  (let* ((spec (etaf-ascii-video--player-spec player))
         (source (etaf-ascii-video--source-start
                  spec
                  (etaf-ascii-video--player-columns player)
                  (etaf-ascii-video--player-rows player)
                  :speed (etaf-ascii-video--player-speed player)
                  :start (or start 0))))
    (setf (etaf-ascii-video--player-source player) source
          (etaf-ascii-video--player-base player) (or start 0)
          (etaf-ascii-video--player-ended player) nil
          (etaf-ascii-video--player-finished player) nil
          (etaf-ascii-video--player-error player) nil)
    source))

(defun etaf-ascii-video--player-restart (player &optional start)
  "Restart PLAYER's producer, keeping its position unless START is given."
  (let ((position (or start (etaf-ascii-video--player-position player))))
    (etaf-ascii-video--player-stop-source player)
    (etaf-ascii-video--player-spawn player position)))

(defun etaf-ascii-video--player-play (player)
  "Start PLAYER's producer and display timer."
  (unless (etaf-ascii-video--player-source player)
    (etaf-ascii-video--player-spawn player (etaf-ascii-video--player-base player)))
  (etaf-ascii-video--player-start-timer player)
  (setf (etaf-ascii-video--player-playing player) t)
  (etaf-ascii-video--player-refresh player))

(defun etaf-ascii-video--player-pause (player)
  "Pause PLAYER: release the producer, keeping the position it reached."
  (setf (etaf-ascii-video--player-playing player) nil
        (etaf-ascii-video--player-stepping player) nil)
  (etaf-ascii-video--player-stop-source player)
  (etaf-ascii-video--player-refresh player))

(defun etaf-ascii-video--player-toggle (player)
  "Toggle PLAYER between playing and paused."
  (if (etaf-ascii-video--player-playing player)
      (etaf-ascii-video--player-pause player)
    (when (etaf-ascii-video--player-ended player)
      (etaf-ascii-video--player-restart player 0))
    (etaf-ascii-video--player-play player)))

(defun etaf-ascii-video--player-step (player)
  "Pause PLAYER and present exactly one more frame."
  (when (etaf-ascii-video--player-playing player)
    (etaf-ascii-video--player-pause player))
  (unless (etaf-ascii-video--player-ended player)
    (unless (etaf-ascii-video--player-source player)
      (etaf-ascii-video--player-spawn player (etaf-ascii-video--player-base player)))
    (setf (etaf-ascii-video--player-stepping player) t)
    (etaf-ascii-video--player-start-timer player)
    (etaf-ascii-video--player-refresh player)))

(defun etaf-ascii-video--player-seek (player seconds)
  "Move PLAYER to SECONDS and restart its producer there."
  (let* ((duration (plist-get (etaf-ascii-video--player-spec player) :duration))
         (target (max 0 (if duration (min seconds duration) seconds)))
         (playing (etaf-ascii-video--player-playing player)))
    (if playing
        (progn
          (etaf-ascii-video--player-restart player target)
          (etaf-ascii-video--player-play player))
      (setf (etaf-ascii-video--player-base player) target)
      (etaf-ascii-video--player-stop-source player)
      (etaf-ascii-video--player-refresh player))))

(defun etaf-ascii-video--player-set-speed (player speed)
  "Set PLAYER's rate to SPEED and restart its producer at the same position."
  (unless (and (numberp speed) (> speed 0))
    (user-error "Playback speed must be a positive number: %S" speed))
  (setf (etaf-ascii-video--player-speed player) speed)
  (let ((playing (etaf-ascii-video--player-playing player)))
    (if playing
        (progn
          (etaf-ascii-video--player-restart player)
          (etaf-ascii-video--player-play player))
      (etaf-ascii-video--player-refresh player))))

(defun etaf-ascii-video--player-set-color (player color)
  "Turn PLAYER's true-color half-block mode on or off and restart decoding."
  (unless (eq (and (plist-get (etaf-ascii-video--player-spec player) :color) t)
              (and color t))
    (setf (plist-get (etaf-ascii-video--player-spec player) :color) (and color t))
    (let ((playing (etaf-ascii-video--player-playing player)))
      (if playing
          (progn
            (etaf-ascii-video--player-restart player)
            (etaf-ascii-video--player-play player))
        (etaf-ascii-video--player-stop-source player)
        (etaf-ascii-video--player-refresh player)))))

(defun etaf-ascii-video--player-set-grid (player columns rows)
  "Resize PLAYER's canvas to COLUMNS by ROWS and restart its producer."
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (user-error "Canvas size must be positive integers: %S by %S" columns rows))
  (unless (and (= columns (etaf-ascii-video--player-columns player))
               (= rows (etaf-ascii-video--player-rows player)))
    (setf (etaf-ascii-video--player-columns player) columns
          (etaf-ascii-video--player-rows player) rows)
    (setf (etaf-value (etaf-ascii-video--player-columns-ref player)) (list 'ch columns)
          (etaf-value (etaf-ascii-video--player-rows-ref player)) (list 'lh rows))
    (setf (etaf-value (etaf-ascii-video--player-grid-text-ref player))
          (etaf-ascii-video--player-grid-text player)
          (etaf-value (etaf-ascii-video--player-hud-text-ref player))
          (etaf-ascii-video--player-hud-text player))
    (when-let* ((runtime (etaf-ascii-video--player-runtime player)))
      (etaf-runtime-flush runtime))
    (let ((playing (etaf-ascii-video--player-playing player)))
      (setf (etaf-ascii-video--player-base player)
            (etaf-ascii-video--player-position player))
      (if playing
          (progn
            (etaf-ascii-video--player-restart player)
            (etaf-ascii-video--player-play player))
        (etaf-ascii-video--player-stop-source player)
        (etaf-ascii-video--player-refresh player)))))

(defun etaf-ascii-video--player-close (player)
  "Release PLAYER's timer, producer and buffers."
  (when-let* ((timer (etaf-ascii-video--player-timer player)))
    (cancel-timer timer)
    (setf (etaf-ascii-video--player-timer player) nil))
  (etaf-ascii-video--player-stop-source player))

(provide 'etaf-ascii-video-player)
;;; etaf-ascii-video-player.el ends here
