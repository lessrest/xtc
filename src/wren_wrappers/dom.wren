// DOM API for Wren scripts
// Provides clean interface to manipulate the XTC DOM from Wren

import "meta" for Meta

// ============================================================================
// Core DOM Classes
// ============================================================================

class Document {
  construct new() {
    _root = DOM.root()
  }

  root { Element.new(_root) }

  createElement(style) {
    return Element.new(DOM.createElement(style))
  }

  createText(text) {
    return Element.new(DOM.createText(text))
  }
  
  getElementById(id) {
    var nodeId = DOM.getElementById(id)
    if (nodeId == 4294967295) return null  // maxInt means not found
    return Element.new(nodeId)
  }

  addEventListener(eventType, handler) {
    return DOM.addEventListener(0, eventType, handler)
  }

  removeEventListener(eventType, handlerId) {
    return DOM.removeEventListener(0, eventType, handlerId)
  }
}

class Element {
  construct new(id) {
    _id = id
  }

  id { _id }
  id=(value) { _id = value }

  childCount { DOM.getChildCount(_id) }

  firstChild {
    var childId = DOM.getFirstChild(_id)
    if (childId == -1) return null
    return Element.new(childId)
  }

  append(child) {
    DOM.appendChild(_id, child.id)
  }

  removeChild(child) {
    DOM.removeChild(_id, child.id)
  }

  setDebugId(name) {
    DOM.setDebugId(_id, name)
  }

  addEventListener(eventType, handler) {
    return DOM.addEventListener(_id, eventType, handler)
  }

  removeEventListener(eventType, handlerId) {
    return DOM.removeEventListener(_id, eventType, handlerId)
  }
}

// Global document instance
var document = Document.new()

// ============================================================================
// Script Runner - Manages script module execution
// ============================================================================

class ScriptRunner {
  // Execute a module that follows the Script.start(self) convention
  static executeModule(moduleName, selfId) {
    System.print("[ScriptRunner] Starting module '%(moduleName)' with selfId=%(selfId)")
    
    var element = Element.new(selfId)
    
    Meta.eval(
      "import \"dom\" for Element\n" +
      "import \"%(moduleName)\" for Script\n" +
      "Script.start(Element.new(%(selfId)))"
    )
    System.print("[ScriptRunner] Module '%(moduleName)' executed successfully")
  }

  // Execute inline script with backward compatibility
  static executeInline(selfId, source) {
    // Provide 'self' variable in the script's scope
    var code = "
      var self = Element.new(%(selfId))
      %(source)
    "

    var closure = Meta.compile(code)
    var fiber = Fiber.new(closure)
    var error = fiber.try()

    if (error) {
      System.print("[ScriptRunner] Error executing inline script: %(error)")
    }
  }
}

// ============================================================================
// Script Module Convention
// ============================================================================
// Script modules should export a Script class with this interface:
//
// class Script {
//   static start(self) {
//     // self is the Element this script is attached to
//     // Initialize your script here
//   }
//
//   static stop() {
//     // Optional: cleanup when script is removed
//   }
// }