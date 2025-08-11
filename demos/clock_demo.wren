// Standalone clock demo - creates animated clocks from pure Wren
// Run with: zig-out/bin/xtc --wren demos/clock_demo.wren --live

var document = Document.new()
var root = document.root

// Style the root
root.updateClass("flex flex-col bg-black text-white p-4")

// Title
var title = document.createElement("text-cyan-400 text-center mb-4")
title.append(document.createText("⏰ Clock Gallery ⏰"))
root.append(title)

// Create a grid of different clock styles
var grid = document.createElement("grid grid-cols-3 gap-4")

// Spinner clocks with different speeds
var spinnerBox = document.createElement("flex flex-col items-center")
var spinnerLabel = document.createElement("text-gray-400 text-xs mb-2")
spinnerLabel.append(document.createText("Spinners"))
spinnerBox.append(spinnerLabel)

var spinner1 = document.createClock("clock interval-100 clock-spinner bg-blue-500 text-white p-2 w-4 h-2")
spinnerBox.append(spinner1)
grid.append(spinnerBox)

// Progress bars
var progressBox = document.createElement("flex flex-col items-center")
var progressLabel = document.createElement("text-gray-400 text-xs mb-2")
progressLabel.append(document.createText("Progress"))
progressBox.append(progressLabel)

var progress1 = document.createClock("clock interval-50 clock-progress bg-green-500 w-16 h-2")
progressBox.append(progress1)
grid.append(progressBox)

// Pulse effect
var pulseBox = document.createElement("flex flex-col items-center")
var pulseLabel = document.createElement("text-gray-400 text-xs mb-2")
pulseLabel.append(document.createText("Pulse"))
pulseBox.append(pulseLabel)

var pulse1 = document.createClock("clock interval-500 clock-pulse bg-red-500 w-4 h-2")
pulseBox.append(pulse1)
grid.append(pulseBox)

root.append(grid)

// Add some animated text using clocks
var animBox = document.createElement("flex flex-row gap-2 mt-6 justify-center")

var letters = ["X", "T", "C"]
var delays = [100, 150, 200]
for (i in 0...letters.count) {
  var letterClock = document.createClock("clock interval-%(delays[i]) clock-pulse bg-purple-500 text-yellow-400 p-1 w-2 h-1")
  // Note: We can't set text on clock nodes directly, they show their visual style
  animBox.append(letterClock)
}

root.append(animBox)

// Footer
var footer = document.createElement("text-gray-600 text-xs mt-6 text-center")
footer.append(document.createText("Created entirely in Wren - no XML needed!"))
root.append(footer)

System.print("Clock demo loaded! Use --live flag to see animations")