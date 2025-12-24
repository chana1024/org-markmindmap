;;; doom-org-mindmap.el --- Convert Org documents to Markmap mindmaps -*- lexical-binding: t; -*-

;; Author: Your Name
;; Version: 1.1.0
;; Package-Requires: ((emacs "27.1") (simple-httpd "1.5.1"))
;; Keywords: org, mindmap, visualization
;; URL: https://github.com/yourusername/doom-org-mindmap

;;; Commentary:

;; This package provides real-time conversion of Org documents to interactive
;; mindmaps using Markmap. It follows Doom Emacs naming conventions.
;;
;; Features:
;; - Real-time org-to-mindmap conversion
;; - Bidirectional sync: click nodes to jump to headlines
;; - Focus mode: respects org-narrow-to-subtree
;; - Theme sync: extracts colors from current Emacs theme

;;; Code:

(require 'simple-httpd)
(require 'org-element)
(require 'json)

;;; Customization

(defgroup doom-org-mindmap nil
  "Convert Org documents to Markmap mindmaps."
  :group 'org
  :prefix "doom-org-mindmap-")

(defcustom doom-org-mindmap-port 8899
  "Port for the mindmap server."
  :type 'integer
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-poll-interval 1000
  "Polling interval in milliseconds for frontend updates."
  :type 'integer
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-use-narrow t
  "Whether to respect buffer narrowing (focus mode).
When non-nil, only the narrowed region will be shown in the mindmap."
  :type 'boolean
  :group 'doom-org-mindmap)

;;; Internal Variables

(defvar +org-mindmap--current-buffer nil
  "The org buffer being visualized.")

(defvar +org-mindmap--server-running nil
  "Whether the mindmap server is running.")

;; Capture the directory at load time
(defvar +org-mindmap--static-root
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "doom-org-mindmap")
                           default-directory))
  "Root directory for static files.")

;;; Theme Color Extraction

(defun +org-mindmap--color-to-hex (color)
  "Convert COLOR (name or #hex) to a hex string."
  (if (and color (not (string-empty-p color)))
      (let ((rgb (color-values color)))
        (if rgb
            (format "#%02x%02x%02x"
                    (/ (nth 0 rgb) 256)
                    (/ (nth 1 rgb) 256)
                    (/ (nth 2 rgb) 256))
          color))
    nil))

(defun +org-mindmap--get-theme-colors ()
  "Extract colors from current Emacs theme for web frontend."
  (let* ((bg (face-background 'default nil t))
         (fg (face-foreground 'default nil t))
         (keyword (face-foreground 'font-lock-keyword-face nil t))
         (function (face-foreground 'font-lock-function-name-face nil t))
         (string (face-foreground 'font-lock-string-face nil t))
         (type (face-foreground 'font-lock-type-face nil t))
         (constant (face-foreground 'font-lock-constant-face nil t))
         (comment (face-foreground 'font-lock-comment-face nil t))
         (link (face-foreground 'link nil t))
         ;; Determine if dark mode based on background luminance
         (bg-rgb (color-values bg))
         (luminance (if bg-rgb
                        (/ (+ (* 0.299 (nth 0 bg-rgb))
                              (* 0.587 (nth 1 bg-rgb))
                              (* 0.114 (nth 2 bg-rgb)))
                           65535.0)
                      0.1))
         (is-dark (< luminance 0.5)))
    `((background . ,(+org-mindmap--color-to-hex bg))
      (foreground . ,(+org-mindmap--color-to-hex fg))
      (isDark . ,is-dark)
      (nodeColors . ,(vconcat
                      (delq nil
                            (list (+org-mindmap--color-to-hex keyword)
                                  (+org-mindmap--color-to-hex function)
                                  (+org-mindmap--color-to-hex string)
                                  (+org-mindmap--color-to-hex type)
                                  (+org-mindmap--color-to-hex constant)
                                  (+org-mindmap--color-to-hex link)))))
      (linkColor . ,(or (+org-mindmap--color-to-hex comment)
                        (+org-mindmap--color-to-hex fg))))))

;;; Core Functions

(defun +org-mindmap--headline-to-node (headline)
  "Convert an org HEADLINE element to a Markmap node structure.
Includes :begin position for bidirectional navigation."
  (let* ((title (org-element-property :raw-value headline))
         (begin (org-element-property :begin headline))
         (children (org-element-contents headline))
         (child-headlines (seq-filter
                           (lambda (el)
                             (eq (org-element-type el) 'headline))
                           children))
         (child-nodes (mapcar #'+org-mindmap--headline-to-node child-headlines)))
    (if child-nodes
        `((content . ,title)
          (begin . ,begin)
          (children . ,(vconcat child-nodes)))
      `((content . ,title)
        (begin . ,begin)
        (children . [])))))

(defun +org-mindmap--get-json ()
  "Parse current org buffer and return Markmap-compatible JSON string.
Respects buffer narrowing when `doom-org-mindmap-use-narrow' is non-nil."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-restriction
        ;; If not using narrow mode, widen to show full buffer
        (unless doom-org-mindmap-use-narrow
          (widen))
        (let* ((tree (org-element-parse-buffer 'headline))
               (headlines (org-element-contents tree))
               (top-headlines (seq-filter
                               (lambda (el)
                                 (eq (org-element-type el) 'headline))
                               headlines))
               (root-title (or (when (buffer-file-name)
                                 (file-name-base (buffer-file-name)))
                               (buffer-name)))
               (narrowed-p (buffer-narrowed-p))
               (root-node `((content . ,(if narrowed-p
                                            (concat root-title " [focused]")
                                          root-title))
                            (begin . ,(point-min))
                            (children . ,(vconcat
                                          (mapcar #'+org-mindmap--headline-to-node
                                                  top-headlines))))))
          (json-encode root-node))))))

;;; Navigation (Bidirectional Sync)

(defun +org-mindmap--goto-position (pos)
  "Jump to position POS in the current org buffer."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (let ((window (get-buffer-window +org-mindmap--current-buffer)))
      (if window
          (progn
            (select-window window)
            (goto-char pos)
            (org-reveal)
            (recenter))
        ;; Buffer exists but no window, show it
        (pop-to-buffer +org-mindmap--current-buffer)
        (goto-char pos)
        (org-reveal)
        (recenter)))))

;;; Servlets

(defun +org-mindmap--data-servlet (request)
  "Servlet to return org structure as JSON for REQUEST."
  (with-httpd-buffer request "application/json; charset=utf-8"
    (insert (or (+org-mindmap--get-json) "{}"))))

(defun +org-mindmap--index-servlet (request)
  "Servlet to serve the index.html for REQUEST."
  (let ((index-file (expand-file-name "index.html" +org-mindmap--static-root)))
    (if (file-exists-p index-file)
        (with-httpd-buffer request "text/html; charset=utf-8"
          (insert-file-contents index-file))
      (httpd-error request 404 "index.html not found"))))

(defun +org-mindmap--config-servlet (request)
  "Servlet to return configuration for REQUEST."
  (with-httpd-buffer request "application/json; charset=utf-8"
    (insert (json-encode
             `((pollInterval . ,doom-org-mindmap-poll-interval))))))

;;; Server Management

(defun +org-mindmap--start-server ()
  "Start the mindmap HTTP server."
  (unless +org-mindmap--server-running
    (setq httpd-port doom-org-mindmap-port)
    (message "Static root: %s" +org-mindmap--static-root)
    ;; Register servlets
    (defservlet* data "application/json" ()
      (insert (or (+org-mindmap--get-json) "{}")))
    (defservlet* config "application/json" ()
      (insert (json-encode
               `((pollInterval . ,doom-org-mindmap-poll-interval)))))
    (defservlet* theme "application/json" ()
      (insert (json-encode (+org-mindmap--get-theme-colors))))
    (defservlet* goto text/plain (pos)
      (when pos
        (let ((position (string-to-number pos)))
          (+org-mindmap--goto-position position)))
      (insert "ok"))
    (defservlet* mindmap "text/html" ()
      (let ((index-file (expand-file-name "index.html" +org-mindmap--static-root)))
        (when (file-exists-p index-file)
          (insert-file-contents index-file))))
    (httpd-start)
    (setq +org-mindmap--server-running t)
    (message "Mindmap server started on port %d" doom-org-mindmap-port)))

(defun +org-mindmap--stop-server ()
  "Stop the mindmap HTTP server."
  (when +org-mindmap--server-running
    (httpd-stop)
    (setq +org-mindmap--server-running nil)
    (message "Mindmap server stopped")))

;;; Interactive Commands

;;;###autoload
(defun +org-mindmap/open ()
  "Open the current org buffer as a mindmap.
If xwidget-webkit is available, use it; otherwise open in external browser."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run in an org-mode buffer"))
  (setq +org-mindmap--current-buffer (current-buffer))
  (+org-mindmap--start-server)
  (let ((url (format "http://localhost:%d/mindmap" doom-org-mindmap-port)))
    ;; Copy URL to kill ring for convenience
    (kill-new url)
    (if (and (featurep 'xwidget-internal)
             (fboundp 'xwidget-webkit-browse-url))
        (progn
          (xwidget-webkit-browse-url url t)
          (message "Mindmap opened in xwidget-webkit"))
      ;; External browser fallback
      (browse-url url)
      (message "Mindmap opened in browser. URL copied: %s" url))))

;;;###autoload
(defun +org-mindmap/stop ()
  "Stop the mindmap server and close visualization."
  (interactive)
  (+org-mindmap--stop-server)
  (setq +org-mindmap--current-buffer nil))

;;;###autoload
(defun +org-mindmap/refresh ()
  "Manually refresh the mindmap by re-parsing the org buffer."
  (interactive)
  (when +org-mindmap--current-buffer
    (message "Mindmap data refreshed")))

;;;###autoload
(defun +org-mindmap/toggle-narrow ()
  "Toggle whether mindmap respects buffer narrowing."
  (interactive)
  (setq doom-org-mindmap-use-narrow (not doom-org-mindmap-use-narrow))
  (message "Mindmap narrow mode: %s"
           (if doom-org-mindmap-use-narrow "ON" "OFF")))

(provide 'doom-org-mindmap)
;;; doom-org-mindmap.el ends here
