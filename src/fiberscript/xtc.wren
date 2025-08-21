class Core {
    foreign static scheduleImmediately(fiber)

    static spawn(block) {
        return scheduleImmediately(Fiber.new(block))
    }

    static print(message) {
        var request = {
            "operation": "Core.print",
            "message": message
        }
        ring.submit(request)
        ring.flush()
        ring.wait(1)
        var completions = ring.reap(1)
        return completions.isEmpty ? null : completions[0]["result"]
    }
}

class Ring {
  // Submission Queue - batched request submissions
  submissionQueue { _submissionQueue }
  sqHead { _sqHead }
  sqTail { _sqTail }

  // Completion Queue - batched completions
  completionQueue { _completionQueue }
  cqHead { _cqHead }
  cqTail { _cqTail }

  // Pending operations waiting for completion
  pendingOps { _pendingOps }
  nextOpId { _nextOpId }

  construct new(sqSize, cqSize) {
    _submissionQueue = List.filled(sqSize, null)
    _completionQueue = List.filled(cqSize, null)
    _pendingOps = {}
    _sqHead = 0
    _sqTail = 0
    _cqHead = 0
    _cqTail = 0
    _nextOpId = 1
  }

  // Submit a single request - returns operation ID for tracking
  submit(request) {
    if (isSqFull) return null

    var opId = _nextOpId
    _nextOpId = _nextOpId + 1

    // Add operation tracking
    request["_opId"] = opId
    _pendingOps[opId] = Fiber.current

    // Add to submission queue
    _submissionQueue[_sqTail] = request
    _sqTail = (_sqTail + 1) % _submissionQueue.count

    return opId
  }

  // Submit multiple requests at once
  submitBatch(requests) {
    var opIds = []
    for (request in requests) {
      var opId = submit(request)
      if (opId == null) break  // SQ full
      opIds.add(opId)
    }
    return opIds
  }

  // Flush submission queue to kernel - yields to trampoline
  flush() {
    if (sqEmpty) return 0

    var submitted = sqCount
    return Fiber.yield({
      "operation": "Ring.flush",
      "ring": this,
      "count": submitted
    })
  }

  // Wait for at least minComplete operations to complete
  wait(minComplete) {
    return Fiber.yield({
      "operation": "Ring.wait",
      "ring": this,
      "minComplete": minComplete
    })
  }

  // Reap completed operations - returns list of completions
  reap(maxReap) {
    if (cqEmpty) return []

    var completions = []
    var reaped = 0

    while (!cqEmpty && reaped < maxReap) {
      var completion = _completionQueue[_cqHead]
      _completionQueue[_cqHead] = null
      _cqHead = (_cqHead + 1) % _completionQueue.count

      completions.add(completion)
      reaped = reaped + 1
    }

    return completions
  }

  // High-level: submit + flush + wait + reap
  submitAndWait(requests) {
    var opIds = submitBatch(requests)
    if (opIds.isEmpty) return []

    flush()
    wait(opIds.count)
    return reap(opIds.count)
  }

  // Queue state checks
  sqEmpty { _sqHead == _sqTail }
  sqFull { ((_sqTail + 1) % _submissionQueue.count) == _sqHead }
  sqCount {
    var count = _sqTail - _sqHead
    if (count < 0) count = count + _submissionQueue.count
    return count
  }

  cqEmpty { _cqHead == _cqTail }
  cqFull { ((_cqTail + 1) % _completionQueue.count) == _cqHead }
  cqCount {
    var count = _cqTail - _cqHead
    if (count < 0) count = count + _completionQueue.count
    return count
  }

  // Internal methods for kernel/trampoline use
  grabBatch(maxGrab) {
    var requests = []
    var grabbed = 0

    while (!sqEmpty && grabbed < maxGrab) {
      var request = _submissionQueue[_sqHead]
      _submissionQueue[_sqHead] = null
      _sqHead = (_sqHead + 1) % _submissionQueue.count

      requests.add(request)
      grabbed = grabbed + 1
    }

    return requests
  }

  completeBatch(completions) {
    for (completion in completions) {
      if (cqFull) break  // Drop completions if CQ full

      _completionQueue[_cqTail] = completion
      _cqTail = (_cqTail + 1) % _completionQueue.count

      // Resume waiting fiber if any
      var opId = completion["_opId"]
      if (opId != null && _pendingOps.containsKey(opId)) {
        var fiber = _pendingOps[opId]
        _pendingOps.remove(opId)
        Core.scheduleImmediately(fiber)
      }
    }
  }
}

var ring = Ring.new(64, 64)  // 64 entry SQ and CQ
