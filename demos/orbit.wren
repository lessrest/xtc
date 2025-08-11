// Orbital animation - a few elements moving in paths
var document = Document.new()

class Orbit {
  construct new(container, doc) {
    _container = container
    _document = doc
    _frame = 0
    _planets = []
    
    // Get viewport size for centering
    _width = doc.width
    _height = doc.height
    _centerX = _width / 2
    _centerY = _height / 2
    
    setupDOM()
  }
  
  setupDOM() {
    var space = _document.createElement("flex flex-col bg-black")
    space.updateClass("fixed top-0 left-0 w-" + _width.toString + " h-" + _height.toString + " bg-black")
    
    // Create sun at center
    var sun = _document.createElement("absolute bg-yellow-400 text-yellow-200 w-4 h-2")
    sun.updateClass("absolute left-" + (_centerX - 2).toString + " top-" + (_centerY - 1).toString + " bg-yellow-400 text-yellow-200 w-4 h-2")
    var sunText = _document.createText("☀️")
    sun.append(sunText)
    space.append(sun)
    
    // Create planets with different orbital parameters
    _planets = [
      {
        "element": _document.createElement("absolute bg-blue-500 w-2 h-1"),
        "text": _document.createText("●"),
        "radius": 8,
        "speed": 0.05,
        "phase": 0
      },
      {
        "element": _document.createElement("absolute bg-red-500 w-2 h-1"),
        "text": _document.createText("●"),
        "radius": 12,
        "speed": 0.03,
        "phase": 1.57
      },
      {
        "element": _document.createElement("absolute bg-green-500 w-2 h-1"),
        "text": _document.createText("●"),
        "radius": 16,
        "speed": 0.02,
        "phase": 3.14
      }
    ]
    
    // Add planets to DOM
    for (planet in _planets) {
      planet["element"].append(planet["text"])
      space.append(planet["element"])
    }
    
    // Animation clock at 30 FPS
    var animClock = _document.createClock("clock fps-30 clock-hidden")
    animClock.addEventListener("tick", Fn.new { |event|
      animate(event["tick"])
    })
    space.append(animClock)
    
    // Info display
    var info = _document.createElement("absolute bottom-2 left-2 text-gray-600 text-xs")
    info.updateClass("absolute left-2 top-" + (_height - 2).toString + " text-gray-600 text-xs")
    _frameText = _document.createText("Frame: 0")
    info.append(_frameText)
    space.append(info)
    
    _container.append(space)
  }
  
  animate(frame) {
    _frame = frame
    _frameText.updateText("Frame: " + frame.toString + " | Press Q to quit")
    
    // Update planet positions
    for (planet in _planets) {
      var angle = planet["phase"] + _frame * planet["speed"]
      var x = (_centerX + planet["radius"] * angle.cos).floor
      var y = (_centerY + planet["radius"] * angle.sin * 0.5).floor  // Squash Y for elliptical orbit
      
      // Update position via classes (not ideal but works)
      planet["element"].updateClass("absolute left-" + x.toString + " top-" + y.toString + " " +
        (planet["radius"] == 8 ? "bg-blue-500" : 
         planet["radius"] == 12 ? "bg-red-500" : "bg-green-500") + " w-2 h-1")
    }
  }
}

// Main execution
var container = document.getElementById("waves")
if (container == null) {
  System.print("Error: Could not find waves element")
} else {
  var orbit = Orbit.new(container, document)
}