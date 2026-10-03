;;; etaf-ascii-video-grid.el --- ASCII pixel grids for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure grid facts shared by the player and the acceptance fixtures: fitting a
;; video frame into a character canvas, and mapping raw grayscale bytes to
;; ramp characters.  No process, buffer or Runtime state lives here.

;;; Code:

(require 'cl-lib)

(defvar etaf-ascii-video-density-ramp " .:-=+*#%@"
  "Characters used for one video pixel, from darkest to lightest.
The ramp must be nonempty and must not contain newline characters.
Changing it takes effect on the next rendered frame.")

(defvar etaf-ascii-video--translation-table nil
  "Cached byte to character translation table, or nil.")
(defvar etaf-ascii-video--translation-ramp nil
  "Ramp the cached translation table was built from.")

(defun etaf-ascii-video--table ()
  "Return the byte to character translation table for the current ramp."
  (let ((ramp etaf-ascii-video-density-ramp))
    (when (or (zerop (length ramp)) (string-match-p "\n" ramp))
      (user-error "`etaf-ascii-video-density-ramp' must be nonempty and single-line"))
    (unless (and etaf-ascii-video--translation-table
                 (equal etaf-ascii-video--translation-ramp ramp))
      (let ((table (make-char-table 'translation-table))
            (last (1- (length ramp))))
        (dotimes (byte 256)
          ;; (255 * last + 127) / 255 rounds the byte to the nearest ramp slot.
          (aset table byte (aref ramp (/ (+ (* byte last) 127) 255))))
        (setq etaf-ascii-video--translation-table table
              etaf-ascii-video--translation-ramp ramp)))
    etaf-ascii-video--translation-table))

(defun etaf-ascii-video--grid-text (bytes columns rows &optional buffer)
  "Return BYTES as ROWS lines of COLUMNS ramp characters.
BYTES must hold at least COLUMNS times ROWS grayscale bytes.  BUFFER, when
non-nil, is a reusable work buffer owned by the caller; otherwise a temporary
buffer is created and killed.  The result carries no text properties."
  (let* ((own (null buffer))
         (buffer (or buffer (generate-new-buffer " *etaf-ascii-video map*"))))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (set-buffer-multibyte nil)
          (insert bytes)
          (translate-region (point-min) (point-max) (etaf-ascii-video--table))
          (let ((row (1- rows)))
            (while (> row 0)
              (goto-char (1+ (* row columns)))
              (insert "\n")
              (setq row (1- row))))
          (buffer-substring-no-properties (point-min) (point-max)))
      (when own (kill-buffer buffer)))))

(defvar etaf-ascii-video--hex-pairs (make-vector 256 nil)
  "Two-digit lowercase hex text for every byte, indexed by value.")

(dotimes (byte 256)
  (aset etaf-ascii-video--hex-pairs byte (format "%02x" byte)))

(defun etaf-ascii-video--color-grid-text (bytes columns rows &optional buffer)
  "Return BYTES as ROWS lines of half-block cells with true color.
BYTES holds COLUMNS by twice ROWS RGB24 pixels in row-major order.  The top
pixel of each cell becomes the foreground of a `▀' character and the bottom
pixel its background, so one character cell shows two full-color pixels.
BUFFER, when non-nil, is ignored and kept for interface parity with the
monochrome mapper; the result carries one `face' property per cell."
  (ignore buffer)
  (let ((text (mapconcat #'identity
                         (make-list rows (make-string columns ?▀))
                         "\n"))
        (hex etaf-ascii-video--hex-pairs)
        (position 0))
    (dotimes (row rows)
      (let ((top (* (* 2 row) columns 3))
            (bottom (* (1+ (* 2 row)) columns 3)))
        (dotimes (column columns)
          (let* ((top-offset (+ top (* column 3)))
                 (bottom-offset (+ bottom (* column 3))))
            (put-text-property
             position (1+ position) 'face
             (list :foreground
                   (concat "#" (aref hex (aref bytes top-offset))
                           (aref hex (aref bytes (+ top-offset 1)))
                           (aref hex (aref bytes (+ top-offset 2))))
                   :background
                   (concat "#" (aref hex (aref bytes bottom-offset))
                           (aref hex (aref bytes (+ bottom-offset 1)))
                           (aref hex (aref bytes (+ bottom-offset 2)))))
             text)
            (setq position (1+ position))))
        (when (< row (1- rows))
          (setq position (1+ position)))))
    text))

(defun etaf-ascii-video--fit-grid (aspect max-columns max-rows &optional cell-aspect)
  "Return the largest (COLUMNS . ROWS) with ASPECT inside the canvas.
ASPECT is the video width divided by its height.  MAX-COLUMNS and MAX-ROWS are
the canvas limits in character cells.  CELL-ASPECT is one cell's
height divided by its width and defaults to 2.0, the usual terminal cell.
The result is at least 8 by 3 cells."
  (let* ((cell-aspect (or cell-aspect 2.0))
         (max-columns (max 8 (floor max-columns)))
         (max-rows (max 3 (floor max-rows)))
         (scale (* aspect cell-aspect))
         (columns (min max-columns (max 8 (floor (* max-rows scale)))))
         (rows (max 3 (min max-rows (floor (/ columns scale))))))
    (cons columns rows)))

(defun etaf-ascii-video--rows-for-columns (aspect columns &optional cell-aspect)
  "Return the row count of an ASPECT frame COLUMNS cells wide."
  (let ((scale (* aspect (or cell-aspect 2.0))))
    (max 3 (round (/ columns scale)))))

(provide 'etaf-ascii-video-grid)
;;; etaf-ascii-video-grid.el ends here
