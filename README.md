# Doom Org Mindmap

Convert Org documents to interactive mindmaps in real-time using Markmap.

## Features

- **Real-time sync**: Mindmap updates as you edit
- **Bidirectional navigation**: Click nodes to jump to headlines in Emacs
- **Focus mode**: Respects `org-narrow-to-subtree`
- **Theme sync**: Colors automatically match your Emacs theme

## Requirements

- Emacs 27.1+
- `simple-httpd` package
- `xwidget-webkit` support (optional, falls back to external browser)

## Installation

### Doom Emacs

Add to `packages.el`:

```elisp
(package! doom-org-mindmap
  :recipe (:local-repo "~/development/tool/org-mindmap"))
```

Add to `config.el`:

```elisp
(use-package! doom-org-mindmap
  :commands (+org-mindmap/open +org-mindmap/stop))
```

### Manual Installation

```elisp
(add-to-list 'load-path "/path/to/org-mindmap")
(require 'doom-org-mindmap)
```

## Usage

1. Open an Org file
2. Run `M-x +org-mindmap/open`
3. Click any node to jump to that headline in Emacs

### Focus Mode

Use `org-narrow-to-subtree` (C-x n s) to show only a specific section.

## Commands

| Command                    | Description                        |
|----------------------------|------------------------------------|
| `+org-mindmap/open`        | Open mindmap for current Org file  |
| `+org-mindmap/stop`        | Stop the mindmap server            |
| `+org-mindmap/toggle-narrow` | Toggle focus mode                |

## Customization

```elisp
(setq doom-org-mindmap-port 8899)           ;; Server port
(setq doom-org-mindmap-poll-interval 1000)  ;; Update interval (ms)
(setq doom-org-mindmap-use-narrow t)        ;; Respect narrowing
```
