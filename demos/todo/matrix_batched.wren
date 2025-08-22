// Matrix-style digital rain with batched DOM updates via ring system
import "dom" for Window, Document, Element

// Generated DOM request classes (would normally be auto-generated)
class Request {
  // Base class for all DOM requests
  construct new() {}
  
  // Submit this request to the ring and yield
  submit() {
    ring.post(this)
    ring.flush()
    ring.wait(1)
    return ring.reap(1)
  }
}

class updateTextRequest is Request {
  static id { 0 }
  construct new(nodeId, text) {
    super()
    _nodeId = nodeId
    _text = text
  }
  nodeId { _nodeId }
  text { _text }
}

class updateClassRequest is Request {
  static id { 1 }
  construct new(nodeId, className) {
    super()
    _nodeId = nodeId
    _className = className
  }
  nodeId { _nodeId }
  className { _className }
}

class BatchedMatrixDemo {
  construct new(container) {
    _container = container
    _document = Document
    _width = Document.width
    _height = Document.height
    _columns = []
    _cellNodeIds = [] // Store node IDs for batched updates

    setupDOM()
    animate()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col items-center justify-center bg-black text-green-400")

    // Grid container
    var grid = _document.createElement("flex flex-col")

    // Build rows with characters and store node IDs
    _cellNodeIds = []
    for (y in 0..._height) {
      var row = _document.createElement("flex flex-row h-1")
      var rowIds = []
      for (x in 0..._width) {
        var cell = _document.createElement("w-1 h-1")
        var text = _document.createText(" ")
        cell.append(text)
        row.append(cell)
        
        // Store the node IDs for batched updates
        rowIds.add([cell.id, text.id])
      }
      _cellNodeIds.add(rowIds)
      grid.append(row)
    }

    main.append(grid)

    // Per-column state (same as original)
    var startTime = System.clock
    for (x in 0..._width) {
      _columns.add({
        "head": -((x * 7 + (x * x * 3)) % (_height + 10)),
        "speed": 1 + ((x * 931 + startTime.floor) % 3),
        "density": 4 + ((x * 11) % 4),
        "burst": (x * 17) % 23 == 0,
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

      // Collect ALL DOM updates for this frame in a batch
      var domUpdates = []

      for (x in 0..._width) {
        var col = _columns[x]
        updateColumnBatched(x, frameCount, currentTime, domUpdates)
      }

      // Submit entire frame as single batch - HUGE performance improvement!
      System.print("Batching %(domUpdates.count) DOM operations in single ring submission")
      if (domUpdates.count > 0) {
        ring.submitAndWait(domUpdates)
      }

      frameCount = frameCount + 1
      Window.waitForNextFrame()
    }
  }

  updateColumnBatched(x, frameCount, currentTime, domUpdates) {
    var col = _columns[x]

    // Same timing logic as original
    var deltaTime = currentTime - col["lastUpdate"]
    var updateInterval = 1.0 / col["fps"]

    if (deltaTime < updateInterval) {
      return
    }

    col["lastUpdate"] = currentTime
    col["head"] = col["head"] + col["speed"]
    
    if (col["head"] >= _height + 15) {
      col["head"] = -((x * 7) % 10)
      col["speed"] = 1 + ((currentTime.floor * 13 + x * 17) % 3)
      col["density"] = 4 + ((currentTime.floor * 7 + x * 11) % 4)
      col["burst"] = ((currentTime.floor + x) % 19) == 0
      col["fps"] = 20 + ((currentTime.floor * 23 + x) % 20)
    }

    // Draw the trail - but collect updates instead of applying immediately
    var trailLen = col["burst"] ? 15 : 8 + ((x * 3) % 5)

    for (y in 0..._height) {
      var distance = col["head"] - y
      var cellNodeId = _cellNodeIds[y][x][0] // Cell element ID
      var textNodeId = _cellNodeIds[y][x][1] // Text element ID

      if (distance < 0 || distance >= trailLen) {
        // Clear cells outside the trail - ADD TO BATCH
        domUpdates.add(updateTextRequest.new(textNodeId, " "))
        domUpdates.add(updateClassRequest.new(cellNodeId, "w-1 h-1"))
      } else {
        // Random chance to skip (create gaps in trail)
        if (distance > 3 && ((x * 29 + y * 31 + col["head"]) % col["density"]) == 0) {
          domUpdates.add(updateTextRequest.new(textNodeId, " "))
          domUpdates.add(updateClassRequest.new(cellNodeId, "w-1 h-1"))
          continue
        }

        // Character selection
        var charset = ["ｱ","ｲ","ｳ","ｴ","ｵ","ｶ","ｷ","ｸ","ｹ","ｺ","ｻ","ｼ","ｽ","ｾ","ｿ","ﾀ","ﾁ","ﾂ","ﾃ","ﾄ","ﾅ","ﾆ","ﾇ","ﾈ","ﾉ","ﾊ","ﾋ","ﾌ","ﾍ","ﾎ","ﾏ","ﾐ","ﾑ","ﾒ","ﾓ","ﾔ","ﾕ","ﾖ","ﾗ","ﾘ","ﾙ","ﾚ","ﾛ","ﾜ","ｦ","ﾝ"]
        var ch = charset[(col["head"] + x * 13 + y * 7) % charset.count]

        // Color based on position in trail
        var cls = ""
        if (distance == 0) {
          cls = "w-1 h-1 text-white"
        } else if (distance < 2) {
          cls = "w-1 h-1 text-green-200"
        } else if (distance < 4) {
          cls = "w-1 h-1 text-green-400"
        } else if (distance < 7) {
          cls = "w-1 h-1 text-green-500"
        } else if (distance < 10) {
          cls = "w-1 h-1 text-green-700"
        } else {
          cls = "w-1 h-1 text-green-800"
        }

        // ADD TO BATCH instead of immediate update
        domUpdates.add(updateTextRequest.new(textNodeId, ch))
        domUpdates.add(updateClassRequest.new(cellNodeId, cls))
      }
    }
  }
}

Window.immediately {
  var container = Document.getElementById("matrix")
  if (container) {
    System.print("🚀 Starting BATCHED Matrix Demo - expect major performance improvements!")
    BatchedMatrixDemo.new(container)
  }
}