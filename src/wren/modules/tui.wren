class TUI {
  static awaitEvent(nodeId, type) {
    Tui.registerWait(nodeId, type, Fiber.current)
    return Fiber.yield()
  }

  static sleep(ms) {
    Tui.registerTimer(ms, Fiber.current)
    return Fiber.yield()
  }

  static nextFrame() {
    Tui.registerNextFrame(Fiber.current)
    return Fiber.yield()
  }
}


