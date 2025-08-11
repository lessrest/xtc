// Matrix-style digital rain with per-column clocks
var document = Document.new()

class MatrixDemo {
  construct new(container, doc) {
    _container = container
    _document = doc
    // Use terminal viewport if available
    _width = _document.width
    _height = _document.height - 3 // leave room for title/info
    _columns = []

    setupDOM()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col items-center justify-center bg-black text-green-400")
    var title = _document.createElement("text-green-300 mb-1")
    title.append(_document.createText("Matrix Rain"))
    main.append(title)

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
        "head": (-(x * 3) % _height),
        // Randomize speed 1..3 with per-column jitter
        "speed": 1 + ((x * 931 + System.clock.floor) % 3),
        // Random per-column density (how often blanks appear)
        "density": 3 + ((x * 57) % 6),
        // Occasional long bursts
        "burst": (x * 17) % 23 == 0,
      })

      var clk = _document.createClock("clock fps-30 clock-hidden")
      clk.addEventListener("tick", Fn.new { |tick|
        updateColumn(x)
      })
      main.append(clk)
    }

    // Legend
    var info = _document.createElement("text-green-700 text-xs mt-1")
    info.append(_document.createText("Q to quit"))
    main.append(info)

    _container.append(main)
  }

  updateColumn(x) {
    var col = _columns[x]
    col["head"] = (col["head"] + col["speed"]) % _height

    // Fade entire column
    for (y in 0..._height) {
      _cells[y][x][1].updateText(" ")
      _cells[y][x][0].updateClass("w-1 h-1 text-green-700")
    }

    // Draw a variable trail
    var trailLen = col["burst"] ? 10 : 4 + ((x + col["head"]) % 4)
    for (t in 0...trailLen) {
      var y = (col["head"] - t)
      while (y < 0) y = y + _height
      if (y >= 0 && y < _height) {
        // Random blanks to create gaps
        if (((x * 131 + y * 97 + t * 17) % col["density"]) == 0 && t > 2) {
          _cells[y][x][1].updateText(" ")
          continue
        }
        var charset = ["ｱ","ｶ","ｻ","ﾀ","ﾅ","ﾊ","ﾏ","ﾔ","ﾗ","ﾜ","0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F"]
        var ch = charset[(_height + x + y + t + System.clock.floor) % charset.count]
        _cells[y][x][1].updateText(ch)
        var cls = (t == 0) ? "text-white" : (t < 3) ? "text-green-300" : (t < 6) ? "text-green-500" : "text-green-700"
        _cells[y][x][0].updateClass("w-1 h-1 " + cls)
      }
    }
  }
}

var container = document.getElementById("matrix")
if (container) {
  MatrixDemo.new(container, document)
}


