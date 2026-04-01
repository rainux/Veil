/// Parses command-line arguments, separating Veil's own flags from
/// arguments that should be forwarded to nvim. Filters out macOS/Xcode
/// injected arguments (-NS*, -Apple*).
enum CliArgParser {
    struct Result {
        var nvimArgs: [String] = []
        var renderer: NvimView.Renderer = .metal
    }

    static func parse(_ rawArgs: [String]) -> Result {
        var result = Result()
        var skip = false
        var iter = rawArgs.dropFirst().makeIterator()
        while let arg = iter.next() {
            if skip { skip = false; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                skip = true
                continue
            }
            if arg == "--veil-renderer" {
                if let value = iter.next(), value.lowercased() == "coretext" {
                    result.renderer = .coretext
                }
                continue
            }
            result.nvimArgs.append(arg)
        }
        return result
    }
}
