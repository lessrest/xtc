// XTC Platformer Game - A fiber-based 2D platformer
import "dom" for Window, Document, Element

class PlatformerGame {
  construct new(container) {
    _container = container
    _document = Document
    _width = Document.width
    _height = Document.height
    
    // Game state
    _gameRunning = true
    _score = 0
    _level = 1
    
    // Player state
    _player = {
      "x": 5,
      "y": _height - 5,
      "vx": 0,
      "vy": 0,
      "onGround": false,
      "char": "🟢"
    }
    
    // Game world
    _platforms = []
    _enemies = []
    _coins = []
    _particles = []
    
    // Controls
    _keys = {}
    
    // Game elements
    _gameArea = null
    _playerElement = null
    _uiElement = null
    
    initializeLevel()
  }
  
  initializeLevel() {
    // Clear existing level
    _platforms = []
    _enemies = []
    _coins = []
    _particles = []
    
    // Create platforms for level 1
    if (_level == 1) {
      // Ground platforms
      _platforms.add({"x": 0, "y": _height - 2, "width": 20, "height": 2, "type": "ground"})
      _platforms.add({"x": 25, "y": _height - 2, "width": 15, "height": 2, "type": "ground"})
      _platforms.add({"x": 45, "y": _height - 2, "width": 20, "height": 2, "type": "ground"})
      
      // Floating platforms
      _platforms.add({"x": 15, "y": _height - 8, "width": 8, "height": 1, "type": "platform"})
      _platforms.add({"x": 30, "y": _height - 12, "width": 6, "height": 1, "type": "platform"})
      _platforms.add({"x": 50, "y": _height - 15, "width": 10, "height": 1, "type": "platform"})
      
      // Create enemies
      _enemies.add({"x": 30, "y": _height - 3, "vx": -1, "char": "👹", "minX": 25, "maxX": 38, "health": 1})
      _enemies.add({"x": 55, "y": _height - 3, "vx": 1, "char": "🔴", "minX": 45, "maxX": 63, "health": 1})
      
      // Create coins
      _coins.add({"x": 18, "y": _height - 10, "char": "💰", "collected": false})
      _coins.add({"x": 33, "y": _height - 14, "char": "💎", "collected": false})
      _coins.add({"x": 55, "y": _height - 17, "char": "🌟", "collected": false})
    }
  }
  
  run() {
    setupUI()
    startGameLoop()
    setupInput()
  }
  
  setupUI() {
    // Create main game container
    _gameArea = Document.createElement("flex flex-col grow-1 bg-black")
    _container.append(_gameArea)
    
    // Create UI bar
    _uiElement = Document.createElement("flex flex-row bg-gray-900 text-white p-1")
    _uiElement.append(Document.createText("Score: %(_score) | Level: %(_level) | Use WASD/Arrow keys"))
    _gameArea.append(_uiElement)
    
    // Create game world container  
    var worldContainer = Document.createElement("flex-1 relative bg-gradient-to-b from-sky-400 to-green-400")
    _gameArea.append(worldContainer)
    
    // Create player
    _playerElement = Document.createElement("absolute bg-glyph-[%(_player["char"])] text-green-400")
    worldContainer.append(_playerElement)
    
    updateDisplay()
  }
  
  startGameLoop() {
    Window.spawn {
      while (_gameRunning) {
        updatePhysics()
        updateEnemies() 
        updateParticles()
        checkCollisions()
        updateDisplay()
        Window.sleep(50) // 20 FPS
      }
    }
  }
  
  setupInput() {
    Window.spawn {
      while (_gameRunning) {
        var event = Window.waitForEvent("keypress")
        var key = event["key"]
        
        if (key == "a" || key == "A" || key == "ArrowLeft") {
          _keys["left"] = true
        } else if (key == "d" || key == "D" || key == "ArrowRight") {  
          _keys["right"] = true
        } else if (key == "w" || key == "W" || key == " " || key == "ArrowUp") {
          if (_player["onGround"]) {
            _player["vy"] = -3 // Jump
            createParticle(_player["x"], _player["y"] + 1, "💨")
          }
        } else if (key == "r" || key == "R") {
          // Reset level
          _player["x"] = 5
          _player["y"] = _height - 5
          _player["vx"] = 0
          _player["vy"] = 0
          _score = 0
          initializeLevel()
        }
      }
    }
    
    // Handle continuous movement and key release simulation
    Window.spawn {
      while (_gameRunning) {
        // Apply horizontal movement
        if (_keys["left"]) {
          _player["vx"] = -2
          _keys["left"] = false // Reset key
        } else if (_keys["right"]) {
          _player["vx"] = 2  
          _keys["right"] = false // Reset key
        } else {
          _player["vx"] = _player["vx"] * 0.8 // Friction
        }
        
        Window.sleep(100)
      }
    }
  }
  
  updatePhysics() {
    // Apply gravity
    _player["vy"] = _player["vy"] + 0.5
    
    // Apply velocity
    _player["x"] = _player["x"] + _player["vx"]
    _player["y"] = _player["y"] + _player["vy"]
    
    // Terminal velocity
    if (_player["vy"] > 5) _player["vy"] = 5
    
    // Screen boundaries
    if (_player["x"] < 0) _player["x"] = 0
    if (_player["x"] >= _width) _player["x"] = _width - 1
    
    // Death by falling
    if (_player["y"] >= _height) {
      _player["x"] = 5
      _player["y"] = _height - 5
      _player["vx"] = 0
      _player["vy"] = 0
      _score = (_score - 50).max(0)
      createParticle(_player["x"], _player["y"], "💀")
    }
  }
  
