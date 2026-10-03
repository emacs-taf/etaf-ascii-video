;;; etaf-ascii-video-demo.el --- Runnable demo for etaf-ascii-video -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The built-in test pattern needs no file:
;;
;;   emacs -Q -L ../.. -L . -l examples/etaf-ascii-video-demo.el \
;;         -f etaf-ascii-video-demo-open
;;
;; Starting from this repository root instead, use `-L ../etaf -L ../ebox
;; -L ../ecss -L ..`.  Press SPC to pause, n to step, +/- to change the rate,
;; 1-4 to change the grid, d to replay and q to close.

;;; Code:

(require 'etaf-ascii-video)

(defun etaf-ascii-video-demo-open ()
  "Open the built-in ASCII video demo."
  (interactive)
  (etaf-ascii-video-demo))

(provide 'etaf-ascii-video-demo)
;;; etaf-ascii-video-demo.el ends here
