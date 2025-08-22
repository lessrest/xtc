import "xtc" for Core
import "dom" for Element, Text, Document, Window

var body = Element.create("flex flex-col")
var text = Text.create("Hello, World!")
body.append(text)
Document.root.append(body)
var win = Window.open()

Core.sleep(1)
win.close()

