// Matrix-style digital rain with fiber-based animation
import "dom" for Window, Document, Element

class MatrixDemo {
  construct new(container) {
    _container = container
    _document = Document
    // Use terminal viewport if available
    _width = Document.width
    _height = Document.height
    _columns = []

    setupDOM()
    animate()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col items-center justify-center bg-black text-green-400")

    // Grid container
    var grid = _document.createElement("flex flex-col")

    // Build rows with characters
    _cells = []
    for (y in 0..._height) {
      var row = _document.createElement("flex flex-row h-1")
      var rowCells = []
      for (x in 0..._width) {
        var cell = _document.createElement("w-1 h-1")
        var text = _document.createText(" ")
        cell.append(text)
        row.append(cell)
        rowCells.add([cell, text])
      }
      _cells.add(rowCells)
      grid.append(row)
    }

    main.append(grid)

    // Per-column state
    var startTime = System.clock
    for (x in 0..._width) {
      _columns.add({
        "head": -((x * 7 + (x * x * 3)) % (_height + 10)), // More varied starting positions
        // Randomize speed 1..3 with per-column jitter
        "speed": 1 + ((x * 931 + startTime.floor) % 3),
        // Random per-column density (how often blanks appear)
        "density": 4 + ((x * 11) % 4),
        // Occasional long bursts
        "burst": (x * 17) % 23 == 0,
        // Individual column timing - stagger initial updates
        "lastUpdate": 0,
        "fps": 8 + ((x * 13) % 30),
      })
    }

    _container.append(main)
  }

  animate() {
    var frameCount = 0
    while (true) {
      var currentTime = System.clock

      for (x in 0..._width) {
        var col = _columns[x]
        updateColumn(x, frameCount, currentTime)
      }

      frameCount = frameCount + 1
      Window.waitForNextFrame()
    }
  }

  updateColumn(x, frameCount, currentTime) {
    var col = _columns[x]

    // Calculate time delta in seconds
    var deltaTime = currentTime - col["lastUpdate"]

    // Update based on column's individual FPS
    var updateInterval = 1.0 / col["fps"]

    // Only update if enough time has passed for this column's speed
    if (deltaTime < updateInterval) {
      return // Skip this column update
    }

    // Update timestamp
    col["lastUpdate"] = currentTime

    // Move based on speed (cells per update)
    col["head"] = col["head"] + col["speed"]
    if (col["head"] >= _height + 15) {
      col["head"] = -((x * 7) % 10) // Random restart position
      // Randomize parameters on restart
      col["speed"] = 1 + ((currentTime.floor * 13 + x * 17) % 3)
      col["density"] = 4 + ((currentTime.floor * 7 + x * 11) % 4)
      col["burst"] = ((currentTime.floor + x) % 19) == 0
      col["fps"] = 20 + ((currentTime.floor * 23 + x) % 20) // Randomize FPS too
    }

    // Draw the trail
    var trailLen = col["burst"] ? 15 : 8 + ((x * 3) % 5)

    for (y in 0..._height) {
      var distance = col["head"] - y

      if (distance < 0 || distance >= trailLen) {
        // Clear cells outside the trail
        _cells[y][x][1].updateText(" ")
        _cells[y][x][0].updateClass("w-1 h-1")
      } else {
        // Random chance to skip (create gaps in trail)
        if (distance > 3 && ((x * 29 + y * 31 + col["head"]) % col["density"]) == 0) {
          _cells[y][x][1].updateText(" ")
          _cells[y][x][0].updateClass("w-1 h-1")
          continue
        }

        // Character selection - change characters as they fall
        var charset = ["ｱ","ｲ","ｳ","ｴ","ｵ","ｶ","ｷ","ｸ","ｹ","ｺ","ｻ","ｼ","ｽ","ｾ","ｿ","ﾀ","ﾁ","ﾂ","ﾃ","ﾄ","ﾅ","ﾆ","ﾇ","ﾈ","ﾉ","ﾊ","ﾋ","ﾌ","ﾍ","ﾎ","ﾏ","ﾐ","ﾑ","ﾒ","ﾓ","ﾔ","ﾕ","ﾖ","ﾗ","ﾘ","ﾙ","ﾚ","ﾛ","ﾜ","ｦ","ﾝ"]
        var ch = charset[(col["head"] + x * 13 + y * 7) % charset.count]
        _cells[y][x][1].updateText(ch)

        // Color based on position in trail
        var cls = ""
        if (distance == 0) {
          cls = "w-1 h-1 text-white" // Leading character is white
        } else if (distance < 2) {
          cls = "w-1 h-1 text-green-200" // Very bright green
        } else if (distance < 4) {
          cls = "w-1 h-1 text-green-400" // Bright green
        } else if (distance < 7) {
          cls = "w-1 h-1 text-green-500" // Medium green
        } else if (distance < 10) {
          cls = "w-1 h-1 text-green-700" // Darker green
        } else {
          cls = "w-1 h-1 text-green-800" // Darkest green in trail
        }
        _cells[y][x][0].updateClass(cls)
      }
    }
  }
}

Window.immediately {
  var container = Document.getElementById("matrix")
  if (container) {
    MatrixDemo.new(container)
  }
}
