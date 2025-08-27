import "syscall" for Print, Start, ReadableStreamFromFiber, SlowlyDrainStream

class Core {
    static start(fiber) {
        Start.new(fiber).call()
    }

    static print(message) {
        Print.new(message).call()
    }

    static readableStreamFromFiber(size, fiber) {
        return ReadableStreamFromFiber.new(size, fiber).call()
    }

    static readableStream(size, block) {
        return readableStreamFromFiber(size, Fiber.new(block))
    }

    static slowlyDrainStream(id) {
        return SlowlyDrainStream.new(id).call()
    }
}

class ReadableStream {
    construct new(block) {
        _stream = Core.readableStream(32, block)
    }

    drainSlowly() {
        Core.slowlyDrainStream(_stream)
    }
}

var stream = ReadableStream.new {
    var n = 0
    while (n < 10) {
        Fiber.yield("yo")
        n = n + 1
    }
}

stream.drainSlowly()
