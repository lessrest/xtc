import "xtc" for Core, Document

Core.spawn {
  // Build a tiny DOM in a fiber so yields work
  var root = Document.root
  var title = Document.createElement("text-green-400")
  Document.append(root, title)
  var t = Document.createText("Hello from one-shot! ")
  Document.append(title, t)
  // Render once to stdout as plain text (no alt screen)
  Core.printDocument()
  System.print("[debug] requested printDocument")
}
