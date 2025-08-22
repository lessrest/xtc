import "xtc" for Core
import "syscall" for ReadFile, WriteFile, ReadDir, IsDir

class FS {
  static read(path) {
    return Core.call(ReadFile.new(path))
  }

  static write(path, data) {
    return Core.call(WriteFile.new(path, data))
  }

  static list(path) {
    var result = Core.call(ReadDir.new(path))
    if (result == "") {
      return []
    }
    return result.split("\n")
  }

  static isDir(path) {
    return Core.call(IsDir.new(path))
  }
}
