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
            if arg.hasPrefix("--veil-") {
                let (name, inlineValue) = splitFlag(arg)
                switch name {
                case "--veil-renderer":
                    let value = (inlineValue ?? iter.next())?.lowercased()
                    if value == "coretext" { result.renderer = .coretext }
                default:
                    break
                }
                continue
            }
            result.nvimArgs.append(arg)
        }
        return result
    }

    /// Split `--flag=value` into `("--flag", "value")`.
    /// Returns `("--flag", nil)` for flags without `=`.
    private static func splitFlag(_ arg: String) -> (String, String?) {
        guard let eqIndex = arg.firstIndex(of: "=") else { return (arg, nil) }
        let name = String(arg[..<eqIndex])
        let value = String(arg[arg.index(after: eqIndex)...])
        return (name, value)
    }
}
