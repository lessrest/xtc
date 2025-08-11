// Simple Tetris - moves DOM nodes instead of recreating them
import "dom" for Document, Element

// Constants
var BOARD_WIDTH = 10
var BOARD_HEIGHT = 20
var COLORS = [
  "",              // 0: empty
  "bg-cyan-500",   // 1: I
  "bg-yellow-500", // 2: O  
  "bg-purple-500", // 3: T
  "bg-green-500",  // 4: S
  "bg-red-500",    // 5: Z
  "bg-blue-500",   // 6: J
  "bg-orange-500"  // 7: L
]

var PIECES = [
  [[1, 1, 1, 1]],                      // I
  [[2, 2], [2, 2]],                    // O
  [[0, 3, 0], [3, 3, 3]],              // T
  [[0, 4, 4], [4, 4, 0]],              // S
  [[5, 5, 0], [0, 5, 5]],              // Z
  [[6, 0, 0], [6, 6, 6]],              // J
  [[0, 0, 7], [7, 7, 7]]               // L
]

class SimpleTetris {
  construct new(container) {
    _container = container
    _board = List.filled(BOARD_HEIGHT, null)
    for (y in 0...BOARD_HEIGHT) {
      _board[y] = List.filled(BOARD_WIDTH, 0)
    }
    
    _score = 0
    _gameOver = false
    _currentPiece = null
    _currentShape = null
    _currentX = 0
    _currentY = 0
    _currentType = 0
    
    // Create persistent DOM structure
    _scoreText = null
    _boardCells = []
    _gameOverBox = null
    _gameOverText = null
    
    setupDOM()
  }
  
  setupDOM() {
    // Create main container
    var gameBox = Document.createElement("flex flex-col p-2")
    
    // Score display
    var scoreBox = Document.createElement("bg-gray-900 text-white p-2 mb-2")
    _scoreText = Document.createText("Score: 0")
    scoreBox.append(_scoreText)
    gameBox.append(scoreBox)
    
    // Create board grid
    var boardBox = Document.createElement("flex flex-col border-2 border-gray-700")
    for (y in 0...BOARD_HEIGHT) {
      var row = Document.createElement("flex flex-row")
      var rowCells = []
      for (x in 0...BOARD_WIDTH) {
        var cell = Document.createElement("w-2 h-1 bg-gray-900")
        row.append(cell)
        rowCells.add(cell)
      }
      boardBox.append(row)
      _boardCells.add(rowCells)
    }
    gameBox.append(boardBox)
    
    // Controls hint
    var controlsBox = Document.createElement("text-gray-400 text-xs mt-2")
    var controlsText = Document.createText("A/D: Move  W: Rotate  S: Drop  Space: Hard  R: Reset")
    controlsBox.append(controlsText)
    gameBox.append(controlsBox)
    
    // Hidden game over message (empty initially)
    _gameOverBox = Document.createElement("")
    _gameOverText = Document.createText("")
    _gameOverBox.append(_gameOverText)
    gameBox.append(_gameOverBox)
    
    _container.append(gameBox)
  }
  
  start() {
    spawnPiece()
    updateBoard()
  }
  
  spawnPiece() {
    var pieceIndex = (System.clock * 1000).floor % PIECES.count
    _currentShape = PIECES[pieceIndex]
    _currentType = pieceIndex + 1
    _currentX = ((BOARD_WIDTH - _currentShape[0].count) / 2).floor
    _currentY = 0
    
    // Check if game over
    if (!canPlace(_currentShape, _currentX, _currentY)) {
      _gameOver = true
      // Show game over message
      _gameOverBox.updateClass("bg-red-600 text-white p-2 mt-2")
      _gameOverText.updateText("GAME OVER! Press R to restart")
    }
  }
  
  canPlace(shape, px, py) {
    for (y in 0...shape.count) {
      for (x in 0...shape[y].count) {
        if (shape[y][x] != 0) {
          var boardX = px + x
          var boardY = py + y
          
          if (boardX < 0 || boardX >= BOARD_WIDTH) return false
          if (boardY < 0 || boardY >= BOARD_HEIGHT) return false
          if (_board[boardY][boardX] != 0) return false
        }
      }
    }
    return true
  }
  
