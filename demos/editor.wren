// Text Editor demo for XTC written in Wren
// Interactive line editor with cursor, history, and keyboard input

import "dom" for Window, Document, Element

class Editor {
  construct new(container) {
    _container = container
    _document = Document
    _buffer = ""
    _cursor = 0
    _history = []
    _historyIndex = null

    // DOM elements (created once, updated as needed)
    _editorBox = null
    _textLine = null
    _beforeText = null
    _cursorEl = null
    _cursorText = null
    _afterText = null
    _statusText = null

    setupDOM()
    setupEventHandler()
  }

  setupDOM() {
    // Create editor UI structure
    _editorBox = _document.createElement("flex flex-col grow-1 bg-gray-900 p-2")

    // Title
    var titleBox = _document.createElement("text-cyan-500 mb-1")
    var titleText = _document.createText("XTC Text Editor - Type to edit, Enter to submit, Escape to clear")
    titleBox.append(titleText)
    _editorBox.append(titleBox)

    // Main text line with cursor
    _textLine = _document.createElement("flex flex-row text-white")

    // Create persistent text elements
    _beforeText = _document.createText("")
    _textLine.append(_beforeText)

    _cursorEl = _document.createElement("bg-blue-500 text-white")
    _cursorText = _document.createText(" ")
    _cursorEl.append(_cursorText)
    _textLine.append(_cursorEl)

    _afterText = _document.createText("")
    _textLine.append(_afterText)

    _editorBox.append(_textLine)

    // Status line
    var statusBox = _document.createElement("text-gray-500 mt-1")
    _statusText = _document.createText("Ready | Cursor: 0 | Length: 0")
    statusBox.append(_statusText)
    _editorBox.append(statusBox)

    // History display
    var historyBox = _document.createElement("text-gray-600 mt-2")
    var historyLabel = _document.createText("History (Up/Down arrows to navigate):")
    historyBox.append(historyLabel)
    _editorBox.append(historyBox)

    _container.append(_editorBox)

    updateDisplay()
  }

  setupEventHandler() {
    // Spawn a fiber to handle keyboard events
    Window.spawn {
      while (true) {
        var event = Window.waitForEvent("keypress")
        handleKey(event["key"])
      }
    }
  }

  handleKey(key) {
    if (key == "Enter") {
      submit()
    } else if (key == "Escape") {
      clear()
    } else if (key == "Backspace") {
      backspace()
    } else if (key == "Delete") {
      delete()
    } else if (key == "Left" || key == "ArrowLeft") {
      moveLeft()
    } else if (key == "Right" || key == "ArrowRight") {
      moveRight()
    } else if (key == "Up" || key == "ArrowUp") {
      historyPrev()
    } else if (key == "Down" || key == "ArrowDown") {
      historyNext()
    } else if (key == "Home") {
      moveHome()
    } else if (key == "End") {
      moveEnd()
    } else if (key == "Ctrl+A") {
      moveHome()
    } else if (key == "Ctrl+E") {
      moveEnd()
    } else if (key == "Ctrl+K") {
      killToEnd()
    } else if (key.count == 1) {
      // Single character input
      insert(key)
    }
  }

  // Text manipulation methods
  insert(char) {
    if (_cursor == _buffer.count) {
      _buffer = _buffer + char
    } else {
      var before = _buffer[0..._cursor]
      var after = _buffer[_cursor..-1]
      _buffer = before + char + after
    }
    _cursor = _cursor + 1
    updateDisplay()
  }

  backspace() {
    if (_cursor > 0) {
      var before = _buffer[0...(_cursor - 1)]
      var after = _buffer[_cursor..-1]
      _buffer = before + after
      _cursor = _cursor - 1
      updateDisplay()
    }
  }

  delete() {
    if (_cursor < _buffer.count) {
      var before = _buffer[0..._cursor]
      var after = _buffer[(_cursor + 1)..-1]
      _buffer = before + after
      updateDisplay()
    }
  }

  killToEnd() {
    if (_cursor < _buffer.count) {
      _buffer = _buffer[0..._cursor]
      updateDisplay()
    }
  }

  // Cursor movement
  moveLeft() {
    if (_cursor > 0) {
      _cursor = _cursor - 1
      updateDisplay()
    }
  }

  moveRight() {
    if (_cursor < _buffer.count) {
      _cursor = _cursor + 1
      updateDisplay()
    }
  }

  moveHome() {
    _cursor = 0
    updateDisplay()
  }

  moveEnd() {
    _cursor = _buffer.count
    updateDisplay()
  }

  // History navigation
  historyPrev() {
    if (_history.isEmpty) return

    if (_historyIndex == null) {
      _historyIndex = _history.count - 1
    } else if (_historyIndex > 0) {
      _historyIndex = _historyIndex - 1
    } else {
      return
    }

    _buffer = _history[_historyIndex]
    _cursor = _buffer.count
    updateDisplay()
  }

  historyNext() {
    if (_history.isEmpty || _historyIndex == null) return

    if (_historyIndex < _history.count - 1) {
      _historyIndex = _historyIndex + 1
      _buffer = _history[_historyIndex]
      _cursor = _buffer.count
    } else {
      _historyIndex = null
      clear()
    }
    updateDisplay()
  }

  // Submit and clear
  submit() {
    if (_buffer != "" && (_history.isEmpty || _history[-1] != _buffer)) {
      _history.add(_buffer)

      // Add submitted text to display
      var submittedBox = _document.createElement("text-green-500 mt-1")
      var submittedText = _document.createText("Submitted: " + _buffer)
      submittedBox.append(submittedText)
      _editorBox.append(submittedBox)
    }
    _buffer = ""
    _cursor = 0
    _historyIndex = null
    updateDisplay()
  }

  clear() {
    _buffer = ""
    _cursor = 0
    _historyIndex = null
    updateDisplay()
  }

  // Optimized display update - updates existing DOM elements
  updateDisplay() {
    // Update text before cursor
    var beforeStr = (_cursor > 0) ? _buffer[0..._cursor] : ""
    _beforeText.updateText(beforeStr)

    // Update cursor character
    var cursorChar = (_cursor < _buffer.count) ? _buffer[_cursor] : " "
    _cursorText.updateText(cursorChar)

    // Update text after cursor
    var afterStr = (_cursor < _buffer.count - 1) ? _buffer[(_cursor + 1)..-1] : ""
    _afterText.updateText(afterStr)

    // Update status line
    var status = "Ready | Cursor: %(_cursor) | Length: %(_buffer.count)"
    if (_historyIndex != null) {
      status = status + " | History: %(_historyIndex + 1)/%(_history.count)"
    }
    _statusText.updateText(status)
  }
}

// Initialize editor when DOM is ready
Window.immediately {
  System.print("Starting XTC Editor Demo")
  var container = Document.getElementById("editor")
  if (container == null) {
    System.print("Error: Could not find editor element")
  } else {
    var editor = Editor.new(container)
    while (true) {
      Window.waitForNextFrame()
      editor.updateDisplay()
    }
  }
}