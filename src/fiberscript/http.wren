import "xtc" for Core
import "syscall" for HttpOpen, HttpRead, HttpCancel

class Http {
  static get(url, headTimeoutMs) {
    return Http.open(url, "GET", headTimeoutMs)
  }

  static open(url, method, headTimeoutMs) {
    var ev = Core.call(HttpOpen.new(url, method, headTimeoutMs))
    // ev is a Map from the VM: access with ["..."]
    if (ev["type"] == "error") {
      Fiber.abort("HTTP error: " + ev["message"])
    }
    if (ev["type"] != "head") {
      Fiber.abort("protocol error: expected head, got " + ev["type"]) 
    }
    return Response.new(ev["id"], ev["status"])
  }
}

class Response {
  construct new(id, status) {
    _id = id
    _status = status
    _done = false
  }

  status { _status }

  read(timeoutMs) {
    if (_done) return null
    var chunk = Core.call(HttpRead.new(_id, timeoutMs))
    // Empty string signals end of stream
    if (chunk.count == 0) {
      _done = true
      return null
    }
    return chunk
  }

  cancel() { 
    Core.call(HttpCancel.new(_id))
    _done = true 
  }
}
