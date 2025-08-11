// Test the Wren editor component
import "dom" for Document, Element
import "editor" for Editor

// Check if document is available
System.print("Testing document availability...")

// Create main container
var container = Document.createElement("flex flex-col bg-slate-900 text-white px-2 py-1 grow-1")
Document.root.append(container)

// Add title
var title = Document.createElement("text-blue-400 mb-2")
var titleText = Document.createText("Wren Editor Component Demo")
title.append(titleText)
container.append(title)

// Add instruction text
var instructions = Document.createElement("text-gray-400 mb-4")
var instructText = Document.createText("Type text, use arrow keys for cursor, Ctrl+A/E for home/end, Enter to submit")
instructions.append(instructText)
container.append(instructions)

// Create editor container
var editorContainer = Document.createElement("border border-gray-600 px-2 mb-2")
container.append(editorContainer)

// Create the editor
var editor = Editor.new(editorContainer)

// Output area for submitted text
var outputArea = Document.createElement("flex flex-col text-green-400")
container.append(outputArea)

var outputLabel = Document.createElement("text-gray-400 mb-1")
var labelText = Document.createText("Submitted lines:")
outputLabel.append(labelText)
outputArea.append(outputLabel)

var outputList = Document.createElement("flex flex-col")
outputArea.append(outputList)

// Counter for submitted lines
var lineCount = 0

// Handle keyboard events
Document.addEventListener("keypress", Fn.new { |event|
    var key = event["key"]

    // Let the editor handle the key
    var result = editor.handleKey(key)

    // If a line was submitted, display it
    if (result != null) {
        lineCount = lineCount + 1
        var lineItem = Document.createElement("text-green-300")
        var lineText = Document.createText("%(lineCount): %(result)")
        lineItem.append(lineText)
        outputList.append(lineItem)
    }
})

// Add some initial text to the editor
editor.setText("Hello from Wren Editor!")

System.print("Editor component initialized")