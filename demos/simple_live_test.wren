// Simple test for --wren --live mode
import "dom" for Document, Element
var root = Document.root

// Clear and style the root
root.updateClass("flex flex-col bg-gray-900 text-white p-4")

// Add a title
var title = Document.createElement("text-cyan-400 text-xl mb-4")
title.append(Document.createText("Wren Live Mode Works!"))
root.append(title)

// Add a simple clock to show it's live
var clock = Document.createClock("clock interval-1000 clock-text bg-blue-500 text-white p-2 w-8 h-2")
root.append(clock)

// Add instructions
var info = Document.createElement("text-gray-400 text-sm mt-4")
info.append(Document.createText("Press Q to quit"))
root.append(info)

System.print("Wren live mode initialized!")