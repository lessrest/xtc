// DOM API for Wren scripts
// Provides clean interface to manipulate the XTC DOM from Wren

import "meta" for Meta
import "tui" for Platform

class Document {
  static root { Element.new(Platform.root()) }

  // Host viewport size
  static width { Platform.viewportWidth() }
  static height { Platform.viewportHeight() }

  static createElement(style) {
    return Element.new(Platform.createElement(style))
  }

  static createText(text) {
    return Element.new(Platform.createText(text))
  }


  static getElementById(id) {
    var nodeId = Platform.getElementById(id)
    if (nodeId == 4294967295) return null  // maxInt means not found
    return Element.new(nodeId)
  }

  static addEventListener(eventType, handler) {
    return Platform.addEventListener(0, eventType, handler)
  }

  static removeEventListener(eventType, handlerId) {
    return Platform.removeEventListener(0, eventType, handlerId)
  }
}

class Element {
  construct new(id) {
    _id = id
  }

  id { _id }
  id=(value) { _id = value }

  childCount { Platform.getChildCount(_id) }

  firstChild {
    var childId = Platform.getFirstChild(_id)
    if (childId == -1) return null
    return Element.new(childId)
  }

  append(child) {
    Platform.appendChild(_id, child.id)
  }

  removeChild(child) {
    Platform.removeChild(_id, child.id)
  }

  setDebugId(name) {
    Platform.setDebugId(_id, name)
  }

  updateText(text) {
    Platform.updateText(_id, text)
  }

  updateClass(className) {
    Platform.updateClass(_id, className)
  }

  addEventListener(eventType, handler) {
    return Platform.addEventListener(_id, eventType, handler)
  }

  removeEventListener(eventType, handlerId) {
    return Platform.removeEventListener(_id, eventType, handlerId)
  }
}

class ScriptRunner {
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

  static executeInline(selfId, source) {
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
