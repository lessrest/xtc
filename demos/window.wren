import "xtc" for Core, Element, Text, Document

var body = Element.create("flex flex-col")
var text = Text.create("Hello, World!")
body.append(text)
Document.root.append(body)
Document.openWindow()

