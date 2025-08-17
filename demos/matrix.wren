// Matrix-style digital rain with per-column clocks
import "dom" for Document, Element

class MatrixDemo {
  construct new(container) {
    _container = container
    _document = Document
    // Use terminal viewport if available
    _width = _document.width
    _height = _document.height
    _columns = []

    setupDOM()
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

    // Per-column state and clocks
    for (x in 0..._width) {
      _columns.add({
        "head": -((x * 7 + (x * x * 3)) % (_height + 10)), // More varied starting positions
        // Randomize speed 1..3 with per-column jitter
        "speed": 1 + ((x * 931 + System.clock.floor) % 3),
        // Random per-column density (how often blanks appear)
        "density": 4 + ((x * 11) % 4),
        // Occasional long bursts
        "burst": (x * 17) % 23 == 0,
      })

      // Stagger the clock updates across columns for more organic movement
      var fps = 10 + (x % 20)
      var clk = _document.createClock("clock fps-" + fps.toString + " clock-hidden")
      clk.addEventListener("tick", Fn.new { |tick|
        updateColumn(x)
      })
      main.append(clk)
    }

    _container.append(main)
  }

  updateColumn(x) {
    var col = _columns[x]

    // Update position more smoothly
    col["head"] = col["head"] + 1
    if (col["head"] >= _height + 15) {
      col["head"] = -((x * 7) % 10) // Random restart position
      // Randomize parameters on restart
      col["speed"] = 1 + ((System.clock * 13 + x * 17) % 3)
      col["density"] = 4 + ((System.clock * 7 + x * 11) % 4)
      col["burst"] = ((System.clock + x) % 19) == 0
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
          cls = "w-1 h-1 text-green-300" // Bright green
        } else if (distance < 7) {
          cls = "w-1 h-1 text-green-400" // Medium green
        } else if (distance < 10) {
          cls = "w-1 h-1 text-green-500" // Darker green
        } else {
          cls = "w-1 h-1 text-green-600" // Darkest green in trail
        }
        _cells[y][x][0].updateClass(cls)
      }
    }
  }
}

var container = Document.getElementById("matrix")
if (container) {
  MatrixDemo.new(container)
}


