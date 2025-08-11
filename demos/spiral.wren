// Spiral animation using sine/cosine field and color cycling
import "dom" for Document, Element

class Spiral {
  construct new(container) {
    _container = container
    _document = Document
    _w = _document.width
    _h = _document.height - 2
    if (_h < 1) _h = 1
    if (_w < 1) _w = 1
    _cells = []    // 2D: [[cellElem, textNode]]
    _rows = []     // row Element per y
    _main = null   // root Element for this demo
    setupDOM()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col items-center justify-center bg-gray-950 text-gray-300")
    _main = main
    var title = _document.createElement("text-center text-pink-300 mb-1")
    title.append(_document.createText("Spiral"))
    main.append(title)

    // grid
    for (y in 0...(_h)) {
      var row = _document.createElement("flex flex-row")
      var rowCells = []
      for (x in 0...(_w)) {
        var cell = _document.createElement("w-1 h-1")
        var txt = _document.createText(" ")
        cell.append(txt)
        row.append(cell)
        rowCells.add([cell, txt])
      }
      main.append(row)
      _rows.add(row)
      _cells.add(rowCells)
    }

    var clk = _document.createClock("clock fps-45 clock-hidden")
    clk.addEventListener("tick", Fn.new { |t| animate(t["tick"]) })
    main.append(clk)

    _container.append(main)
  }

  animate(frame) {
    // Resize grid to match viewport if it changed
    resizeIfNeeded()

    var cx = _w / 2
    var cy = _h / 2
    var time = frame * 0.1
    for (y in 0..._h) {
      for (x in 0..._w) {
        var dx = x - cx
        var dy = y - cy
        var r = (dx*dx + dy*dy).sqrt
        var a = (dy.atan(dx) + time)
        var v = (a.sin + a.cos + (r * 0.1).sin).abs
        var idx = ((v * 9).floor) % 10
        var chars = [" ",".","·","*","o","O","@","#","\%","█"]
        var colors = ["text-gray-800","text-gray-700","text-gray-600","text-blue-400","text-cyan-400","text-green-400","text-yellow-400","text-orange-400","text-pink-400","text-white"]
        _cells[y][x][1].updateText(chars[idx])
        _cells[y][x][0].updateClass("w-1 h-1 " + colors[idx])
      }
    }
  }

  resizeIfNeeded() {
    var target_w = _document.width
    var target_h = _document.height - 2
    if (target_w < 1) target_w = 1
    if (target_h < 1) target_h = 1

    if (target_w == _w && target_h == _h) return

    // Adjust rows
    if (target_h > _h) {
      // Add rows
      for (y in _h...target_h) {
        var row = _document.createElement("flex flex-row")
        var rowCells = []
        for (x in 0..._w) {
          var cell = _document.createElement("w-1 h-1")
          var txt = _document.createText(" ")
          cell.append(txt)
          row.append(cell)
          rowCells.add([cell, txt])
        }
        _main.append(row)
        _rows.add(row)
        _cells.add(rowCells)
      }
    } else if (target_h < _h) {
      // Remove rows from end
      for (y in (target_h ... _h)) {
        var idx = _h - 1 - (y - target_h)
        var rowElem = _rows[idx]
        _main.removeChild(rowElem)
        _rows.removeAt(idx)
        _cells.removeAt(idx)
      }
    }

    // Adjust columns for each row
    if (target_w != _w) {
      for (y in 0..._rows.count) {
        var row = _rows[y]
        var rowCells = _cells[y]
        if (target_w > _w) {
          // Add cells
          for (x in _w...target_w) {
            var cell = _document.createElement("w-1 h-1")
            var txt = _document.createText(" ")
            cell.append(txt)
            row.append(cell)
            rowCells.add([cell, txt])
          }
        } else {
          // Remove cells from end
          for (x in (target_w ... _w)) {
            var idx = _w - 1 - (x - target_w)
            row.removeChild(rowCells[idx][0])
            rowCells.removeAt(idx)
          }
        }
        _cells[y] = rowCells
      }
    }

    _w = target_w
    _h = target_h
  }
}

var container = Document.getElementById("spiral")
if (container) {
  Spiral.new(container)
}