  updateEnemies() {
    for (enemy in _enemies) {
      if (enemy["health"] > 0) {
        enemy["x"] = enemy["x"] + enemy["vx"]
        
        // Bounce off boundaries
        if (enemy["x"] <= enemy["minX"] || enemy["x"] >= enemy["maxX"]) {
          enemy["vx"] = -enemy["vx"]
        }
      }
    }
  }
  
  updateParticles() {
    var activeParticles = []
    for (particle in _particles) {
      particle["life"] = particle["life"] - 1
      particle["y"] = particle["y"] - 1
      if (particle["life"] > 0) {
        activeParticles.add(particle)
      }
    }
    _particles = activeParticles
  }
  
  checkCollisions() {
    _player["onGround"] = false
    
    // Platform collisions
    for (platform in _platforms) {
      if (playerCollidesPlatform(platform)) {
        if (_player["vy"] > 0) { // Falling down
          _player["y"] = platform["y"] - 1
          _player["vy"] = 0
          _player["onGround"] = true
        }
      }
    }
    
    // Enemy collisions
    for (enemy in _enemies) {
      if (enemy["health"] > 0 && playerCollidesEnemy(enemy)) {
        if (_player["vy"] > 0 && _player["y"] < enemy["y"]) {
          // Player jumped on enemy
          enemy["health"] = 0
          _player["vy"] = -2 // Bounce
          _score = _score + 100
          createParticle(enemy["x"], enemy["y"], "💥")
        } else {
          // Player hit enemy - damage
          _player["x"] = 5
          _player["y"] = _height - 5  
          _player["vx"] = 0
          _player["vy"] = 0
          _score = (_score - 25).max(0)
          createParticle(_player["x"], _player["y"], "⚡")
        }
      }
    }
    
    // Coin collisions
    for (coin in _coins) {
      if (!coin["collected"] && playerCollidesCoin(coin)) {
        coin["collected"] = true
        _score = _score + 50
        createParticle(coin["x"], coin["y"], "✨")
        
        // Check if all coins collected
        var allCollected = true
        for (c in _coins) {
          if (!c["collected"]) allCollected = false
        }
        if (allCollected) {
          _level = _level + 1
          _score = _score + 200
          createParticle(_player["x"], _player["y"], "🎉")
          initializeLevel()
        }
      }
    }
  }
  
  playerCollidesPlatform(platform) {
    return _player["x"] >= platform["x"] && 
           _player["x"] < platform["x"] + platform["width"] &&
           _player["y"] >= platform["y"] && 
           _player["y"] < platform["y"] + platform["height"]
  }
  
  playerCollidesEnemy(enemy) {
    return (_player["x"] - enemy["x"]).abs < 2 && 
           (_player["y"] - enemy["y"]).abs < 2
  }
  
  playerCollidesCoin(coin) {
    return (_player["x"] - coin["x"]).abs < 2 && 
           (_player["y"] - coin["y"]).abs < 2
  }
  
  createParticle(x, y, char) {
    _particles.add({"x": x, "y": y, "char": char, "life": 10})
  }
  
  updateDisplay() {
    // Clear and rebuild display
    var children = _gameArea.children
    if (children.count > 2) {
      // Keep UI and world container, remove game objects
      for (i in 2...children.count) {
        children[i].remove()
      }
    }
    
    var worldContainer = children[1]
    
    // Update UI
    _uiElement.children[0].updateText("Score: %(_score) | Level: %(_level) | WASD/Arrows: Move, Space/W: Jump, R: Reset")
    
    // Position player
    var playerStyle = "absolute bg-glyph-[%(_player["char"])] text-green-400"
    if (_player["x"] >= 0 && _player["x"] < _width && _player["y"] >= 0 && _player["y"] < _height) {
      playerStyle = playerStyle + " left-%(_player["x"]) top-%(_player["y"])"
    }
    _playerElement.updateClass(playerStyle)
    
    // Draw platforms
    for (platform in _platforms) {
      var platformChar = platform["type"] == "ground" ? "🟫" : "🟤"
      for (x in platform["x"]...(platform["x"] + platform["width"])) {
        for (y in platform["y"]...(platform["y"] + platform["height"])) {
          if (x >= 0 && x < _width && y >= 0 && y < _height) {
            var elem = Document.createElement("absolute bg-glyph-[%(platformChar)] left-%(x) top-%(y)")
            worldContainer.append(elem)
          }
        }
      }
    }
    
    // Draw enemies
    for (enemy in _enemies) {
      if (enemy["health"] > 0 && enemy["x"] >= 0 && enemy["x"] < _width && enemy["y"] >= 0 && enemy["y"] < _height) {
        var elem = Document.createElement("absolute bg-glyph-[%(enemy["char"])] text-red-400 left-%(enemy["x"]) top-%(enemy["y"])")
        worldContainer.append(elem)
      }
    }
    
    // Draw coins
    for (coin in _coins) {
      if (!coin["collected"] && coin["x"] >= 0 && coin["x"] < _width && coin["y"] >= 0 && coin["y"] < _height) {
        var elem = Document.createElement("absolute bg-glyph-[%(coin["char"])] text-yellow-400 left-%(coin["x"]) top-%(coin["y"])")
        worldContainer.append(elem)
      }
    }
    
    // Draw particles
    for (particle in _particles) {
      if (particle["x"] >= 0 && particle["x"] < _width && particle["y"] >= 0 && particle["y"] < _height) {
        var elem = Document.createElement("absolute bg-glyph-[%(particle["char"])] left-%(particle["x"]) top-%(particle["y"])")
        worldContainer.append(elem)
      }
    }
  }
}

// Start the game
Window.immediately {
  var game = PlatformerGame.new(Document.root)
  game.run()
}