import "xtc" for Core
import "syscall" for CreateElement, CreateText, UpdateText, UpdateClass, AppendChild, RemoveChild, SetDocumentTitle

class Document {
  static root { Element.fromIndex(0) }

  static title=(title) {
    return Core.call(SetDocumentTitle.new(title))
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

  remove(child) {
    return Core.call(RemoveChild.new(index, child.index))
  }

  classes=(string) {
    return Core.call(UpdateClass.new(index, string))
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
