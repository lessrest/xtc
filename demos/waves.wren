// Beautiful combined wave, star, and particle animation
import "dom" for Window, Document, Element

class CombinedWaveAnimation {
  construct new(container) {
    _container = container
    _document = Document
    _frame = 0
    _rows = []
    _width = Document.width
    _height = Document.height - 1

    // FPS measurement
    _lastFrameTime = System.clock
    _frameCount = 0
    _fpsUpdateCount = 0
    _currentFps = 0

    // Wave parameters
    _amplitude = 5
    _frequency = 0.15
    _speed = 0.1

    // Color palette for gradient effect
    _colors = [
      "bg-blue-900",
      "bg-blue-800",
      "bg-blue-700",
      "bg-blue-600",
      "bg-cyan-600",
      "bg-cyan-500",
      "bg-cyan-400",
      "bg-cyan-300",
      "bg-blue-400",
      "bg-blue-500"
    ]

    // Characters for wave visualization
    _waveChars = ["░", "▒", "▓", "█", "▓", "▒", "░", " ", " ", " "]

    // Star system
    _stars = []
    for (i in 0...40) {
      _stars.add({
        "x": (System.clock * 1000 * (i + 1)).floor % _width,
        "y": (System.clock * 1000 * (i + 7)).floor % (_height - 8),
        "brightness": (i % 5) + 1,
        "twinklePhase": i * 0.5,
        "char": ["·", "✦", "★", "✧", "✨"][i % 5]
      })
    }

    // Particle system
    _particles = []
    for (i in 0...25) {
      _particles.add({
        "x": (System.clock * 1000 * (i + 3)).floor % _width,
        "y": (System.clock * 1000 * (i + 11)).floor % (_height - 5),
        "vx": ((i % 7) - 3) * 0.15,
        "vy": ((i % 3) - 1) * 0.1,
        "char": ["*", "·", "•", "+", "◦", "○", "◈"][i % 7],
        "color": ["text-yellow-400", "text-cyan-300", "text-purple-300",
                  "text-pink-300", "text-green-300", "text-blue-300"][i % 6],
        "life": 1.0
      })
    }

    setupDOM()
  }

  setupDOM() {
    var mainBox = _document.createElement("flex flex-col grow-1 bg-gray-900")

    // Info display
    var infoBox = _document.createElement("flex flex-row text-gray-500 justify-between")

    var fpsBox = _document.createElement("flex-1")
    _fpsText = _document.createText("FPS: --")
    fpsBox.append(_fpsText)
    infoBox.append(fpsBox)
    mainBox.append(infoBox)

    // Create wave display rows
    for (y in 0..._height) {
      var row = _document.createElement("flex flex-row")
      var cells = []

      for (x in 0..._width) {
        var cell = _document.createElement("w-1 h-1 text-cyan-500")
        var text = _document.createText(" ")
        cell.append(text)
        row.append(cell)
        cells.add([cell, text])
      }

      mainBox.append(row)
      _rows.add(cells)
    }


    _container.append(mainBox)
  }

