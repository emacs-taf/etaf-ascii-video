;;; etaf-ascii-video-tests.el --- Public acceptance scenarios -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Public-entry scenarios for the player.  Decoding and frame mapping belong
;; to the native `etaf-video' Component, so this suite drives it through the
;; application entry only.  The producer and metadata are the repository's
;; fake ffmpeg fixtures, so the suite needs no real decoder, no network and no
;; graphical frame; one explicitly gated scenario runs the real ffmpeg path.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-ascii-video)

(defconst etaf-ascii-video-tests--fixtures
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Fixture directory beside the test source.")

(defconst etaf-ascii-video-tests--ffmpeg
  (expand-file-name "fake-ffmpeg.py" etaf-ascii-video-tests--fixtures)
  "Executable fixture standing in for ffmpeg.")

(defconst etaf-ascii-video-tests--ffprobe
  (expand-file-name "fake-ffprobe.py" etaf-ascii-video-tests--fixtures)
  "Executable fixture standing in for ffprobe.")

(defconst etaf-ascii-video-tests--input
  (expand-file-name "fake-ffmpeg.py" etaf-ascii-video-tests--fixtures)
  "An existing file accepted as the video input; the fixture ignores it.")

(defun etaf-ascii-video-tests--log ()
  "Return a fresh log path for recorded fixture invocations."
  (make-temp-file "etaf-ascii-video-log-"))

(defun etaf-ascii-video-tests--runs (log)
  "Return the recorded fixture invocations in LOG as argument lists."
  (when (file-exists-p log)
    (mapcar (lambda (line) (split-string line "\000" t))
            (split-string
             (with-temp-buffer
               (insert-file-contents log)
               (buffer-string))
             "\n" t))))

(defun etaf-ascii-video-tests--cleanup ()
  "Close any leftover player without signaling."
  (when-let* ((buffer (get-buffer "*ASCII Video*")))
    (with-current-buffer buffer
      (condition-case nil
          (etaf-ascii-video-close)
        (error nil)))))

(defun etaf-ascii-video-tests--wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil for at most SECONDS, then retry once.
Return PREDICATE's final value."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.02)
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-ascii-video-tests--state ()
  "Return the live player state."
  (etaf-ascii-video-state))

(defun etaf-ascii-video-tests--visible (line)
  "Return LINE's active characters without EBox display padding.
EBox pads each row to its owner width with a `space' display character for
background painting; those characters are not video pixels."
  (let ((position 0) (end (length line)) cut)
    (while (< position end)
      (let ((display (get-text-property position 'display line)))
        (when (and (null cut) (consp display) (eq (car display) 'space))
          (setq cut position))
        (setq position (or (next-property-change position line end) end))))
    (substring-no-properties line 0 (or cut end))))

(defun etaf-ascii-video-tests--grid (rows)
  "Return the first ROWS visible grid lines of the application buffer."
  (with-current-buffer "*ASCII Video*"
    (mapconcat #'etaf-ascii-video-tests--visible
               (cl-subseq (split-string (buffer-string) "\n") 0 rows)
               "\n")))

(defun etaf-ascii-video-tests--columns-grid (columns rows)
  "Return the expected fixture grid for the `columns' pattern."
  (let* ((ramp etaf-video-density-ramp)
         (last (1- (length ramp)))
         (span (max 1 (1- columns))))
    (mapconcat
     (lambda (_row)
       (apply #'string
              (cl-loop for x below columns
                       for value = (floor (* x 255) span)
                       for index = (floor (+ (* value last) 127) 255)
                       collect (aref ramp index))))
     (number-sequence 1 rows) "\n")))

(defun etaf-ascii-video-tests--argument (arguments flag)
  "Return the value following FLAG in ARGUMENTS, or nil."
  (cadr (member flag arguments)))

(defmacro etaf-ascii-video-tests--with-fixture (log settings &rest body)
  "Run BODY with the fake decoder fixtures and SETTINGS bound.
LOG receives the recorded ffmpeg invocations.  SETTINGS is a list of ENV=VALUE
strings for the fixture."
  (declare (indent 2))
  `(let ((process-environment
          (append (cons (concat "FAKE_FFMPEG_LOG=" ,log) ,settings)
                  process-environment))
         (etaf-video-ffmpeg-program etaf-ascii-video-tests--ffmpeg)
         (etaf-video-ffprobe-program etaf-ascii-video-tests--ffprobe))
     ,@body))

(ert-deftest etaf-ascii-video-tests-renders-ramp-frames ()
  "Every displayed pixel is the ramp character of its grayscale byte.
The native session produces the documented gray scale and read rate, the
status line reports the canvas size, and the recorded invocation matches the
documented ffmpeg contract."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=200"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0"
               "FAKE_FFPROBE_FPS=50/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (should (equal (etaf-ascii-video-tests--grid 4)
                        (etaf-ascii-video-tests--columns-grid 16 4)))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (with-current-buffer "*ASCII Video*"
                      (string-match-p "16x4" (buffer-string))))))
         (let ((runs (etaf-ascii-video-tests--runs log)))
           (should (cl-some (lambda (arguments)
                              (member "scale=16:4:flags=area" arguments))
                            runs))
           (should (cl-some (lambda (arguments)
                              (equal (etaf-ascii-video-tests--argument arguments "-readrate")
                                     "1"))
                            runs))
           (should (cl-some (lambda (arguments)
                              (equal (etaf-ascii-video-tests--argument arguments "-pix_fmt")
                                     "gray"))
                            runs))))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-playback-controls ()
  "Play, pause, single-step, speed and seek keep the reported state honest.
A paused picture stays still, one step presents one more frame, resume moves
the picture again, and speed and seek restart the producer with the recorded
arguments."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=shift"
               "FAKE_FFMPEG_FRAMES=400"
               "FAKE_FFMPEG_INTERVAL=0.15"
               "FAKE_FFPROBE_DURATION=8.0"
               "FAKE_FFPROBE_FPS=10/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (etaf-ascii-video-toggle-playback)
         (should-not (plist-get (etaf-ascii-video-tests--state) :playing))
         (let ((paused (etaf-ascii-video-tests--grid 4)))
           (sleep-for 0.2)
           (should (equal paused (etaf-ascii-video-tests--grid 4)))
           (let ((presented (plist-get (etaf-ascii-video-tests--state) :presented)))
             (etaf-ascii-video-step)
             (should (etaf-ascii-video-tests--wait
                      (lambda ()
                        (> (plist-get (etaf-ascii-video-tests--state) :presented)
                           presented))))
             (should-not (plist-get (etaf-ascii-video-tests--state) :playing)))
           ;; A paused seek only moves the clock; no producer is running.
           (etaf-ascii-video-seek 0.5)
           (should (>= (plist-get (etaf-ascii-video-tests--state) :position) 0.5))
           (etaf-ascii-video-toggle-playback)
           (should (plist-get (etaf-ascii-video-tests--state) :playing))
           (should (etaf-ascii-video-tests--wait
                    (lambda ()
                      (not (equal paused (etaf-ascii-video-tests--grid 4)))))))
         ;; A restart while playing records the rate and the seek target.
         (etaf-ascii-video-set-speed 2)
         (should (= 2 (plist-get (etaf-ascii-video-tests--state) :speed)))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (cl-some (lambda (arguments)
                               (equal (etaf-ascii-video-tests--argument
                                       arguments "-readrate")
                                      "2"))
                             (etaf-ascii-video-tests--runs log)))))
         (etaf-ascii-video-seek 0.5)
         (should (>= (plist-get (etaf-ascii-video-tests--state) :position) 0.5))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (cl-some (lambda (arguments)
                               (etaf-ascii-video-tests--argument arguments "-ss"))
                             (etaf-ascii-video-tests--runs log)))))
         (etaf-ascii-video-toggle-playback))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-resume-seeks-instead-of-catching-up ()
  "Resuming after a pause restarts the producer at the pause position.
A wall-clock-paced ffmpeg would fast-forward to catch up after a suspension;
the player must release the producer on pause and restart it with `-ss' at the
paused position instead."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=shift"
               "FAKE_FFMPEG_FRAMES=400"
               "FAKE_FFMPEG_INTERVAL=0.1"
               "FAKE_FFPROBE_DURATION=8.0"
               "FAKE_FFPROBE_FPS=10/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (etaf-ascii-video-toggle-playback)
         (let ((paused-position (plist-get (etaf-ascii-video-tests--state) :position)))
           (sleep-for 0.5)
           (should (equal paused-position
                          (plist-get (etaf-ascii-video-tests--state) :position)))
           (etaf-ascii-video-toggle-playback)
           (should (etaf-ascii-video-tests--wait
                    (lambda ()
                      (cl-some (lambda (arguments)
                                 (etaf-ascii-video-tests--argument arguments "-ss"))
                               (etaf-ascii-video-tests--runs log)))))
           (let ((seek (string-to-number
                        (or (cl-some (lambda (arguments)
                                       (etaf-ascii-video-tests--argument arguments "-ss"))
                                     (etaf-ascii-video-tests--runs log))
                            "0"))))
             (should (>= seek paused-position))
             (should (< seek (+ paused-position 1.0))))
           (etaf-ascii-video-toggle-playback))
         (etaf-ascii-video-close))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-resizes-canvas ()
  "A new grid changes the published line shape and the fitted window size.
The session restarts with the new scale, and `etaf-ascii-video-fit' keeps the
canvas inside the window that shows it."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=200"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0"
               "FAKE_FFPROBE_FPS=50/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (etaf-ascii-video-set-grid 24 6)
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (equal (etaf-ascii-video-tests--grid 6)
                           (etaf-ascii-video-tests--columns-grid 24 6)))))
         (should (= 24 (plist-get (etaf-ascii-video-tests--state) :columns)))
         (should (= 6 (plist-get (etaf-ascii-video-tests--state) :rows)))
         (should (cl-some (lambda (arguments)
                            (member "scale=24:6:flags=area" arguments))
                          (etaf-ascii-video-tests--runs log)))
         (should (eq t (etaf-ascii-video-fit)))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (let ((state (etaf-ascii-video-tests--state)))
                      (<= (plist-get state :rows)
                          (max 3 (1- (window-body-height (selected-window)))))))))
         (etaf-ascii-video-close))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-rejects-invalid-sources ()
  "Invalid sources and a missing ffmpeg fail before anything is left behind.
Every rejection signals `user-error', the state API refuses a foreign buffer,
and no application buffer survives a failed open."
  (etaf-ascii-video-tests--cleanup)
  (should-error (etaf-ascii-video-open 42) :type 'user-error)
  (should-error (etaf-ascii-video-open '(:file "/definitely/missing.mp4"))
                :type 'user-error)
  (should-error (etaf-ascii-video-open '(:file)) :type 'user-error)
  (should-error (etaf-ascii-video-open (list :file etaf-ascii-video-tests--input
                                             :mode 'graphics))
                :type 'user-error)
  (etaf-ascii-video-tests--cleanup)
  (let ((etaf-video-ffmpeg-program "etaf-ascii-video-missing-ffmpeg")
        (etaf-video-ffprobe-program "etaf-ascii-video-missing-ffprobe"))
    (should-error (etaf-ascii-video-open '(:demo :columns 8 :rows 3))
                  :type 'user-error))
  (should-not (get-buffer "*ASCII Video*"))
  (with-temp-buffer
    (should-error (etaf-ascii-video-state) :type 'user-error))
  (etaf-ascii-video-tests--cleanup))

(ert-deftest etaf-ascii-video-tests-finishes-at-end ()
  "A producer that runs out of frames ends the player instead of waiting forever.
The last picture stays published, the status turns to `ended', and playing
again replays from the start."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=3"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=1.0"
               "FAKE_FFPROBE_FPS=50/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (plist-get (etaf-ascii-video-tests--state) :ended))
                  5))
         (should-not (plist-get (etaf-ascii-video-tests--state) :playing))
         (should (< 0.0 (plist-get (etaf-ascii-video-tests--state) :position)))
         (should (equal (etaf-ascii-video-tests--grid 4)
                        (etaf-ascii-video-tests--columns-grid 16 4)))
         (etaf-ascii-video-toggle-playback)
         (should (plist-get (etaf-ascii-video-tests--state) :playing))
         (etaf-ascii-video-close))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-documented-keys-reach-player ()
  "The documented keys drive the player instead of the renderer's own map.
Every binding is exercised through the command loop; closing with `q' leaves
no buffer behind."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=shift"
               "FAKE_FFMPEG_FRAMES=400"
               "FAKE_FFMPEG_INTERVAL=0.1"
               "FAKE_FFPROBE_DURATION=8.0"
               "FAKE_FFPROBE_FPS=10/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (with-current-buffer "*ASCII Video*"
           (execute-kbd-macro (kbd "SPC")))
         (should-not (plist-get (etaf-ascii-video-tests--state) :playing))
         (let ((presented (plist-get (etaf-ascii-video-tests--state) :presented)))
           (with-current-buffer "*ASCII Video*"
             (execute-kbd-macro (kbd "n")))
           (should (etaf-ascii-video-tests--wait
                    (lambda ()
                      (> (plist-get (etaf-ascii-video-tests--state) :presented)
                         presented)))))
         (with-current-buffer "*ASCII Video*"
           (execute-kbd-macro (kbd "SPC")))
         (should (plist-get (etaf-ascii-video-tests--state) :playing))
         (with-current-buffer "*ASCII Video*"
           (execute-kbd-macro (kbd "q")))
         (should-not (get-buffer "*ASCII Video*")))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-color-half-blocks ()
  "Color mode publishes half-block cells with per-cell true colors.
The fixture's RGB24 pattern makes each cell's foreground and background
predictable, the status line reports the mode, and turning color off returns
the player to density characters."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=400"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0"
               "FAKE_FFPROBE_FPS=50/1")
         (etaf-ascii-video-open
          (list :file etaf-ascii-video-tests--input :columns 16 :rows 4 :mode 'color))
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (should (eq 'color (plist-get (etaf-ascii-video-tests--state) :mode)))
         (with-current-buffer "*ASCII Video*"
           (let* ((text (buffer-string))
                  (line (substring text 0 (string-match "\n" text))))
             (should (= 16 (length (cl-remove-if-not (lambda (char) (eq char ?▀)) line))))
             (should (member '(:foreground "#000000" :background "#ff0000")
                             (get-text-property 0 'face line)))
             (should (member '(:foreground "#111111" :background "#ee0011")
                             (get-text-property 1 'face line)))))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (with-current-buffer "*ASCII Video*"
                      (string-match-p "color" (buffer-string))))))
         (etaf-ascii-video-set-color nil)
         (should (eq 'mono (plist-get (etaf-ascii-video-tests--state) :mode)))
         (should (etaf-ascii-video-tests--wait
                  (lambda ()
                    (with-current-buffer "*ASCII Video*"
                      (not (string-match-p "▀" (buffer-string)))))))
         (etaf-ascii-video-close))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-streams-http-url ()
  "An HTTP(S) URL is passed to ffmpeg as a stream, not opened as a file.
The fixture stands in for ffmpeg, so the recorded input and reconnect options
are checked without touching the network; non-HTTP schemes are rejected."
  (etaf-ascii-video-tests--cleanup)
  (let ((log (etaf-ascii-video-tests--log)))
    (unwind-protect
        (etaf-ascii-video-tests--with-fixture
         log
         (list "FAKE_FFMPEG_PATTERN=columns"
               "FAKE_FFMPEG_FRAMES=40"
               "FAKE_FFMPEG_INTERVAL=0.02"
               "FAKE_FFPROBE_DURATION=4.0"
               "FAKE_FFPROBE_FPS=50/1")
         (etaf-ascii-video-open-url "https://example.invalid/video.mp4")
         (should (etaf-ascii-video-tests--wait
                  (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 1))))
         (should (equal "https://example.invalid/video.mp4"
                        (plist-get (etaf-ascii-video-tests--state) :source)))
         (let ((runs (etaf-ascii-video-tests--runs log)))
           (should (cl-some (lambda (arguments)
                              (member "https://example.invalid/video.mp4" arguments))
                            runs))
           (should (cl-some (lambda (arguments)
                              (equal (etaf-ascii-video-tests--argument arguments "-reconnect")
                                     "1"))
                            runs)))
         (should-error (etaf-ascii-video-open-url "ftp://example.invalid/v.mp4")
                       :type 'user-error)
         (etaf-ascii-video-close))
      (ignore-errors (delete-file log))
      (etaf-ascii-video-tests--cleanup))))

(ert-deftest etaf-ascii-video-tests-plays-demo-with-real-ffmpeg ()
  "The built-in demo plays through a real ffmpeg when one is installed.
This scenario is skipped on machines without ffmpeg; the fixture scenarios
above still cover the full public path there."
  (skip-unless (executable-find "ffmpeg"))
  (etaf-ascii-video-tests--cleanup)
  (unwind-protect
      (progn
        (etaf-ascii-video-demo)
        (etaf-ascii-video-set-grid 48 14)
        (should (etaf-ascii-video-tests--wait
                 (lambda () (>= (plist-get (etaf-ascii-video-tests--state) :presented) 2))
                 10))
        (should (= 30 (plist-get (etaf-ascii-video-tests--state) :source-fps)))
        (let ((grid (etaf-ascii-video-tests--grid 14)))
          (should (string-match-p "=" grid))))
    (etaf-ascii-video-tests--cleanup)))

(provide 'etaf-ascii-video-tests)
;;; etaf-ascii-video-tests.el ends here
