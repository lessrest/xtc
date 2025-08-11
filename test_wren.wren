System.print("Hello from Wren!")
System.print("Math test: 2 + 3 = %(2 + 3)")

import "dom" for Document

var doc = Document.new()
var el = doc.createElement("text-blue-400 bg-slate-800")
var txt = doc.createText("hello world")
el.append(txt)
doc.root.append(el)
