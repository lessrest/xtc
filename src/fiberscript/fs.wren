import "xtc" for Core
import "syscall" for ReadFile, WriteFile, ReadDir, IsDir, Exists, Remove

class Path {
  construct new(path) {
    _path = path
  }

  static cwd() {
    return Path.new(".")
  }

  join(child) {
    var sep = _path.endsWith("/") ? "" : "/"
    return Path.new(_path + sep + child)
  }

  read() {
    return Core.call(ReadFile.new(_path))
  }

  write(data) {
    return Core.call(WriteFile.new(_path, data))
  }

  list() {
    var result = Core.call(ReadDir.new(_path))
    if (result == "") {
      return []
    }
    return result.split("\n")
  }

  isDir() {
    return Core.call(IsDir.new(_path))
  }

  exists() {
    return Core.call(Exists.new(_path))
  }

  remove() {
    return Core.call(Remove.new(_path))
  }

  toString() { _path }
}
