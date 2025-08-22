import "xtc" for Core, Element, Text, Document, Window

var body = Element.create("flex flex-col")
var text = Text.create("Hello, World!")
body.append(text)
Document.root.append(body)
Document.openWindow()

Core.sleep(1)
Window.close()

