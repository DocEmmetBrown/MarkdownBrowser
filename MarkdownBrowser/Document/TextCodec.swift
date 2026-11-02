import Foundation

nonisolated enum TextEncoding: Equatable, Sendable {
    case utf8(bom: Bool)
    case utf16LittleEndian
    case utf16BigEndian
    /// Fallback for non-UTF-8 bytes; maps every byte 1:1 so unmodified content round-trips.
    case latin1
}

nonisolated struct DecodedText: Equatable, Sendable {
    var text: String
    var encoding: TextEncoding
    var lineSeparator: String
}

nonisolated enum TextCodec {
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    static func decode(_ data: Data) -> DecodedText {
        let (text, encoding) = decodeText(data)
        return DecodedText(text: text, encoding: encoding, lineSeparator: lineSeparator(of: text))
    }

    private static func decodeText(_ data: Data) -> (String, TextEncoding) {
        if data.starts(with: utf8BOM), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8(bom: true))
        }
        if data.starts(with: utf16LEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if data.starts(with: utf16BEBOM), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8(bom: false))
        }
        return (String(decoding: data.map { UInt16($0) }, as: UTF16.self), .latin1)
    }

    /// Encodes text in its original encoding; text that no longer fits Latin-1 is upgraded to UTF-8.
    static func encode(_ text: String, as encoding: TextEncoding) -> (Data, TextEncoding) {
        switch encoding {
        case .utf8(let bom):
            return ((bom ? Data(utf8BOM) : Data()) + Data(text.utf8), encoding)
        case .utf16LittleEndian:
            return (Data(utf16LEBOM) + (text.data(using: .utf16LittleEndian) ?? Data()), encoding)
        case .utf16BigEndian:
            return (Data(utf16BEBOM) + (text.data(using: .utf16BigEndian) ?? Data()), encoding)
        case .latin1:
            let units = Array(text.utf16)
            guard units.allSatisfy({ $0 <= 0xFF }) else { return (Data(text.utf8), .utf8(bom: false)) }
            return (Data(units.map { UInt8($0) }), .latin1)
        }
    }

    /// The dominant line separator, so the editor writes new lines the way the file already does.
    static func lineSeparator(of text: String) -> String {
        var crlf = 0
        var lf = 0
        var cr = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous == 0x0D {
                    crlf += 1
                    cr -= 1
                } else {
                    lf += 1
                }
            } else if byte == 0x0D {
                cr += 1
            }
            previous = byte
        }
        if crlf > lf && crlf >= cr { return "\r\n" }
        if cr > lf && cr > crlf { return "\r" }
        return "\n"
    }
}
