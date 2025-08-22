import "syscall" for Sleep

class Core {
    foreign static syscall(fiber, request)
    foreign static submitBatch(fiber, batch)

    static call(request) {
        var result = syscall(Fiber.current, request)
        if (result == Fiber.current) {
            return Fiber.suspend()
        } else {
            return result
        }
    }

    static sleep(seconds) {
        return Core.call(Sleep.new(seconds))
    }

    static submit(batch) {
        return submitBatch(Fiber.current, batch)
    }
}

