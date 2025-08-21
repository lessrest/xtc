import "xtc" for Core

System.print("printing from the top level")

Core.spawn {
    System.print("printing from the spawn")
}

System.print("printing after the spawn")
