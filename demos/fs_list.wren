import "fs" for Path

fun walk(path) {
  for (name in path.list()) {
    var child = path.join(name)
    System.print(child)
    if (child.isDir()) {
      walk(child)
    }
  }
}

walk(Path.cwd())
