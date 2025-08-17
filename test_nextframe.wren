// Simple test to verify TUI.nextFrame() functionality
import "dom" for Document, Element
import "tui" for TUI

class NextFrameTest {
  construct new() {
    _document = Document
    _frameCount = 0
    _maxFrames = 10
    
    setupDOM()
    startTest()
  }

  setupDOM() {
    var main = _document.createElement("flex flex-col p-4 bg-black text-white")
    
    // Title
    var title = _document.createElement("text-2xl mb-2")
    var titleText = _document.createText("NextFrame Test")
    title.append(titleText)
    main.append(title)
    
    // Frame counter display
    _counterElement = _document.createElement("text-lg mb-2")
    _counterText = _document.createText("Frame: 0")
    _counterElement.append(_counterText)
    main.append(_counterElement)
    
    // Status display
    _statusElement = _document.createElement("text-base")
    _statusText = _document.createText("Starting test...")
    _statusElement.append(_statusText)
    main.append(_statusElement)
    
    // Append to document root
    var root = _document.root
    root.append(main)
  }

  startTest() {
    System.print("Starting NextFrame test...")
    
    // Start the animation fiber
    var testFiber = Fiber.new {
      animate()
    }
    testFiber.call()
  }

  animate() {
    while (_frameCount < _maxFrames) {
      _frameCount = _frameCount + 1
      
      // Update the display
      _counterText.updateText("Frame: %(_frameCount)")
      _statusText.updateText("Waiting for next frame... (%(_frameCount)/%(_maxFrames))")
      
      System.print("Frame %(_frameCount): About to call TUI.nextFrame()")
      
      // Wait for next frame - this is what we're testing
      TUI.nextFrame()
      
      System.print("Frame %(_frameCount): Returned from TUI.nextFrame()")
    }
    
    // Test complete
    _statusText.updateText("Test complete! NextFrame worked %(_maxFrames) times.")
    System.print("NextFrame test completed successfully!")
  }
}

// Create and run the test
NextFrameTest.new()