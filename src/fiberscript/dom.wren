import "xtc" for Core
import "syscall" for CreateElement, CreateText, UpdateText, UpdateClass, AppendChild, RemoveChild, GetViewportWidth, GetViewportHeight, WaitForNextFrame, Start

class Document {
  static root { Element.fromIndex(0) }

  static width { GetViewportWidth.new().yield() }
  static height { GetViewportHeight.new().yield() }

  static createElement(style) { Element.create(style) }
  static createText(text) { Text.create(text) }
}

class Element {
  index { _index }

  construct fromIndex(index) {
    _index = index
  }

  construct create(style) {
    _index = CreateElement.new(style).yield()
  }

  append(child) {
    return AppendChild.new(index, child.index).yield()
  }

  remove(child) {
    return RemoveChild.new(index, child.index).yield()
  }

  classes=(string) {
    return UpdateClass.new(index, string).yield()
  }

  updateClass(string) {
    return UpdateClass.new(index, string).yield()
  }
}

class Window {
  static waitForNextFrame() {
    return Fiber.yield(WaitForNextFrame.new())
  }

  static immediately(block) {
    return Core.call(Start.new(Fiber.new(block)))
  }
}

class Text {
  index { _index }

  construct fromIndex(index) {
    _index = index
  }

  construct create(text) {
    _index = CreateText.new(text).yield()
  }

  content=(string) {
    return UpdateText.new(index, string).yield()
  }

  updateText(string) {
    return UpdateText.new(index, string).yield()
  }
}
