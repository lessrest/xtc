import "xtc" for Kernel

class Window {
  static width { Kernel.viewportWidth() }
  static height { Kernel.viewportHeight() }

  static waitForNextFrame() {
    return Kernel.requestAnimationFrame(Fiber.current)
  }

  static immediately(f) {
    return Kernel.enqueue(Fiber.new(f))
  }
}

class Document {
  static root { Element.new(Kernel.root()) }

  // Host viewport size
  static width { Kernel.viewportWidth() }
  static height { Kernel.viewportHeight() }

  static createElement(style) {
    return Element.new(Kernel.createElement(style))
  }

  static createText(text) {
    return Element.new(Kernel.createText(text))
  }


  static getElementById(id) {
    var nodeId = Kernel.getElementById(id)
    if (nodeId == 4294967295) return null  // maxInt means not found
    return Element.new(nodeId)
  }
}

class Element {
  construct new(id) {
    _id = id
  }

  id { _id }
  id=(value) { _id = value }

  childCount { Kernel.getChildCount(_id) }

  firstChild {
    var childId = Kernel.getFirstChild(_id)
    if (childId == -1) return null
    return Element.new(childId)
  }

  append(child) {
    Kernel.appendChild(_id, child.id)
  }

  removeChild(child) {
    Kernel.removeChild(_id, child.id)
  }

  setDebugId(name) {
    Kernel.setDebugId(_id, name)
  }

  updateText(text) {
    Kernel.updateText(_id, text)
  }

  updateClass(className) {
    Kernel.updateClass(_id, className)
  }
}
