// Simple test script that creates a basic Tetris-like display
import "dom" for document, Element

var root = document.root

// Create container
var container = document.createElement("bg-gray-900 p-4")
root.append(container)

// Add title
var title = document.createElement("text-white text-2xl mb-4")
var titleText = document.createText("TETRIS TEST")
title.append(titleText)
container.append(title)

// Create game board
var board = document.createElement("border-2 border-white p-2")
container.append(board)

// Add some rows
for (y in 0...10) {
  var row = document.createElement("flex")
  for (x in 0...10) {
    var cell = document.createElement("w-2 h-1 bg-gray-800 border border-gray-600")
    var cellText = document.createText(".")
    cell.append(cellText)
    row.append(cell)
  }
  board.append(row)
}

System.print("Tetris test display created")