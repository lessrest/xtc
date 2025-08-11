import "meta" for Meta

class Document {
  root { Element.new(_root) }

  construct new() {
    _root = DOM.root()
  }
  createElement(style) {
    return Element.new(DOM.createElement(style))
  }
  createText(text) {
    return Element.new(DOM.createText(text))
  }
  
  // Add event listener to document (root node)
  addEventListener(eventType, handler) {
    return DOM.addEventListener(0, eventType, handler)
  }
  
  removeEventListener(eventType, handlerId) {
    return DOM.removeEventListener(0, eventType, handlerId)
  }
}

var document = Document.new()
var self = null

class Element {
  id { _id }
  id=(value) { _id = value }
  
  childCount { DOM.getChildCount(_id) }
  firstChild { 
    var childId = DOM.getFirstChild(_id)
    if (childId == -1) return null
    return Element.new(childId)
  }

  construct new(id) {
    _id = id
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

class ScriptRunner {
  static run(selfId, source) {
    var code = ""
    code = "{
      var self = Element.new(%(selfId))
      %(source)
    }"
    var closure = Meta.compile(code)
    var fiber = Fiber.new(closure)
    var error = fiber.try()
    if (error) {
      System.print(error)
    }
  }
}
