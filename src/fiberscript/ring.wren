class Core {
    foreign static scheduleImmediately(fiber)

    static spawn(block) {
        return scheduleImmediately(Fiber.new(block))
    }

    static print(message) {
        ring.post({
            "operation": "Core.print", 
            "message": message
        })
        ring.push()
        return ring.pull()
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

  take() {
    return _completionQueue.removeAt(0)
  }

  pull() {
    return Fiber.yield({
        "operation": "Ring.pull",
        "ring": this,
    })
  }
}

var ring = Ring.new()
