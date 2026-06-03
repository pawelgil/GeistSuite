import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let arguments = CommandLine.arguments

let usage = """
USAGE: geistcast <subcommand>

SUBCOMMANDS:
  version   Print version
  help      Print this message

NOTE:
  list and watch are not yet reimplemented as socket clients of the
  GeistCast daemon. They previously embedded the discovery + watch
  pipeline directly; that pipeline now lives in the macOS app target.
"""

guard arguments.count >= 2 else {
    print(usage)
    exit(0)
}

switch arguments[1] {
case "version":
    print("geistcast 0.1.0")
case "help", "--help", "-h":
    print(usage)
default:
    FileHandle.standardError.write(Data("Unknown command: \(arguments[1])\n".utf8))
    print(usage)
    exit(1)
}
