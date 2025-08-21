System.print("Hello, world!")

var f1 = Fiber.new {
    System.print("Hello, world!")
    Fiber.yield(3)
}

Fiber.yield(f1)
