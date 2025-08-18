import "dom" for Document, Window

Window.immediately {
  var row = Document.createElement("flex-row items-stretch grow-1")
  Document.root.append(row)

  var pleasePress = Document.createElement("grow-1 items-center bg-blue-900 text-blue-400 px-1")
  var pleasePressText = Document.createText("Press any key to continue")
  pleasePress.append(pleasePressText)
  row.append(pleasePress)

  Window.spawn {
    while (true) {
      var event = Window.waitForEvent("keypress")
      pleasePressText.updateText("You pressed %(event["key"])")
    }
  }

  for (i in ["blue", "cyan", "green", "yellow", "amber", "red", "purple"]) {
    var textbox = Document.createElement("grow-1 items-center bg-%(i)-900 text-%(i)-400 px-1")
    textbox.append(Document.createText("%(i)"))
    row.append(textbox)

    for (j in 1..9) {
      textbox.updateClass("grow-1 items-center bg-%(i)-%(j)00 text-%(i)-%(10-j)00 px-1")
      Window.sleep(250)
    }

    Window.sleep(250)
  }
}
