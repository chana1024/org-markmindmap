;;; doom-org-mindmap.el --- Convert Org documents to Mind-elixir mindmaps -*- lexical-binding: t; -*-

;; Author: Your Name
;; Version: 2.0.0
;; Package-Requires: ((emacs "27.1") (simple-httpd "1.5.1"))
;; Keywords: org, mindmap, visualization
;; URL: https://github.com/yourusername/doom-org-mindmap

;;; Commentary:

;; This package provides real-time conversion of Org documents to interactive
;; mindmaps using Mind-elixir. It follows Doom Emacs naming conventions.
;;
;; Features:
;; - Real-time org-to-mindmap conversion via JSON
;; - Bidirectional sync: click nodes to jump to headlines
;; - Edit in mindmap and sync back to Emacs
;; - Focus mode: respects org-narrow-to-subtree
;; - Summary nodes support via :summary: tag or SUMMARY property

;;; Code:

(require 'simple-httpd)
(require 'org-element)
(require 'json)

;;; Customization

(defgroup doom-org-mindmap nil
  "Convert Org documents to Mind-elixir mindmaps."
  :group 'org
  :prefix "doom-org-mindmap-")

(defcustom doom-org-mindmap-port 8899
  "Port for the mindmap server."
  :type 'integer
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-poll-interval 3000
  "Polling interval in milliseconds for frontend updates."
  :type 'integer
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-use-narrow t
  "Whether to respect buffer narrowing (focus mode).
When non-nil, only the narrowed region will be shown in the mindmap."
  :type 'boolean
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-static-root nil
  "Override directory for static files (index.html).
If nil, auto-detect from package location."
  :type '(choice (const nil) directory)
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-split-window t
  "Whether to open mindmap in a new window (split).
When non-nil, splits the current window and displays mindmap in the new window.
When nil, opens in the current window."
  :type 'boolean
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-include-items t
  "Whether to include list items as nodes in the mindmap."
  :type 'boolean
  :group 'doom-org-mindmap)

(defcustom doom-org-mindmap-include-content t
  "Whether to include content (paragraphs) as nodes in the mindmap."
  :type 'boolean
  :group 'doom-org-mindmap)

;;; Internal Variables

(defvar +org-mindmap--current-buffer nil
  "The org buffer being visualized.")

(defvar +org-mindmap--server-running nil
  "Whether the mindmap server is running.")

(defun +org-mindmap--on-buffer-switch (&optional _frame)
  "Update current buffer when switching to an org-mode buffer.
Only triggers when the mindmap server is running.
FRAME argument is ignored (required by `window-buffer-change-functions')."
  (ignore-errors
    (when (and +org-mindmap--server-running
               (not (minibufferp))
               (not (string-prefix-p " " (buffer-name)))
               (not (string-prefix-p "*xwidget" (buffer-name)))
               (not (eq major-mode 'xwidget-webkit-mode))
               (buffer-file-name)
               (derived-mode-p 'org-mode))
      (setq +org-mindmap--current-buffer (current-buffer)))))

(defun +org-mindmap--get-static-root ()
  "Get the directory containing static files."
  (or doom-org-mindmap-static-root
      (when load-file-name
        (file-name-directory load-file-name))
      (when (locate-library "doom-org-mindmap")
        (file-name-directory (locate-library "doom-org-mindmap")))
      (expand-file-name "~/development/tool/org-mindmap/"))
  (or doom-org-mindmap-static-root
      (when load-file-name
        (file-name-directory load-file-name))
      (when (locate-library "doom-org-mindmap")
        (file-name-directory (locate-library "doom-org-mindmap")))
      (expand-file-name "~/development/tool/org-mindmap/")))

;;; Core Functions - Markdown Inline Conversion

(defun +org-mindmap--org-to-markdown-inline (text)
  "Convert Org inline formatting in TEXT to Markdown."
  (when text
    (let ((result text))
      ;; Links: [[url][description]] → [description](url)
      (setq result
            (replace-regexp-in-string
             "\\[\\[\\([^]]+\\)\\]\\[\\([^]]+\\)\\]\\]" "[\\2](\\1)" result))
      ;; Links without description: [[url]] → url
      (setq result
            (replace-regexp-in-string "\\[\\[\\([^]]+\\)\\]\\]" "\\1" result))
      ;; Bold: *text* → **text**
      (setq result
            (replace-regexp-in-string "\\*\\([^*\n]+\\)\\*" "**\\1**" result))
      ;; Italic: /text/ → *text*
      (setq result (replace-regexp-in-string "/\\([^/\n]+\\)/" "*\\1*" result))
      ;; Code: =text= or ~text~ → `text`
      (setq result
            (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "`\\1`" result))
      ;; Strikethrough: +text+ → ~~text~~
      (setq result
            (replace-regexp-in-string "\\+\\([^+\n]+\\)\\+" "~~\\1~~" result))
      result)))

;;; Core Functions - JSON Conversion for Mind-elixir

(defun +org-mindmap--generate-node-id (begin)
  "Generate unique node ID based on BEGIN position."
  (format "node-%s" (or begin (random 1000000))))

(defun +org-mindmap--process-element (element)
  "Convert an org ELEMENT to a JSON structure if applicable."
  (let ((type (org-element-type element)))
    (cond
     ((eq type 'headline) (+org-mindmap--headline-to-json element))
     ((and doom-org-mindmap-include-items (eq type 'plain-list))
      (+org-mindmap--list-to-json element))
     ((and doom-org-mindmap-include-content (eq type 'paragraph))
      (+org-mindmap--paragraph-to-json element))
     ((eq type 'section) ;; Recursively process section content
      (+org-mindmap--container-to-json-list element))
     (t nil))))

(defun +org-mindmap--container-to-json-list (container)
  "Process children of CONTAINER and return list of JSON nodes."
  (let ((children (org-element-contents container)))
    (seq-filter #'identity
                (mapcar #'+org-mindmap--process-element children))))

(defun +org-mindmap--list-to-json (plain-list)
  "Convert PLAIN-LIST to a list of item nodes."
  ;; A plain-list is not a node itself, but returns a list of item nodes
  ;; Since our structure expects a single node return or list, we need to handle this.
  ;; However, our mapcar logic expects one node per element.
  ;; Wait, a plain-list element contains items. We should probably return the items as siblings?
  ;; But the current structure (children array) expects a list of nodes.
  ;; Let's make this function return a LIST of nodes, and the caller handles flattening.
  ;; Actually, let's treat the list itself as a transparency and return its items.
  ;; But +org-mindmap--process-element is expected to return A NODE Usually.
  ;; Let's change +org-mindmap--process-element to return a LIST of nodes.
  nil) ;; Re-thinking strategy below

(defun +org-mindmap--process-children (element)
  "Process all children of ELEMENT and return a flat list of JSON nodes."
  (let ((contents (org-element-contents element))
        (result nil))
    (dolist (child contents)
      (let ((type (org-element-type child)))
        (cond
         ((eq type 'headline)
          (push (+org-mindmap--headline-to-json child) result))
         ((eq type 'section)
          (setq result (append (+org-mindmap--process-children child) result)))
         ((and doom-org-mindmap-include-items (eq type 'plain-list))
          (setq result (append (+org-mindmap--process-list child) result)))
         ((and doom-org-mindmap-include-content (eq type 'paragraph))
          (push (+org-mindmap--paragraph-to-json child) result)))))
    (nreverse result)))

(defun +org-mindmap--process-list (plain-list)
  "Convert PLAIN-LIST to a list of item nodes."
  (let ((items (org-element-contents plain-list))
        (result nil))
    (dolist (item items)
      (when (eq (org-element-type item) 'item)
        (push (+org-mindmap--item-to-json item) result)))
    (nreverse result)))

(defun +org-mindmap--item-to-json (item)
  "Convert list ITEM to JSON node."
  (let* ((tag (org-element-property :tag item))
         (bullet (org-element-property :bullet item))
         ;; Content of item is tricky, it's mixed with children
         ;; We need to extract the first paragraph or clean text?
         ;; Actually item contents are elements too.
         (contents (org-element-contents item))
         (begin (org-element-property :begin item))
         (id (+org-mindmap--generate-node-id begin))
         (text (if tag (format "%s %s" bullet tag) bullet)) ;; Fallback title if no paragraph
         ;; Find first paragraph for title?
         (first-para (seq-find (lambda (x) (eq (org-element-type x) 'paragraph)) contents))
         (cb (and first-para (org-element-property :contents-begin first-para)))
         (ce (and first-para (org-element-property :contents-end first-para)))
         (title (if (and cb ce)
                    (buffer-substring-no-properties cb ce)
                  (or text "")))
         ;; Clean title
         (clean-title (string-trim (or title "")))
         (md-title (+org-mindmap--org-to-markdown-inline clean-title))
         ;; Children
         (children (+org-mindmap--process-children item)))
    `((topic . ,md-title)
      (id . ,id)
      (begin . ,begin)
      (expanded . t)
      (children . ,children))))

(defun +org-mindmap--paragraph-to-json (paragraph)
  "Convert PARAGRAPH to JSON node."
  (let* ((begin (org-element-property :begin paragraph))
         (cb (org-element-property :contents-begin paragraph))
         (ce (org-element-property :contents-end paragraph))
         (id (+org-mindmap--generate-node-id begin))
         (text (if (and cb ce)
                   (buffer-substring-no-properties cb ce)
                 ""))
         (clean-text (string-trim text))
         (md-text (+org-mindmap--org-to-markdown-inline clean-text)))
    (if (> (length clean-text) 0)
        `((topic . ,md-text)
          (id . ,id)
          (begin . ,begin)
          ;; Paragraphs are usually leaves, but we handle it generally
          (children . []))
      nil)))

(defun +org-mindmap--headline-to-json (headline)
  "Convert HEADLINE to Mind-elixir JSON node structure."
  (let* ((title (org-element-property :raw-value headline))
         (begin (org-element-property :begin headline))
         (id (+org-mindmap--generate-node-id begin))
         (md-title (+org-mindmap--org-to-markdown-inline title))
         (children (+org-mindmap--process-children headline))
         (tags (org-element-property :tags headline))
         ;; Check for summary tag
         (has-summary-tag (member "summary" tags))
         ;; Check for SUMMARY property
         (summary-label (org-element-property :SUMMARY headline))
         (summary-range (org-element-property :SUMMARY_RANGE headline)))
    `((topic . ,md-title)
      (id . ,id)
      (begin . ,begin)
      (expanded . t)
      (children . ,children)
      ,@
      (when tags
        `((tags
           .
           ,(vconcat
             (seq-filter (lambda (tag) (not (string= tag "summary"))) tags)))))
      ;; Summary info for frontend
      ,@
      (when (or has-summary-tag summary-label)
        `((hasSummary . t)
          ,@
          (when summary-label
            `((summaryLabel . ,summary-label)))
          ,@
          (when summary-range
            (let* ((range-parts (split-string summary-range "-"))
                   (start (string-to-number (car range-parts)))
                   (end
                    (when (cdr range-parts)
                      (string-to-number (cadr range-parts)))))
              `((summaryStart . ,start)
                (summaryEnd . ,(or end (length child-headlines)))))))))))

(defun +org-mindmap--extract-summaries (node)
  "Extract summary definitions from NODE tree recursively."
  (let ((summaries nil)
        (has-summary (alist-get 'hasSummary node))
        (node-id (alist-get 'id node))
        (children (alist-get 'children node)))
    ;; Check if this node has summary
    (when has-summary
      (let* ((label (or (alist-get 'summaryLabel node) "Summary"))
             (start (or (alist-get 'summaryStart node) 0))
             (end (or (alist-get 'summaryEnd node) (length children))))
        (push `((id . ,(format "summary-%s" node-id))
                (parent . ,node-id)
                (start . ,start)
                (end . ,end)
                (label . ,label))
              summaries)))
    ;; Recurse into children
    (dolist (child children)
      (setq summaries
            (append summaries (+org-mindmap--extract-summaries child))))
    summaries))

(defun +org-mindmap--get-json ()
  "Parse current org buffer and return JSON for Mind-elixir."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-restriction
        (unless doom-org-mindmap-use-narrow
          (widen))
        (let* ((tree (org-element-parse-buffer)) ;; Full parse
               (root-children (+org-mindmap--process-children tree))
               (file-title
                (car (cdr (assoc "TITLE" (org-collect-keywords '("TITLE"))))))
               (root-title
                (or file-title
                    (when (buffer-file-name)
                      (file-name-base (buffer-file-name)))
                    (buffer-name)))
               (narrowed-p (buffer-narrowed-p))
               (title-text
                (if narrowed-p
                    (concat root-title " [focused]")
                  root-title))
               (root-id "root")
               (root-node
                `((topic . ,title-text)
                  (id . ,root-id)
                  (begin . ,(point-min))
                  (expanded . t)
                  (root . t)
                  (root . t)
                  (children . ,root-children))
               (summaries (+org-mindmap--extract-summaries root-node)))
          (json-encode
           `((topic . ,(alist-get 'topic root-node))
             (id . ,(alist-get 'id root-node))
             (begin . ,(alist-get 'begin root-node))
             (expanded . t)
             (children . ,(alist-get 'children root-node))
             (summaries . ,(vconcat summaries)))))))))

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
        (pop-to-buffer +org-mindmap--current-buffer)
        (goto-char pos)
        (org-reveal)
        (recenter)))))

;;; Edit Sync - From Mindmap to Org

(defun +org-mindmap--update-headline (position old-topic new-topic)
  "Update headline at POSITION from OLD-TOPIC to NEW-TOPIC."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-excursion
        (goto-char position)
        (when (org-at-heading-p)
          (let* ((element (org-element-at-point))
                 (begin (org-element-property :begin element))
                 (end (org-element-property :end element))
                 (current-title (org-element-property :raw-value element)))
            ;; Find and replace the headline text
            (goto-char begin)
            (when (re-search-forward (regexp-quote current-title) end t)
              (replace-match new-topic t t))))))))

(defun +org-mindmap--add-child-headline (parent-position topic)
  "Add a child headline with TOPIC under headline at PARENT-POSITION."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-excursion
        (goto-char parent-position)
        (org-end-of-subtree t t)
        (unless (bolp)
          (insert "\n"))
        (let ((level (1+ (org-current-level))))
          (insert (make-string level ?*) " " topic "\n"))))))

(defun +org-mindmap--add-sibling-headline (position topic)
  "Add a sibling headline with TOPIC after headline at POSITION."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-excursion
        (goto-char position)
        (org-end-of-subtree t t)
        (unless (bolp)
          (insert "\n"))
        (let ((level (org-current-level)))
          (insert (make-string level ?*) " " topic "\n"))))))

(defun +org-mindmap--delete-headline (position)
  "Delete headline at POSITION."
  (when (and +org-mindmap--current-buffer
             (buffer-live-p +org-mindmap--current-buffer))
    (with-current-buffer +org-mindmap--current-buffer
      (save-excursion
        (goto-char position)
        (when (org-at-heading-p)
          (org-cut-subtree))))))

;;; Server Management

(defun +org-mindmap--start-server ()
  "Start the mindmap HTTP server."
  (unless +org-mindmap--server-running
    (setq httpd-port doom-org-mindmap-port)
    (let ((static-root (+org-mindmap--get-static-root)))
      (message "Mindmap static root: %s" static-root)

      (setq httpd-root static-root)

      ;; JSON data endpoint
      (defservlet*
       data "application/json" () (insert (or (+org-mindmap--get-json) "{}")))

      ;; Config
      (defservlet*
       config "application/json" ()
       (insert
        (json-encode `((pollInterval . ,doom-org-mindmap-poll-interval)
                       (includeItems . ,doom-org-mindmap-include-items)
                       (includeContent . ,doom-org-mindmap-include-content)))))

      ;; Update config
      (defservlet*
       update-config text/plain ()
       (let* ((content (httpd-body httpd-request))
              (data (json-read-from-string content))
              (items (alist-get 'includeItems data))
              (content-flag (alist-get 'includeContent data)))
         (unless (eq items nil)
           (setq doom-org-mindmap-include-items items))
         (unless (eq content-flag nil)
           (setq doom-org-mindmap-include-content content-flag))
         (insert "ok")))

      ;; Navigation - goto position
      (defservlet*
       goto text/plain (pos)
       (let ((http-buffer (current-buffer)))
         (when pos
           (let ((position (string-to-number pos)))
             (+org-mindmap--goto-position position)))
         (set-buffer http-buffer)
         (insert "ok")))

      ;; Update headline
      (defservlet*
       update text/plain ()
       (let* ((content (httpd-body httpd-request))
              (data (json-read-from-string content))
              (position (alist-get 'position data))
              (old-topic (alist-get 'oldTopic data))
              (new-topic (alist-get 'newTopic data)))
         (when (and position new-topic)
           (+org-mindmap--update-headline position old-topic new-topic)))
       (insert "ok"))

      ;; Add new node
      (defservlet*
       add-node text/plain ()
       (let* ((content (httpd-body httpd-request))
              (data (json-read-from-string content))
              (parent-position (alist-get 'parentPosition data))
              (topic (alist-get 'topic data))
              (type (alist-get 'type data)))
         (when (and parent-position topic)
           (if (string= type "child")
               (+org-mindmap--add-child-headline parent-position topic)
             (+org-mindmap--add-sibling-headline parent-position topic))))
       (insert "ok"))

      ;; Delete node
      (defservlet*
       delete-node text/plain ()
       (let* ((content (httpd-body httpd-request))
              (data (json-read-from-string content))
              (position (alist-get 'position data)))
         (when position
           (+org-mindmap--delete-headline position)))
       (insert "ok"))


      (httpd-start)
      (setq +org-mindmap--server-running t)
      ;; Add hook to track buffer switches to org buffers
      (add-hook 'window-buffer-change-functions #'+org-mindmap--on-buffer-switch)
      (message "Mindmap server started on port %d" doom-org-mindmap-port))))
(defun +org-mindmap--stop-server ()
  "Stop the mindmap HTTP server."
  (when +org-mindmap--server-running
    (httpd-stop)
    (setq +org-mindmap--server-running nil)
    ;; Remove buffer switch hook
    (remove-hook 'window-buffer-change-functions #'+org-mindmap--on-buffer-switch)
    (message "Mindmap server stopped")))

;;; Interactive Commands

;;;###autoload
(defun +org-mindmap/open ()
  "Open the current org buffer as a mindmap."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run in an org-mode buffer"))
  (setq +org-mindmap--current-buffer (current-buffer))
  (+org-mindmap--start-server)
  (let ((url (format "http://localhost:%d/" doom-org-mindmap-port)))
    (kill-new url)
    (if (and (featurep 'xwidget-internal) (fboundp 'xwidget-webkit-browse-url))
        (progn
          (when doom-org-mindmap-split-window
            (select-window (split-window-right)))
          (xwidget-webkit-browse-url url t)
          (message "Mindmap opened in xwidget-webkit"))
      ;; External browser - split window not applicable
      (browse-url url)
      (message "Mindmap opened in browser. URL copied: %s" url))))

;;;###autoload
(defun +org-mindmap/stop ()
  "Stop the mindmap server and close visualization."
  (interactive)
  (+org-mindmap--stop-server)
  (setq +org-mindmap--current-buffer nil))

;;;###autoload
(defun +org-mindmap/toggle-narrow ()
  "Toggle whether mindmap respects buffer narrowing."
  (interactive)
  (setq doom-org-mindmap-use-narrow (not doom-org-mindmap-use-narrow))
  (message "Mindmap narrow mode: %s"
           (if doom-org-mindmap-use-narrow
               "ON"
             "OFF")))

(provide 'doom-org-mindmap)
;;; doom-org-mindmap.el ends here
