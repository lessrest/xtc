import "http" for Http

var f = Fiber.new {
  System.print("fetching...")
  var res = Http.get("https://example.com", 10000)
  System.print("status: %(res.status)")

  var total = 0
  var i = 0
  while (true) {
    var chunk = res.read(5000)
    if (chunk == null) break
    total = total + chunk.count
    i = i + 1
    if (i <= 5) System.print("chunk %(i): %(chunk.count) bytes")
  }

  System.print("total bytes: %(total)")
}

f.call()
