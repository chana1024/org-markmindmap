# Org Mindmap

Convert Org documents to interactive mindmaps using Mind-elixir.

## Features

- **Real-time visualization** - Org structure displayed as interactive mindmap
- **Bidirectional sync** - Click nodes to jump to headlines in Emacs
- **Editable mindmap** - Edit nodes and sync changes back to Emacs
- **Focus mode** - Respects `org-narrow-to-subtree`
- **Summary nodes** - Group related nodes with summaries
- **Theme support** - Multiple dark/light themes

## Installation

### Doom Emacs

```elisp
;; In packages.el
(package! doom-org-mindmap :recipe (:local-repo "~/path/to/org-mindmap"))

;; In config.el
(use-package! doom-org-mindmap
  :commands (+org-mindmap/open +org-mindmap/stop)
  :init
  (map! :leader
        :prefix "m"
        :desc "Open mindmap" "M" #'+org-mindmap/open))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/org-mindmap")
(require 'doom-org-mindmap)
```

## Usage

1. Open any `.org` file
2. Run `M-x +org-mindmap/open`
3. Mindmap opens in browser at `http://localhost:8899/mindmap`

### Commands

| Command | Description |
|---------|-------------|
| `+org-mindmap/open` | Open current org file as mindmap |
| `+org-mindmap/stop` | Stop the mindmap server |
| `+org-mindmap/toggle-narrow` | Toggle focus mode |

## Summary Nodes

Summary nodes group related child nodes. Two syntaxes supported:

### Tag-based (`:summary:`)

```org
* Parent Heading :summary:
** Child 1
** Child 2
** Child 3
```

### Property-based

```org
* Parent Heading
:PROPERTIES:
:SUMMARY: Summary of children 1-2
:SUMMARY_RANGE: 0-2
:END:
** Child 1
** Child 2
** Child 3
```

## Customization

```elisp
;; Server port (default: 8899)
(setq doom-org-mindmap-port 8899)

;; Poll interval in ms (default: 1000)
(setq doom-org-mindmap-poll-interval 1000)

;; Respect buffer narrowing (default: t)
(setq doom-org-mindmap-use-narrow t)
```

## Keyboard Shortcuts (in mindmap)

- **Tab** - Add child node
- **Enter** - Add sibling node
- **Delete/Backspace** - Remove selected node
- **F2** - Edit node text
- **Click** - Select node & jump to Emacs

## Requirements

- Emacs 27.1+
- `simple-httpd` package
- Modern browser with ES6 module support

## License

MIT
