import Foundation
import TOML

// MARK: - DecodableDefault

/// Property wrapper that provides default values for missing keys during decoding.
/// Based on https://www.swiftbysundell.com/tips/default-decoding-values/
enum DecodableDefault {
    protocol Source {
        associatedtype Value: Decodable
        static var defaultValue: Value { get }
    }

    @propertyWrapper
    struct Wrapper<S: Source>: Decodable {
        typealias Value = S.Value
        var wrappedValue = S.defaultValue

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            wrappedValue = try container.decode(Value.self)
        }

        init() {}
    }
}

extension KeyedDecodingContainer {
    func decode<T>(
        _ type: DecodableDefault.Wrapper<T>.Type, forKey key: Key
    ) throws -> DecodableDefault.Wrapper<T> {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}

// MARK: - Default value sources

extension DecodableDefault {
    enum True: Source { static var defaultValue: Bool { true } }
    enum False: Source { static var defaultValue: Bool { false } }
    enum EmptyString: Source { static var defaultValue: String { "" } }
    enum LineHeight: Source { static var defaultValue: CGFloat { 1.2 } }
    enum TitleBarBrightness: Source { static var defaultValue: CGFloat { -0.08 } }
    enum TabBarBrightness: Source { static var defaultValue: CGFloat { 0.05 } }
}

// MARK: - RemoteEntry

struct RemoteEntry: Decodable {
    let name: String
    let address: String
}

// MARK: - VeilConfig

struct VeilConfig: Decodable {
    @DecodableDefault.Wrapper<DecodableDefault.LineHeight>
    var line_height: CGFloat
    @DecodableDefault.Wrapper<DecodableDefault.True>
    var ligatures: Bool
    @DecodableDefault.Wrapper<DecodableDefault.EmptyString>
    var nvim_path: String
    @DecodableDefault.Wrapper<DecodableDefault.EmptyString>
    var nvim_appname: String
    @DecodableDefault.Wrapper<DecodableDefault.False>
    var native_tabs: Bool
    @DecodableDefault.Wrapper<DecodableDefault.TitleBarBrightness>
    var titlebar_brightness_offset: CGFloat
    @DecodableDefault.Wrapper<DecodableDefault.TabBarBrightness>
    var tabbar_brightness_offset: CGFloat

    var remote: [RemoteEntry]?

    static var current: VeilConfig = load()

    static func load() -> VeilConfig {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/veil/veil.toml")

        guard let data = try? String(contentsOf: configPath, encoding: .utf8) else {
            return VeilConfig()
        }

        do {
            return try TOMLDecoder().decode(VeilConfig.self, from: data)
        } catch {
            return VeilConfig()
        }
    }
}
