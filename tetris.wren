// Tetris Game Module
// Create document instance
var document = Document.new()

// Internal game classes (module-scoped)
class Piece {
  construct new(shape, color) {
    _shape = shape
    _color = color
  }

  shape { _shape }
  color { _color }

  rotate() {
    var rotated = []
    var rows = _shape.count
    var cols = _shape[0].count
    for (c in 0...cols) {
      var newRow = []
      for (r in (rows - 1)..0) {
        newRow.add(_shape[r][c])
      }
      rotated.add(newRow)
    }
    _shape = rotated
  }

  clone() {
    var newShape = []
    for (row in _shape) {
      var newRow = []
      for (cell in row) {
        newRow.add(cell)
      }
      newShape.add(newRow)
    }
    return Piece.new(newShape, _color)
  }
}

class Board {
  construct new(width, height) {
    _width = width
    _height = height
    _grid = []

    for (y in 0...height) {
      var row = []
      for (x in 0...width) {
        row.add(0)
      }
      _grid.add(row)
    }
  }

  width { _width }
  height { _height }

  isValidPosition(piece, px, py) {
    for (y in 0...piece.shape.count) {
      for (x in 0...piece.shape[y].count) {
        if (piece.shape[y][x] != 0) {
          var boardX = px + x
          var boardY = py + y

          if (boardX < 0 || boardX >= _width) return false
          if (boardY < 0 || boardY >= _height) return false
          if (_grid[boardY][boardX] != 0) return false
        }
      }
    }
    return true
  }

  placePiece(piece, px, py) {
    for (y in 0...piece.shape.count) {
      for (x in 0...piece.shape[y].count) {
        if (piece.shape[y][x] != 0) {
          _grid[py + y][px + x] = piece.shape[y][x]
        }
      }
    }
  }

  clearLines() {
    var linesCleared = 0
    var y = _height - 1

    while (y >= 0) {
      var complete = true
      for (x in 0..._width) {
        if (_grid[y][x] == 0) {
          complete = false
          break
        }
      }

      if (complete) {
        _grid.removeAt(y)
        var emptyRow = []
        for (x in 0..._width) {
          emptyRow.add(0)
        }
        _grid.insert(0, emptyRow)
        linesCleared = linesCleared + 1
      } else {
        y = y - 1
      }
    }

    return linesCleared
  }

  reset() {
    for (y in 0..._height) {
      for (x in 0..._width) {
        _grid[y][x] = 0
      }
    }
  }

  getDisplayGrid(currentPiece, px, py) {
    var display = []
    for (row in _grid) {
      var newRow = []
      for (cell in row) {
        newRow.add(cell)
      }
      display.add(newRow)
    }

    if (currentPiece != null) {
      for (y in 0...currentPiece.shape.count) {
        for (x in 0...currentPiece.shape[y].count) {
          if (currentPiece.shape[y][x] != 0) {
            var boardY = py + y
            var boardX = px + x
            if (boardY >= 0 && boardY < _height && boardX >= 0 && boardX < _width) {
              display[boardY][boardX] = currentPiece.shape[y][x]
            }
          }
        }
      }
    }

    return display
  }
}

class TetrisGame {
  construct new(container, doc) {
    _container = container
    _document = doc
    _board = Board.new(10, 20)
    _score = 0
    _gameOver = false
    _currentPiece = null
    _currentX = 0
    _currentY = 0

    _pieces = [
      Piece.new([[1, 1, 1, 1]], 1),  // I
      Piece.new([[2, 2], [2, 2]], 2),  // O
      Piece.new([[0, 3, 0], [3, 3, 3]], 3),  // T
      Piece.new([[0, 4, 4], [4, 4, 0]], 4),  // S
      Piece.new([[5, 5, 0], [0, 5, 5]], 5),  // Z
      Piece.new([[6, 0, 0], [6, 6, 6]], 6),  // J
      Piece.new([[0, 0, 7], [7, 7, 7]], 7)  // L
    ]

    _colors = [
      "bg-gray-800",   // empty
      "bg-cyan-500",   // I
      "bg-yellow-500", // O
      "bg-purple-500", // T
      "bg-green-500",  // S
      "bg-red-500",    // Z
      "bg-blue-500",   // J
      "bg-orange-500"  // L
    ]
  }

