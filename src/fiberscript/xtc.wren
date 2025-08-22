import "syscall" for Sleep, OpenWindow, RequestRender, NextEvent, CloseWindow, CreateElement, AppendChild, UpdateClass, PrintElement, CreateText, UpdateText

class Core {
    foreign static syscall(fiber, request)
    foreign static submitBatch(fiber, batch)

    static call(request) {
        var result = syscall(Fiber.current, request)
        if (result == Fiber.current) {
            return Fiber.suspend()
        } else {
            return result
        }
    }

    static sleep(seconds) {
        return Core.call(Sleep.new(seconds))
    }

    static submit(batch) {
        return submitBatch(Fiber.current, batch)
    }
}

class Document {
  static root { Element.fromIndex(0) }

  static openWindow() {
    return Core.call(OpenWindow.new())
  }

  static requestRender() {
    return Core.call(RequestRender.new())
  }
}

class Window {
  static nextEvent(type) {
    return Core.call(NextEvent.new(type))
  }

  static close() {
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
