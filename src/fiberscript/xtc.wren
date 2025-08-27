class Core {
    foreign static syscall(fiber, request)

    static call(request) {
        var result = syscall(Fiber.current, request)
        if (result == Fiber.current) {
            return Fiber.suspend()
        } else {
            return result
        }
    }
}

