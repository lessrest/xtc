// DOM API for Wren scripts
// Provides clean interface to manipulate the XTC DOM from Wren

import "meta" for Meta

class Document {
  static root { Element.new(DOM.root()) }

  // Host viewport size
  static width { DOM.viewportWidth() }
  static height { DOM.viewportHeight() }

  static createElement(style) {
    return Element.new(DOM.createElement(style))
  }

  static createText(text) {
    return Element.new(DOM.createText(text))
  }

  static createClock(style) {
    return Element.new(DOM.createClock(style))
  }

  static getElementById(id) {
    var nodeId = DOM.getElementById(id)
    if (nodeId == 4294967295) return null  // maxInt means not found
    return Element.new(nodeId)
  }

  static addEventListener(eventType, handler) {
    return DOM.addEventListener(0, eventType, handler)
  }

  static removeEventListener(eventType, handlerId) {
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

  updateText(text) {
    DOM.updateText(_id, text)
  }

  updateClass(className) {
    DOM.updateClass(_id, className)
  }

  addEventListener(eventType, handler) {
    return DOM.addEventListener(_id, eventType, handler)
  }

  removeEventListener(eventType, handlerId) {
    return DOM.removeEventListener(_id, eventType, handlerId)
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
