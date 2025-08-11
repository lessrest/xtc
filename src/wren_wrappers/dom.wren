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
}

class Element {
  id { _id }
  id=(value) { _id = value }

  construct new(id) {
    _id = id
  }
  append(child) {
    DOM.appendChild(_id, child.id)
  }
  setDebugId(name) {
    DOM.setDebugId(_id, name)
  }
}

class ScriptRunner {
  static run(selfId, source) {
    var code = ""
    code = "var self = Element.new(%(selfId))\n"
    code = code + "var document = Document.new()\n"
    code = code + source

    var closure = Meta.compile(code)
    var fiber = Fiber.new(closure)
    var error = fiber.try()
    if (error) {
      System.print(error)
    }
  }
}
