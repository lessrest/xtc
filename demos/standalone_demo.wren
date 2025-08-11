// Standalone Wren demo - creates entire UI from scratch
// Run with: zig-out/bin/xtc --wren demos/standalone_demo.wren

import "dom" for Document, Element

// Get the root element
var root = Document.root

// Clear any existing content and style the root
root.updateClass("flex flex-col bg-gray-900 text-white p-4")

// Create a title
var title = Document.createElement("text-cyan-400 text-xl mb-4 text-center")
var titleText = Document.createText("✨ Standalone Wren Demo ✨")
title.append(titleText)
root.append(title)

// Create a description
var desc = Document.createElement("text-gray-400 mb-4")
var descText = Document.createText("This entire UI was created from a Wren script - no XML needed!")
desc.append(descText)
root.append(desc)

// Create some interactive content
var contentBox = Document.createElement("flex flex-col gap-2 border border-gray-700 p-4 rounded")

// Add some colorful boxes
var colors = ["red", "yellow", "green", "blue", "purple", "pink"]
for (i in 0...colors.count) {
  var box = Document.createElement("flex flex-row gap-2 items-center")
  
  var colorSquare = Document.createElement("w-4 h-2 bg-%(colors[i])-500")
  var squareText = Document.createText("██")
  colorSquare.append(squareText)
  box.append(colorSquare)
  
  var label = Document.createElement("text-%(colors[i])-400")
  var labelText = Document.createText("This is a %(colors[i]) element")
  label.append(labelText)
  box.append(label)
  
  contentBox.append(box)
}

root.append(contentBox)

// Add a footer with instructions
var footer = Document.createElement("text-gray-600 text-xs mt-4 text-center")
var footerText = Document.createText("Run with: zig-out/bin/xtc --wren demos/standalone_demo.wren")
footer.append(footerText)
root.append(footer)

System.print("Standalone Wren demo loaded successfully!")