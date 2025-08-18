class TUI {
  static awaitEvent(nodeId, type) {
    return Fiber.yield(["wait", nodeId, type])
  }

  static sleep(ms) {
    return Fiber.yield(["sleep", ms])
  }

  static nextFrame() {
    return Fiber.yield(["frame"])
  }

  // Delegate to the foreign Tui.enqueue for compatibility
  static enqueue(fiber) {
    Tui.enqueue(fiber)
  }
}