  animate() {
    while (true) {
      _frame = _frame + 1
      _frameCount = _frameCount + 1

      // Calculate FPS every 10 frames for smoother display
      var currentTime = System.clock
      if (_frameCount % 10 == 0) {
        var deltaTime = currentTime - _lastFrameTime
        if (deltaTime > 0) {
          _currentFps = ((100 / deltaTime).round) / 10
        }
        _lastFrameTime = currentTime

        // Update FPS display
        _fpsText.updateText("FPS %(_currentFps)")
      }


      // Clear all cells first
      for (y in 0..._height) {
        for (x in 0..._width) {
          _rows[y][x][1].updateText(" ")
          _rows[y][x][0].updateClass("w-1 h-1 bg-gray-900")
        }
      }

      // Update and render shimmering stars
      for (star in _stars) {
        var x = star["x"]
        var y = star["y"]

        // Twinkle effect
        var twinkle = ((star["twinklePhase"] + _frame * 0.05).sin * 0.5 + 0.5)
        var brightness = (twinkle * star["brightness"]).floor

        if (x >= 0 && x < _width && y >= 0 && y < _height) {
          var starColors = ["text-gray-700", "text-yellow-200", "text-yellow-300",
                           "text-white", "text-cyan-200", "text-blue-200"]
          var starChar = star["char"]

          // Occasional shooting star effect
          if ((_frame + star["x"] * 7) % 180 == 0) {
            starChar = "⋆"
            _rows[y][x][0].updateClass("w-1 h-1 " + starColors[4] + " bold")
          } else {
            _rows[y][x][0].updateClass("w-1 h-1 " + starColors[brightness.min(5)])
          }

          _rows[y][x][1].updateText(starChar)
        }
      }

      // Update and render particles
      for (particle in _particles) {
        // Update position with fluid motion
        particle["x"] = particle["x"] + particle["vx"]
        particle["y"] = particle["y"] + particle["vy"]

        // Add organic floating movement
        particle["x"] = particle["x"] + ((_frame * 0.08 + particle["y"] * 0.3).sin * 0.15)
        particle["y"] = particle["y"] + ((_frame * 0.06 + particle["x"] * 0.2).cos * 0.08)

        // Wrap around edges
        if (particle["x"] < 0) particle["x"] = _width - 1
        if (particle["x"] >= _width) particle["x"] = 0
        if (particle["y"] < 0) particle["y"] = (_height - 8) - 1
        if (particle["y"] >= (_height - 8)) particle["y"] = 0

        var px = particle["x"].floor
        var py = particle["y"].floor

        if (px >= 0 && px < _width && py >= 0 && py < _height) {
          // Pulsing particle effect
          var pulse = ((_frame * 0.15 + px * 0.1).sin * 0.5 + 0.5)
          var particleClass = "w-1 h-1 " + particle["color"]
          if (pulse > 0.6) {
            particleClass = particleClass + " bold"
          }

          _rows[py][px][1].updateText(particle["char"])
          _rows[py][px][0].updateClass(particleClass)
        }
      }

      // Calculate and render waves (with layering priority)
      for (y in 0..._height) {
        for (x in 0..._width) {
          var cell = _rows[y][x][0]
          var text = _rows[y][x][1]

          // Calculate wave height at this position
          var waveX = x * _frequency
          var waveTime = _frame * _speed

          // Create multiple wave layers for complexity
          var wave1 = (_amplitude * (waveX + waveTime).sin).abs
          var wave2 = ((_amplitude * 0.7) * ((waveX * 1.5 + waveTime * 1.2).sin)).abs
          var wave3 = ((_amplitude * 0.5) * ((waveX * 2.3 + waveTime * 0.8).sin)).abs

          // Combine waves
          var waveHeight = wave1 + wave2 + wave3
          var normalizedHeight = _height - 1 - waveHeight.floor

          // Calculate distance from wave peak for this cell
          var distance = (normalizedHeight - y).abs

          // Determine character and color based on position relative to wave
          if (y >= normalizedHeight - 2 && y <= normalizedHeight + 2) {
            // Near the wave - override background elements
            var intensity = (5 - distance).min(9).max(0)
            var char = _waveChars[intensity]
            var color = _colors[intensity]

            text.updateText(char)

            // Create enhanced shimmer effect
            var shimmer = ((x + _frame * 0.5).sin * 3 + 3).floor
            var sparkle = ((_frame * 0.3 + x * 0.7).cos * 2 + 2).floor

            if (shimmer == 0 && sparkle == 0) {
              cell.updateClass("w-1 h-1 " + color + " text-white bold")
            } else if (shimmer == 1) {
              cell.updateClass("w-1 h-1 " + color + " text-cyan-200")
            } else {
              cell.updateClass("w-1 h-1 " + color + " text-blue-300")
            }
          } else if (y > normalizedHeight + 2) {
            // Below the wave (water) - override background elements
            var depth = (y - normalizedHeight - 2).min(4)
            var waterChars = ["≈", "~", "-", ".", " "]
            var waterChar = waterChars[depth]

            // Add gentle water movement
            if (depth < 2 && ((_frame + x * 3) % 8 == 0)) {
              waterChar = "~"
            }

            text.updateText(waterChar)

            var waterColors = ["bg-blue-800", "bg-blue-900", "bg-gray-900", "bg-gray-900", "bg-gray-900"]
            cell.updateClass("w-1 h-1 " + waterColors[depth] + " text-blue-400")
          }
          // Sky area preserves stars and particles (no override)
        }
      }

      Window.waitForNextFrame()
    }
  }
}

Window.immediately {
  System.print("Starting waves animation")
  Document.root.classes = "flex flex-col grow-1 bg-gray-900"
  var container = Document.createElement("flex flex-col grow-1")
  Document.root.append(container)

  var combinedWaves = CombinedWaveAnimation.new(container)
  System.print("✨ Mystical Ocean Waves with shimmering stars and floating particles! ✨")
  combinedWaves.animate()
}
