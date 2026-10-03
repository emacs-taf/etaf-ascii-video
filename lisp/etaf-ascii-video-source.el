;;; etaf-ascii-video-source.el --- ffmpeg frame stream for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One running frame producer: source normalization, ffprobe metadata, the
;; ffmpeg argv contract, a binary process and a latest-frame buffer.  The
;; player polls `claim', so the newest complete frame always wins and a slow
;; display drops older frames instead of replaying a backlog.  Nothing here
;; touches a buffer being displayed by ETAF.

;;; Code:

(require 'cl-lib)

(defvar etaf-ascii-video-ffmpeg-program "ffmpeg"
  "Name or absolute path of the ffmpeg executable.
Set it to a wrapper script to add decoder options of your own; the player
appends the filter and rawvideo output arguments described in the manual.")

(defvar etaf-ascii-video-ffprobe-program "ffprobe"
  "Name or absolute path of the ffprobe executable.
Missing metadata degrades to defaults instead of failing playback.")

(cl-defstruct (etaf-ascii-video--source (:constructor etaf-ascii-video--source--make))
  "A running raw or JPEG frame producer."
  process pipe work columns rows frame-size carry latest received presented dropped ended exit graphics-p)

(defun etaf-ascii-video--number (values key)
  "Return VALUES's KEY as a positive number, or nil."
  (let ((text (gethash key values)))
    (when (and (stringp text) (string-match-p "\\`[0-9.]+\\'" text))
      (let ((number (string-to-number text)))
        (when (> number 0) number)))))

