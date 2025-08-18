import "tui" for TUI
import "dom" for Document

TUI.enqueue(Fiber.new {
  System.print("Stage 1: printing and sleeping")
  for (i in 0..5) {
    System.print("round %(i); sleeping 100ms")
    TUI.sleep(100)
  }

  var row = Document.createElement("flex-row items-stretch grow-1")
  Document.root.append(row)

  for (i in ["blue", "cyan", "green", "yellow", "amber", "red", "purple"]) {
    var textbox = Document.createElement("grow-1 items-center bg-%(i)-900 text-%(i)-400 px-1")
    textbox.append(Document.createText("%(i)"))
    row.append(textbox)

    for (j in 1..9) {
      textbox.updateClass("grow-1 items-center bg-%(i)-%(j)00 text-%(i)-%(10-j)00 px-1")
      TUI.sleep(250)
    }

    TUI.sleep(250)
  }
})