  start() {
    spawnPiece()
    updateDisplay()
  }

  spawnPiece() {
    var pieceIndex = (System.clock * 1000).floor % _pieces.count
    _currentPiece = _pieces[pieceIndex].clone()
    _currentX = ((_board.width - _currentPiece.shape[0].count) / 2).floor
    _currentY = 0

    if (!_board.isValidPosition(_currentPiece, _currentX, _currentY)) {
      _gameOver = true
    }
  }

  movePiece(dx, dy) {
    if (_gameOver) return false

    if (_board.isValidPosition(_currentPiece, _currentX + dx, _currentY + dy)) {
      _currentX = _currentX + dx
      _currentY = _currentY + dy
      updateDisplay()
      return true
    }
    return false
  }

  rotatePiece() {
    if (_gameOver) return

    var testPiece = _currentPiece.clone()
    testPiece.rotate()

    if (_board.isValidPosition(testPiece, _currentX, _currentY)) {
      _currentPiece = testPiece
      updateDisplay()
    }
  }

  dropPiece() {
    if (!movePiece(0, 1)) {
      _board.placePiece(_currentPiece, _currentX, _currentY)
      var lines = _board.clearLines()
      _score = _score + lines * 100
      spawnPiece()
      updateDisplay()
    }
  }

  hardDrop() {
    while (movePiece(0, 1)) {
      // Keep dropping
    }
    dropPiece()
  }

  reset() {
    _gameOver = false
    _score = 0
    _board.reset()
    spawnPiece()
    updateDisplay()
  }

  updateDisplay() {
    // Clear container
    while (_container.childCount > 0) {
      var child = _container.firstChild
      if (child != null) {
        _container.removeChild(child)
      }
    }

    // Create game container
    var gameBox = _document.createElement("flex flex-col")

    // Score display
    var scoreBox = _document.createElement("bg-gray-900 text-white p-2 mb-2")
    var scoreText = _document.createText("Score: " + _score.toString)
    scoreBox.append(scoreText)
    gameBox.append(scoreBox)

    // Get display grid
    var displayGrid = _board.getDisplayGrid(_currentPiece, _currentX, _currentY)

    // Render board
    for (y in 0..._board.height) {
      var rowBox = _document.createElement("flex flex-row")
      for (x in 0..._board.width) {
        var cellValue = displayGrid[y][x]
        var cellColor = _colors[cellValue]
        var cellBox = _document.createElement("w-2 h-1 border border-gray-700 " + cellColor)
        var cellText = _document.createText(cellValue == 0 ? " " : "█")
        cellBox.append(cellText)
        rowBox.append(cellBox)
      }
      gameBox.append(rowBox)
    }

    // Controls info
    var controlsBox = _document.createElement("bg-gray-900 text-white p-2 mt-2")
    var controlsText = _document.createText("A/D: Move  W: Rotate  S: Drop  Space: Hard Drop  R: Reset")
    controlsBox.append(controlsText)
    gameBox.append(controlsBox)

    // Game over message
    if (_gameOver) {
      var gameOverBox = _document.createElement("bg-red-600 text-white p-2 mt-2")
      var gameOverText = _document.createText("GAME OVER! Press R to restart")
      gameOverBox.append(gameOverText)
      gameBox.append(gameOverBox)
    }

    _container.append(gameBox)
  }

  handleKey(key) {
    if (key == "a" || key == "A") {
      movePiece(-1, 0)
    } else if (key == "d" || key == "D") {
      movePiece(1, 0)
    } else if (key == "s" || key == "S") {
      dropPiece()
    } else if (key == "w" || key == "W") {
      rotatePiece()
    } else if (key == " ") {
      hardDrop()
    } else if (key == "r" || key == "R") {
      reset()
    }
  }
}

// Main script execution
var container = document.getElementById("game-board")
if (container == null) {
  System.print("Error: Could not find game-board element")
} else {
  var game = TetrisGame.new(container, document)
  
  document.addEventListener("keypress", Fn.new { |event|
    if (game != null) {
      game.handleKey(event["key"])
    }
  })
  
  game.start()
}