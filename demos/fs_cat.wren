import "fs" for Path

var readme = Path.cwd().join("README.md")
System.print(readme.read())
