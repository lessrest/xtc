# Wren Event System Roadmap for XTC

Internal development roadmap for implementing a live event scripting system using Wren, progressing from simple callbacks to a fiber-based architecture.

## Phase 1: Basic Event Callbacks
**Goal**: Enable simple event handling through registered callbacks

### 1.1 Event Registration Infrastructure
- [ ] Add event listener tracking to DOM nodes (`src/dom.zig`)
  - Store map of event type → Wren handle for each node
  - Support basic events: `click`, `keypress`, `focus`, `blur`
- [ ] Extend `ScriptContext` with event registration methods
  - `DOM.addEventListener(nodeId, eventType, handler)`
  - `DOM.removeEventListener(nodeId, eventType)`
- [ ] Implement Wren handle management for callbacks
  - Store handles in a global registry to prevent GC
  - Clean up handles when nodes are destroyed

### 1.2 Event Dispatch System
- [ ] Create event loop integration in `src/live.zig`
  - Queue events during input processing
  - Dispatch events after layout/paint cycle
- [ ] Build event object wrapper
  - Pass event data to Wren (type, target, key, mouse coords)
  - Implement `preventDefault()` and `stopPropagation()`
- [ ] Add error boundaries for script exceptions
  - Catch and log errors without crashing
  - Optional debug mode to break on errors

### 1.3 Example Implementation
```wren
// Simple callback-based event handling
class Button {
  construct new(text) {
    _element = document.createElement("px-4 py-2 bg-blue-500")
    _textNode = document.createText(text)
    _element.append(_textNode)
    
    DOM.addEventListener(_element.id, "click", Fn.new {
      System.print("Button clicked: " + text)
    })
  }
}
```

## Phase 2: State Management & Data Binding
**Goal**: Enable reactive UI updates through state changes

### 2.1 Observable State
- [ ] Implement observable values in Wren
  - `Observable` class with getter/setter
  - Automatic notification of listeners on change
- [ ] Create DOM binding helpers
  - `DOM.bindText(nodeId, observable)`
  - `DOM.bindClass(nodeId, className, observable)`
- [ ] Add dirty tracking for efficient updates
  - Mark affected nodes when observables change
  - Batch updates in next frame

### 2.2 Component System
- [ ] Design component lifecycle
  - `mount()`, `unmount()`, `update()` hooks
  - Automatic cleanup of event listeners
- [ ] Build component registry
  - Track active components
  - Handle component destruction

### 2.3 Example Implementation
```wren
class Counter {
  construct new() {
    _count = Observable.new(0)
    _element = document.createElement("flex flex-col gap-2")
    
    var display = document.createElement("text-xl")
    DOM.bindText(display.id, _count)
    
    var button = document.createElement("px-4 py-2 bg-green-500")
    button.append(document.createText("Increment"))
    DOM.addEventListener(button.id, "click", Fn.new {
      _count.value = _count.value + 1
    })
    
    _element.append(display)
    _element.append(button)
  }
}
```

## Phase 3: Timer & Animation Support
**Goal**: Enable time-based updates and smooth animations

### 3.1 Timer Integration
- [ ] Expose timer functions to Wren
  - `Timer.after(ms, callback)`
  - `Timer.every(ms, callback)`
  - `Timer.cancel(timerId)`
- [ ] Integrate with main event loop
  - Check timer queue each frame
  - Execute due callbacks

### 3.2 Animation Frame Callbacks
- [ ] Implement `requestAnimationFrame` equivalent
  - `DOM.onFrame(callback)`
  - Pass elapsed time and delta to callback
- [ ] Add easing functions library
- [ ] Build animation helper classes

## Phase 4: Fiber-Based Async Event System
**Goal**: Use Wren fibers for elegant async programming

### 4.1 Fiber Scheduler Foundation
- [ ] Implement fiber scheduler in Zig (`src/wren_scheduler.zig`)
  - Manage fiber queue and execution
  - Handle fiber suspension/resumption
  - Track fiber states (running, suspended, dead)
- [ ] Create Wren-side scheduler interface
  - `Scheduler.current` - get current fiber
  - `Scheduler.yield()` - yield to scheduler
  - `Scheduler.spawn(fn)` - create new fiber

### 4.2 Async Event Handling
- [ ] Convert events to fiber-based model
  - Events resume waiting fibers instead of calling callbacks
  - `DOM.waitForEvent(nodeId, eventType)` - suspends fiber until event
- [ ] Implement event streams
  - Multiple fibers can wait on same event
  - Event broadcasting to all waiting fibers