(defun etaf-ascii-video--probe (file)
  "Return FILE's (:duration :fps :width :height) from ffprobe, or nil.
Missing ffprobe, an unreadable file or malformed output returns nil and lets
playback use documented defaults."
  (when-let* ((program (executable-find etaf-ascii-video-ffprobe-program)))
    (ignore-errors
      (let ((values (make-hash-table :test #'equal)))
        (dolist (line (process-lines program "-v" "error"
                                     "-select_streams" "v:0"
                                     "-show_entries"
                                     "stream=width,height,r_frame_rate:format=duration"
                                     "-of" "default=nw=1" file))
          (when (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" line)
            (puthash (match-string 1 line) (match-string 2 line) values)))
        (let ((rate (gethash "r_frame_rate" values)))
          (list :width (etaf-ascii-video--number values "width")
                :height (etaf-ascii-video--number values "height")
                :duration (etaf-ascii-video--number values "duration")
                :fps (when (and (stringp rate)
                                (string-match "\\`\\([0-9.]+\\)/\\([0-9.]+\\)\\'" rate))
                       (let ((frames (string-to-number (match-string 1 rate)))
                             (seconds (string-to-number (match-string 2 rate))))
                         (when (> seconds 0) (/ frames seconds))))))))))

(defun etaf-ascii-video--url-p (source)
  "Return non-nil when SOURCE is an HTTP or HTTPS URL string."
  (and (stringp source)
       (string-match-p "\\`https?://[^[:space:]]+\\'" source)))

(cl-defun etaf-ascii-video--normalize-source (source)
  "Return SOURCE as a normalized plist, or signal `user-error'.
SOURCE is nil for the built-in demo, a file name or HTTP(S) URL string, or
a plist:

  (:file PATH)   a local video file; ffprobe supplies its metadata
  (:url URL)     an HTTP(S) video stream decoded directly by ffmpeg
  (:demo)        a generated 30 second test pattern, no file needed

All accept the display hints `:columns' and `:rows' (canvas size in character
cells) and `:speed' (playback rate).  The result holds `:kind', `:file',
`:url', `:width', `:height', `:duration', `:fps', `:mode' and the hints."
  (let (kind file url)
    (cond ((null source) (setq kind 'demo))
          ((etaf-ascii-video--url-p source) (setq kind 'url url source))
          ((stringp source) (setq kind 'file file source))
          ((and (consp source) (eq (car source) :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :demo)) (setq kind 'demo))
          ((and (consp source) (plist-get source :url))
           (setq kind 'url url (plist-get source :url)))
          ((and (consp source) (plist-get source :file))
           (setq kind 'file file (plist-get source :file)))
          (t (user-error "Unsupported etaf-ascii-video source: %S" source)))
    (when (eq kind 'file)
      (unless (and (stringp file) (file-readable-p file))
        (user-error "Video file is not readable: %S" file)))
    (when (eq kind 'url)
      (unless (etaf-ascii-video--url-p url)
        (user-error "Video URL must be http or https: %S" url)))
    (let* ((probe (and (memq kind '(file url)) (etaf-ascii-video--probe (or file url))))
           (width (or (and (memq kind '(file url)) (plist-get probe :width))
                      (plist-get source :width) 640))
           (height (or (and (memq kind '(file url)) (plist-get probe :height))
                       (plist-get source :height) 360))
           (duration (or (and (memq kind '(file url)) (plist-get probe :duration))
                         (plist-get source :duration)
                         (and (eq kind 'demo) 30)))
           (fps (or (and (memq kind '(file url)) (plist-get probe :fps))
                    (plist-get source :fps)
                    (and (eq kind 'demo) 30)
                    25)))
      (list :kind kind
            :file file
            :url url
            :width width
            :height height
            :duration duration
            :fps fps
            :columns (plist-get source :columns)
            :rows (plist-get source :rows)
            :speed (plist-get source :speed)
            :mode (or (plist-get source :mode)
                      (and (plist-get source :color) 'color))))))

(defun etaf-ascii-video--ffmpeg-arguments (spec columns rows speed start)
  "Return ffmpeg arguments for SPEC at COLUMNS by ROWS character cells.
SPEED is the `-readrate' factor; START is the seek position in seconds.
The `mono' mode outputs one grayscale byte per cell, `color' outputs COLUMNS
by twice ROWS RGB24 pixels and `graphics' outputs one MJPEG image per frame,
scaled to the pixel size recorded in SPEC."
  (let ((mode (plist-get spec :mode)))
    (append (list "-hide_banner" "-loglevel" "error")
            (when (and (numberp start) (> start 0))
              (list "-ss" (number-to-string start)))
            (list "-readrate" (number-to-string speed))
            (pcase (plist-get spec :kind)
              ('file (list "-i" (plist-get spec :file)))
              ('url (list "-reconnect" "1" "-reconnect_streamed" "1"
                          "-reconnect_delay_max" "5"
                          "-i" (plist-get spec :url)))
              ('demo (list "-f" "lavfi" "-i" "testsrc2=size=640x360:rate=30" "-t" "30"))
              (_ (user-error "Cannot build ffmpeg arguments for %S" spec)))
            (pcase mode
              ('graphics
               (list "-vf" (format "scale=%d:%d:flags=area"
                                   (or (plist-get spec :pixel-width) columns)
                                   (or (plist-get spec :pixel-height) rows))
                     "-f" "image2pipe" "-c:v" "mjpeg" "-"))
              ('color
               (list "-vf" (format "scale=%d:%d:flags=area" columns (* 2 rows))
                     "-f" "rawvideo" "-pix_fmt" "rgb24" "-"))
              (_
               (list "-vf" (format "scale=%d:%d:flags=area" columns rows)
                     "-f" "rawvideo" "-pix_fmt" "gray" "-"))))))

(defun etaf-ascii-video--source-filter (process chunk)
  "Accumulate CHUNK into complete frames; the newest complete frame wins.
Raw frames are cut at their fixed byte length; graphics frames are complete
JPEG images delimited by SOI and EOI markers."
  (let ((source (process-get process 'etaf-ascii-video-source)))
    (when source
      (let ((data (concat (etaf-ascii-video--source-carry source) chunk)))
        (if (etaf-ascii-video--source-graphics-p source)
            (let ((soi (string-search "\xff\xd8" data))
                  (eoi nil) (frame nil))
              (when soi
                (setq eoi (string-search "\xff\xd9" data (1+ soi))))
              (while (and soi eoi)
                (setq frame (substring data soi (+ eoi 2))
                      data (substring data (+ eoi 2))
                      soi (string-search "\xff\xd8" data)
                      eoi (and soi (string-search "\xff\xd9" data (1+ soi)))))
              (when frame
                (when (etaf-ascii-video--source-latest source)
                  (cl-incf (etaf-ascii-video--source-dropped source)))
                (setf (etaf-ascii-video--source-latest source) frame)
                (cl-incf (etaf-ascii-video--source-received source))))
          (let ((size (etaf-ascii-video--source-frame-size source)))
            (while (>= (length data) size)
              (let ((frame (substring data 0 size)))
                (setq data (substring data size))
                (when (etaf-ascii-video--source-latest source)
                  (cl-incf (etaf-ascii-video--source-dropped source)))
                (setf (etaf-ascii-video--source-latest source) frame)
                (cl-incf (etaf-ascii-video--source-received source))))))
        (setf (etaf-ascii-video--source-carry source) data)))))

(defun etaf-ascii-video--source-sentinel (process _event)
  "Mark PROCESS's source ended when the producer really terminated.
Stop and continue events leave the producer running and are ignored."
  (let ((source (process-get process 'etaf-ascii-video-source)))
    (when (and source (not (process-live-p process)))
      (setf (etaf-ascii-video--source-ended source) t)
      (setf (etaf-ascii-video--source-exit source)
            (condition-case nil (process-exit-status process) (error nil))))))

(cl-defun etaf-ascii-video--source-start (spec columns rows &key speed start)
  "Start a producer for normalized SPEC at COLUMNS by ROWS.
SPEED defaults to 1 and START to 0.  Return the new source.  A missing ffmpeg
signals `user-error' before any process exists."
  (let ((program (or (executable-find etaf-ascii-video-ffmpeg-program)
                     (user-error "ffmpeg is not available: %s"
                                 etaf-ascii-video-ffmpeg-program)))
        (pipe (generate-new-buffer " *etaf-ascii-video pipe*"))
        (work (generate-new-buffer " *etaf-ascii-video map*"))
        (frame-size (pcase (plist-get spec :mode)
                      ('color (* columns rows 2 3))
                      ('graphics 0)
                      (_ (* columns rows))))
        (process nil))
    (setq process
          (make-process
           :name "etaf-ascii-video"
           :command (cons program
                          (etaf-ascii-video--ffmpeg-arguments
                           spec columns rows (or speed 1) (or start 0)))
           :buffer pipe
           :coding '(no-conversion . no-conversion)
           :connection-type 'pipe
           :noquery t
           :filter #'etaf-ascii-video--source-filter
           :sentinel #'etaf-ascii-video--source-sentinel))
    (let ((source (etaf-ascii-video--source--make
                   :process process :pipe pipe :work work
                   :columns columns :rows rows :frame-size frame-size
                   :carry "" :latest nil :received 0 :presented 0 :dropped 0
                   :graphics-p (eq (plist-get spec :mode) 'graphics))))
      (process-put process 'etaf-ascii-video-source source)
      source)))

(defun etaf-ascii-video--source-claim (source)
  "Return SOURCE's newest complete frame, clearing it, or nil."
  (when-let* ((frame (etaf-ascii-video--source-latest source)))
    (setf (etaf-ascii-video--source-latest source) nil)
    (cl-incf (etaf-ascii-video--source-presented source))
    frame))

(defun etaf-ascii-video--source-close (source)
  "Terminate SOURCE's producer and release its buffers."
  (let ((process (etaf-ascii-video--source-process source)))
    (when (process-live-p process) (delete-process process)))
  (dolist (buffer (list (etaf-ascii-video--source-pipe source)
                        (etaf-ascii-video--source-work source)))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(provide 'etaf-ascii-video-source)
;;; etaf-ascii-video-source.el ends here
