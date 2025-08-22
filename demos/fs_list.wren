import "fs" for FS

fun walk(path) {
  for (name in FS.list(path)) {
    var child = path + "/" + name
    System.print(child)
    if (FS.isDir(child)) {
      walk(child)
    }
  }
}

walk(".")
