// Smooth animated waves using clock-based animation
var document = Document.new()

class WaveAnimation {
  construct new(container, doc) {
    _container = container
    _document = doc
    _frame = 0
    _rows = []
    _width = 60
    _height = 20
    
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
    
    setupDOM()
  }
  
  setupDOM() {
    var mainBox = _document.createElement("flex flex-col p-2 bg-gray-900")
    
    // Title
    var titleBox = _document.createElement("text-cyan-400 text-center mb-2")
    var titleText = _document.createText("~ Wave Animation ~")
    titleBox.append(titleText)
    mainBox.append(titleBox)
    
    // Create animation clock - 60 FPS for smooth animation
    var animClock = _document.createClock("clock fps-60 clock-hidden")
    animClock.addEventListener("tick", Fn.new { |event|
      animate(event["tick"])
    })
    mainBox.append(animClock)
    
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
    
    // Info display
    var infoBox = _document.createElement("flex flex-row gap-4 mt-2 text-gray-500 text-xs")
    
    var fpsBox = _document.createElement("flex-1")
    _fpsText = _document.createText("60 FPS")
    fpsBox.append(_fpsText)
    infoBox.append(fpsBox)
    
    var frameBox = _document.createElement("flex-1 text-right")
    _frameText = _document.createText("Frame: 0")
    frameBox.append(_frameText)
    infoBox.append(frameBox)
    
    mainBox.append(infoBox)
    
    // Controls
    var controlsBox = _document.createElement("text-gray-600 text-xs mt-1 text-center")
    var controlsText = _document.createText("Press Q to quit")
    controlsBox.append(controlsText)
    mainBox.append(controlsBox)
    
    _container.append(mainBox)
  }
  
  animate(frame) {
    _frame = frame
    
    // Update frame counter
    _frameText.updateText("Frame: " + frame.toString)
    
    // Calculate wave positions
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
          // Near the wave
          var intensity = (5 - distance).min(9).max(0)
          var char = _waveChars[intensity]
          var color = _colors[intensity]
          
          text.updateText(char)
          
          // Create shimmer effect
          var shimmer = ((x + _frame * 0.5).sin * 3 + 3).floor
          if (shimmer == 0) {
            cell.updateClass("w-1 h-1 " + color + " text-white")
          } else if (shimmer == 1) {
            cell.updateClass("w-1 h-1 " + color + " text-cyan-300")
          } else {
            cell.updateClass("w-1 h-1 " + color + " text-blue-400")
          }
        } else if (y > normalizedHeight + 2) {
          // Below the wave (water)
          var depth = (y - normalizedHeight - 2).min(4)
          var waterChar = ["≈", "~", "-", ".", " "][depth]
          text.updateText(waterChar)
          
          var waterColor = ["bg-blue-800", "bg-blue-900", "bg-gray-900", "bg-gray-900", ""][depth]
          cell.updateClass("w-1 h-1 " + waterColor + " text-blue-600")
        } else {
          // Above the wave (sky)
          text.updateText(" ")
          
          // Stars in the sky
          if ((x * 7 + y * 13) % 47 == 0) {
            text.updateText("·")
            cell.updateClass("w-1 h-1 text-yellow-200")
          } else if ((x * 11 + y * 17) % 67 == 0) {
            text.updateText("✦")
            cell.updateClass("w-1 h-1 text-white")
          } else {
            cell.updateClass("w-1 h-1 text-gray-900")
          }
        }
      }
    }
  }
}

// Create second animation - particle field
class ParticleField {
  construct new(container, doc) {
    _container = container
    _document = doc
    _frame = 0
    _cells = []
    _width = 60
    _height = 20
    
    // Particle system
    _particles = []
    for (i in 0...30) {
      _particles.add({
        "x": (System.clock * 1000 * (i + 1)).floor % _width,
        "y": (System.clock * 1000 * (i + 7)).floor % _height,
        "vx": ((i % 5) - 2) * 0.3,
        "vy": ((i % 3) - 1) * 0.2,
        "char": ["*", "·", "•", "+", "◦", "○"][i % 6],
        "color": ["text-red-400", "text-yellow-400", "text-green-400", 
                  "text-blue-400", "text-purple-400", "text-pink-400"][i % 6]
      })
    }
    
    setupDOM()
  }
  
  setupDOM() {
    var mainBox = _document.createElement("flex flex-col p-2 bg-black mt-4")
    
    // Title
    var titleBox = _document.createElement("text-purple-400 text-center mb-2")
    var titleText = _document.createText("✨ Particle Field ✨")
    titleBox.append(titleText)
    mainBox.append(titleBox)
    
    // Animation clock
    var animClock = _document.createClock("clock fps-30 clock-hidden")
    animClock.addEventListener("tick", Fn.new { |event|
      animate(event["tick"])
    })
    mainBox.append(animClock)
    
    // Create display grid
    for (y in 0..._height) {
      var row = _document.createElement("flex flex-row")
      var rowCells = []
      
      for (x in 0..._width) {
        var cell = _document.createElement("w-1 h-1")
        var text = _document.createText(" ")
        cell.append(text)
        row.append(cell)
        rowCells.add([cell, text])
      }
      
      mainBox.append(row)
      _cells.add(rowCells)
    }
    
    _container.append(mainBox)
  }
  
  animate(frame) {
    _frame = frame
    
    // Clear field
    for (y in 0..._height) {
      for (x in 0..._width) {
        _cells[y][x][1].updateText(" ")
        _cells[y][x][0].updateClass("w-1 h-1")
      }
    }
    
    // Update and draw particles
    for (particle in _particles) {
      // Update position
      particle["x"] = particle["x"] + particle["vx"]
      particle["y"] = particle["y"] + particle["vy"]
      
      // Add some sine wave movement
      particle["x"] = particle["x"] + ((_frame * 0.1 + particle["y"] * 0.5).sin * 0.2)
      
      // Wrap around edges
      if (particle["x"] < 0) particle["x"] = _width - 1
      if (particle["x"] >= _width) particle["x"] = 0
      if (particle["y"] < 0) particle["y"] = _height - 1
      if (particle["y"] >= _height) particle["y"] = 0
      
      // Draw particle
      var px = particle["x"].floor
      var py = particle["y"].floor
      
      if (px >= 0 && px < _width && py >= 0 && py < _height) {
        _cells[py][px][1].updateText(particle["char"])
        
        // Pulse effect
        var pulse = ((_frame * 0.3).sin * 0.5 + 0.5)
        if (pulse > 0.7) {
          _cells[py][px][0].updateClass("w-1 h-1 " + particle["color"] + " bold")
        } else {
          _cells[py][px][0].updateClass("w-1 h-1 " + particle["color"])
        }
        
        // Trail effect - draw fading trail
        var trailX = (px - particle["vx"]).floor
        var trailY = (py - particle["vy"]).floor
        if (trailX >= 0 && trailX < _width && trailY >= 0 && trailY < _height) {
          _cells[trailY][trailX][1].updateText("·")
          _cells[trailY][trailX][0].updateClass("w-1 h-1 text-gray-700")
        }
      }
    }
  }
}

// Main execution
var container = document.getElementById("waves")
if (container == null) {
  System.print("Error: Could not find waves element")
} else {
  // Create both animations
  var waves = WaveAnimation.new(container, document)
  var particles = ParticleField.new(container, document)
  
  // No keyboard handling needed - just runs automatically
}