### 4.3 Example Implementation
```wren
import "scheduler" for Scheduler

class AsyncButton {
  construct new(text) {
    _element = document.createElement("px-4 py-2 bg-purple-500")
    _element.append(document.createText(text))
    
    // Spawn a fiber to handle clicks
    Scheduler.spawn {
      while (true) {
        var event = DOM.waitForEvent(_element.id, "click")
        handleClick(event)
      }
    }
  }
  
  handleClick(event) {
    System.print("Async click at: " + event.timestamp)
  }
}
```

## Phase 5: Advanced Fiber Patterns
**Goal**: Implement sophisticated async patterns

### 5.1 Async/Await Style Primitives
- [ ] Build Promise-like abstraction
  - `Future` class for async values
  - `Future.all()`, `Future.race()` combinators
- [ ] Add async DOM operations
  - `DOM.waitForAnimation(nodeId)`
  - `DOM.waitForTransition(nodeId)`

### 5.2 Coroutine-Based Animations
- [ ] Implement animation coroutines
```wren
class Animator {
  static fadeIn(element, duration) {
    var start = System.clock
    while (true) {
      var elapsed = System.clock - start
      if (elapsed >= duration) break
      
      var progress = elapsed / duration
      DOM.setOpacity(element.id, progress)
      Scheduler.nextFrame()  // Suspend until next frame
    }
    DOM.setOpacity(element.id, 1.0)
  }
}
```

### 5.3 Channel-Based Communication
- [ ] Implement CSP-style channels
  - Fibers communicate via channels
  - Blocking send/receive operations
- [ ] Build actor model on top
  - Each component as an actor
  - Message passing between components

### 5.4 Example: Complex Interaction
```wren
class DragHandler {
  construct new(element) {
    _element = element
    Scheduler.spawn { handleDrag() }
  }
  
  handleDrag() {
    while (true) {
      // Wait for mousedown
      var down = DOM.waitForEvent(_element.id, "mousedown")
      var startX = down.x
      var startY = down.y
      
      // Start drag fiber
      var dragFiber = Scheduler.spawn {
        while (true) {
          var move = DOM.waitForEvent("document", "mousemove")
          updatePosition(move.x - startX, move.y - startY)
        }
      }
      
      // Wait for mouseup
      DOM.waitForEvent("document", "mouseup")
      
      // Stop drag fiber
      dragFiber.cancel()
    }
  }
  
  updatePosition(dx, dy) {
    DOM.setTransform(_element.id, "translate(" + dx + "," + dy + ")")
  }
}
```

## Phase 6: Performance & Debugging
**Goal**: Optimize and provide development tools

### 6.1 Performance Optimizations
- [ ] Implement fiber pooling
- [ ] Add priority-based scheduling
- [ ] Optimize event dispatch paths
- [ ] Profile and minimize Wren↔Zig transitions

### 6.2 Developer Tools
- [ ] Fiber inspector
  - Show active fibers and their states
  - Stack traces for suspended fibers
- [ ] Event flow visualization
- [ ] Performance profiler
- [ ] Hot reload support for Wren scripts

## Technical Considerations

### Memory Management
- Wren handles are reference counted
- Need careful management when storing in Zig structures
- Consider weak references for event listeners

### Thread Safety
- XTC is currently single-threaded
- Fiber scheduling happens on main thread
- Future: could move Wren VM to separate thread with message passing

### Error Handling
- Fibers provide natural error boundaries
- Errors in one fiber don't affect others
- Need strategy for unhandled errors

### Integration Points
- Event system needs hooks in:
  - `src/live.zig` - input processing
  - `src/dom.zig` - node lifecycle
  - `src/wren_runner.zig` - VM management
  - `src/tty.zig` - render callbacks

## Success Metrics
- Clean, ergonomic API for common patterns
- Performance: <1ms overhead for event dispatch
- Stability: graceful handling of script errors
- Developer experience: clear debugging and error messages

## Open Questions
1. Should we support multiple VMs for isolation?
2. How to handle memory pressure from many fibers?
3. What's the right abstraction level for DOM updates?
4. Should we implement virtual DOM diffing in Wren?
5. How to integrate with potential future WebAssembly support?

## References
- [Wren Fiber Documentation](https://wren.io/concurrency.html)
- [CSP in Go](https://go.dev/doc/effective_go#concurrency)
- [Lua Coroutines](https://www.lua.org/manual/5.4/manual.html#2.6)
- [JavaScript Event Loop](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Event_loop)