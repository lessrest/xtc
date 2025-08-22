import "xtc" for Core
import "syscall" for OpenWindow, RequestRender, NextEvent, CloseWindow, CreateElement, AppendChild, UpdateClass, PrintElement, CreateText, UpdateText

class Document {
  static root { Element.fromIndex(0) }

  static requestRender() {
    return Core.call(RequestRender.new())
  }
}

class Window {
  construct new() {}

  static open() {
    Core.call(OpenWindow.new())
    return Window.new()
  }

  nextEvent(type) {
    return Core.call(NextEvent.new(type))
  }

  close() {
    return Core.call(CloseWindow.new())
  }
}

class Element {
  index { _index }

  construct fromIndex(index) {
    _index = index
  }

  construct create(style) {
    _index = Core.call(CreateElement.new(style))
  }

  append(child) {
    return Core.call(AppendChild.new(index, child.index))
  }

  classes=(string) {
    return Core.call(UpdateClass.new(index, string))
  }

  print() {
    return Core.call(PrintElement.new(index))
  }
}

class Text {
  index { _index }

  construct fromIndex(index) {
    _index = index
  }

  construct create(text) {
    _index = Core.call(CreateText.new(text))
  }

  content=(string) {
    return Core.call(UpdateText.new(index, string))
  }
}
