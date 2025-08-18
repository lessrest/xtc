// Text Editor component for XTC written in Wren
// Provides line editing functionality with history and cursor management

import "dom" for Window, Document

class Editor {
  construct new(container) {
    _container = container
    _buffer = ""
    _cursor = 0
    _history = []
    _historyIndex = null

    // Create editor UI structure
    _editorBox = Document.createElement("flex flex-col")
    _container.append(_editorBox)

    // Text display with cursor
    _textLine = Document.createElement("flex")
    _editorBox.append(_textLine)

    updateDisplay
  }

  // Public API
  buffer {
    return _buffer
  }
  cursor {
    return _cursor
  }

  clear {
    // No parameters version
    _buffer = ""
    _cursor = 0
    _historyIndex = null
    updateDisplay
  }

  setText(text) {
    // Set text with parameter
    _buffer = text
    _cursor = text.count
    updateDisplay
  }

  // Character insertion
  insert(char) {
    // Insert character
    if (_cursor == _buffer.count) {
      _buffer = _buffer + char
    } else {
      var before = _buffer[0..._cursor]
      var after = _buffer[_cursor..-1]
      _buffer = before + char + after
    }
    _cursor = _cursor + 1
    updateDisplay
  }

  insertText(text) {
    // Insert text string
    for (char in text) {
      insert(char)
    }
  }

  // Deletion operations
  backspace {
    // Delete backwards
    if (_cursor > 0) {
      var before = _buffer[0...(_cursor - 1)]
      var after = _buffer[_cursor..-1]
      _buffer = before + after
      _cursor = _cursor - 1
      updateDisplay
    }
  }

  delete {
    // Delete forwards
    if (_cursor < _buffer.count) {
      var before = _buffer[0..._cursor]
      var after = _buffer[(_cursor + 1)..-1]
      _buffer = before + after
      updateDisplay
    }
  }

  killToEnd {
    // Kill to end of line
    if (_cursor < _buffer.count) {
      _buffer = _buffer[0..._cursor]
      updateDisplay
    }
  }

  // Cursor movement
  moveLeft {
    // Move cursor left
    if (_cursor > 0) {
      _cursor = _cursor - 1
      updateDisplay
    }
  }

  moveRight {
    // Move cursor right
    if (_cursor < _buffer.count) {
      _cursor = _cursor + 1
      updateDisplay
    }
  }

  moveHome {
    // Move to start
    _cursor = 0
    updateDisplay
  }

  moveEnd {
    // Move to end
    _cursor = _buffer.count
    updateDisplay
  }

  // History navigation
  addToHistory(line) {
    if (line != "" && (_history.isEmpty || _history[-1] != line)) {
      _history.add(line)
    }
    _historyIndex = null
  }

  historyPrev {
    // Previous history
    if (_history.isEmpty) return

    if (_historyIndex == null) {
      _historyIndex = _history.count - 1
    } else if (_historyIndex > 0) {
      _historyIndex = _historyIndex - 1
    } else {
      return
    }

    setText(_history[_historyIndex])
  }

  historyNext {
    // Next history
    if (_history.isEmpty || _historyIndex == null) return

    if (_historyIndex < _history.count - 1) {
      _historyIndex = _historyIndex + 1
      setText(_history[_historyIndex])
    } else {
      _historyIndex = null
      clear
    }
  }

  // Submit/cancel
  submit {
    // Submit and return buffer
    var result = _buffer
    addToHistory(result)
    clear
    return result
  }

  cancel {
    // Cancel and clear
    clear
    return null
  }

  // Display update
  updateDisplay {
    // Update display
    // Clear text line
    while (_textLine.childCount > 0) {
      var child = _textLine.firstChild
      if (child) _textLine.removeChild(child)
    }

    // Build display with cursor visualization
    if (_buffer.isEmpty) {
      // Just show cursor
      var cursorEl = Document.createElement("bg-blue-500 text-white")
      var cursorText = Document.createText(" ")
      cursorEl.append(cursorText)
      _textLine.append(cursorEl)
    } else {
      // Text before cursor
      if (_cursor > 0) {
        var beforeText = Document.createText(_buffer[0..._cursor])
        _textLine.append(beforeText)
      }

      // Cursor position
      var cursorEl = Document.createElement("bg-blue-500 text-white")
      var cursorChar = (_cursor < _buffer.count) ? _buffer[_cursor] : " "
      var cursorText = Document.createText(cursorChar)
      cursorEl.append(cursorText)
      _textLine.append(cursorEl)

      // Text after cursor
      if (_cursor < _buffer.count - 1) {
        var afterText = Document.createText(_buffer[(_cursor + 1)..-1])
        _textLine.append(afterText)
      }
    }
  }

  // Key handling
  handleKey(key) {
    if (key == "Enter") {
      return submit
    } else if (key == "Escape") {
      return cancel
    } else if (key == "Backspace") {
      backspace
    } else if (key == "Delete") {
      delete
    } else if (key == "Left") {
      moveLeft
    } else if (key == "Right") {
      moveRight
    } else if (key == "Up") {
      historyPrev
    } else if (key == "Down") {
      historyNext
    } else if (key == "Home") {
      moveHome
    } else if (key == "End") {
      moveEnd
    } else if (key == "Ctrl+A") {
      moveHome
    } else if (key == "Ctrl+E") {
      moveEnd
    } else if (key == "Ctrl+K") {
      killToEnd
    } else if (key.count == 1) {
      // Single character input
      insert(key)
    }
    return null
  }
}

// Export for use in scripts
class EditorComponent {
  static create(container) {
    return Editor.new(container)
  }
}
