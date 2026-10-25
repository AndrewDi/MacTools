import Foundation

enum PortablePreferencesValidation {
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }

    static func text(_ value: String, maximumBytes: Int, allowsEmpty: Bool = false) -> Bool {
        (allowsEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func endpoint(_ value: String) -> Bool {
        guard text(value, maximumBytes: 2_048), let url = URLComponents(string: value),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.host?.isEmpty == false, url.url != nil else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}