  placePiece() {
    for (y in 0..._currentShape.count) {
      for (x in 0..._currentShape[y].count) {
        if (_currentShape[y][x] != 0) {
          _board[_currentY + y][_currentX + x] = _currentType
        }
      }
    }
  }
  
  clearLines() {
    var linesCleared = 0
    var y = BOARD_HEIGHT - 1
    
    while (y >= 0) {
      var complete = true
      for (x in 0...BOARD_WIDTH) {
        if (_board[y][x] == 0) {
          complete = false
          break
        }
      }
      
      if (complete) {
        // Move everything down
        for (moveY in y...1) {
          for (x in 0...BOARD_WIDTH) {
            _board[moveY][x] = _board[moveY - 1][x]
          }
        }
        // Clear top row
        for (x in 0...BOARD_WIDTH) {
          _board[0][x] = 0
        }
        linesCleared = linesCleared + 1
      } else {
        y = y - 1
      }
    }
    
    if (linesCleared > 0) {
      _score = _score + linesCleared * 100
      updateScore()
    }
  }
  
  updateScore() {
    // Update the text content directly
    _scoreText.updateText("Score: " + _score.toString)
  }
  
  updateBoard() {
    // Update board cells based on placed pieces
    for (y in 0...BOARD_HEIGHT) {
      for (x in 0...BOARD_WIDTH) {
        var value = _board[y][x]
        
        // Check if current piece overlaps this position
        if (_currentShape != null && !_gameOver) {
          for (py in 0..._currentShape.count) {
            for (px in 0..._currentShape[py].count) {
              if (_currentShape[py][px] != 0) {
                if (_currentY + py == y && _currentX + px == x) {
                  value = _currentType
                }
              }
            }
          }
        }
        
        // Update cell class
        var cellClass = "w-2 h-1 "
        if (value == 0) {
          cellClass = cellClass + "bg-gray-900"
        } else {
          cellClass = cellClass + COLORS[value]
        }
        _boardCells[y][x].updateClass(cellClass)
      }
    }
  }
  
  move(dx, dy) {
    if (_gameOver) return false
    
    if (canPlace(_currentShape, _currentX + dx, _currentY + dy)) {
      _currentX = _currentX + dx
      _currentY = _currentY + dy
      updateBoard()
      return true
    }
    return false
  }
  
  rotate() {
    if (_gameOver) return
    
    // Rotate shape 90 degrees
    var rotated = []
    var rows = _currentShape.count
    var cols = _currentShape[0].count
    
    for (c in 0...cols) {
      var newRow = []
      for (r in (rows - 1)...(-1)) {
        newRow.add(_currentShape[r][c])
      }
      rotated.add(newRow)
    }
    
    if (canPlace(rotated, _currentX, _currentY)) {
      _currentShape = rotated
      updateBoard()
    }
  }
  
  drop() {
    if (!move(0, 1)) {
      placePiece()
      clearLines()
      spawnPiece()
      updateBoard()
    }
  }
  
  hardDrop() {
    while (move(0, 1)) {
      // Keep moving down
    }
    drop()
  }
  
  reset() {
    // Clear board
    for (y in 0...BOARD_HEIGHT) {
      for (x in 0...BOARD_WIDTH) {
        _board[y][x] = 0
      }
    }
    
    _score = 0
    _gameOver = false
    updateScore()
    
    // Hide game over message
    _gameOverBox.updateClass("")
    _gameOverText.updateText("")
    
    spawnPiece()
    updateBoard()
  }
  
  handleKey(key) {
    if (key == "a" || key == "A") {
      move(-1, 0)
    } else if (key == "d" || key == "D") {
      move(1, 0)
    } else if (key == "s" || key == "S") {
      drop()
    } else if (key == "w" || key == "W") {
      rotate()
    } else if (key == " ") {
      hardDrop()
    } else if (key == "r" || key == "R") {
      reset()
    }
  }
}

// Main execution
var container = Document.getElementById("game-board")
if (container == null) {
  System.print("Error: Could not find game-board element")
} else {
  var game = SimpleTetris.new(container)
  
  Document.addEventListener("keypress", Fn.new { |event|
    if (game != null) {
      game.handleKey(event["key"])
    }
  })
  
  game.start()
}