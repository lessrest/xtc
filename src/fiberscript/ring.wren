class Core {
    foreign static scheduleImmediately(fiber)

    static spawn(block) {
        return scheduleImmediately(Fiber.new(block))
    }
}

class Ring {
  submissionQueue { _submissionQueue }
  completionQueue { _completionQueue }

  construct new() {
    _submissionQueue = []
    _completionQueue = []
  }

  post(request) {
    _submissionQueue.add(request)
  }

  push() {
    return Fiber.yield({
        "operation": "Ring.post",
        "ring": this,
    })
  }

  grab() {
    return submissionQueue.remove(0)
  }

  give(response) {
    _completionQueue.add(response)
  }

  pull() {
    return Fiber.yield({
        "operation": "Ring.pull",
        "ring": this,
    })
  }
}

var ring = Ring.new()
