// 10x5 grid of animated spinners, each with different FPS and phase
var document = Document.new()

class ClockGrid {
  construct new(container, doc) {
    _container = container
    _document = doc
    _cols = 10
    _rows = 5
    _cells = []
    setupDOM()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col items-center justify-center bg-gray-900 text-gray-300")
    var title = _document.createElement("text-center text-gray-400 mb-1")
    title.append(_document.createText("Clock Grid"))
    main.append(title)

    for (y in 0..._rows) {
      var row = _document.createElement("flex flex-row gap-1")
      var rowCells = []
      for (x in 0..._cols) {
        var cell = _document.createElement("w-3 h-1 items-center justify-center")
        var txt = _document.createText(" ")
        cell.append(txt)

        // Create a dedicated clock per cell
        var fps = 10 + (x * 3 + y * 5) % 40
        var clk = _document.createClock("clock fps-" + fps.toString + " clock-hidden")
        clk.addEventListener("tick", Fn.new { |e|
          var phase = (x * 7 + y * 13) % 10
          var idx = (e["tick"] + phase) % 10
          var frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
          txt.updateText(frames[idx])
        })

        row.append(cell)
        row.append(clk)
        rowCells.add([cell, txt])
      }
      main.append(row)
      _cells.add(rowCells)
    }

    _container.append(main)
  }
}

var container = document.getElementById("cgrid")
if (container) {
  ClockGrid.new(container, document)
}


