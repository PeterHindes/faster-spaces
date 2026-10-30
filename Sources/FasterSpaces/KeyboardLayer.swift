import CoreGraphics
import Foundation

// MARK: - Layer model

/// One source-key override in the Caps Lock layer. The layer's default action
/// is passthrough; a mapping only changes the keys the user explicitly adds.
struct KeyboardLayerMapping: Codable, Identifiable, Equatable {
    var id: UUID
    var sourceKeyCode: UInt16
    var action: KeyboardLayerAction
    var targetKeyCode: UInt16
    var control: Bool
    var option: Bool
    var command: Bool
    var shift: Bool

    init(
        id: UUID = UUID(),
        sourceKeyCode: UInt16,
        action: KeyboardLayerAction = .send,
        targetKeyCode: UInt16 = 0,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false
    ) {
        self.id = id
        self.sourceKeyCode = sourceKeyCode
        self.action = action
        self.targetKeyCode = targetKeyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    init(
        source: KeyboardKey,
        target: KeyboardKey,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false
    ) {
        self.init(
            sourceKeyCode: source.code,
            action: .send,
            targetKeyCode: target.code,
            control: control,
            option: option,
            command: command,
            shift: shift
        )
    }

    var flags: CGEventFlags {
        var result: CGEventFlags = []
        if control { result.insert(.maskControl) }
        if option { result.insert(.maskAlternate) }
        if command { result.insert(.maskCommand) }
        if shift { result.insert(.maskShift) }
        return result
    }

    var sourceName: String { KeyboardKeyCatalog.name(for: sourceKeyCode) }
    var targetName: String { KeyboardKeyCatalog.name(for: targetKeyCode) }
}

enum KeyboardLayerAction: String, Codable, CaseIterable, Identifiable {
    case passthrough
    case send
    case swallow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: return "Passthrough"
        case .send: return "Send Key"
        case .swallow: return "Do Nothing"
        }
    }

    var detail: String {
        switch self {
        case .passthrough: return "Send the original key unchanged"
        case .send: return "Send a different key / shortcut"
        case .swallow: return "Swallow the key while the layer is held"
        }
    }
}

// MARK: - Key catalog

struct KeyboardKey: Identifiable, Hashable {
    let code: UInt16
    let name: String
    let category: String

    var id: UInt16 { code }
}

enum KeyboardKeyCatalog {
    static let all: [KeyboardKey] = {
        var keys: [KeyboardKey] = []

        func add(_ category: String, _ entries: [(UInt16, String)]) {
            keys.append(contentsOf: entries.map { KeyboardKey(code: $0.0, name: $0.1, category: category) })
        }

        add("Letters", [
            (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"), (5, "G"),
            (6, "Z"), (7, "X"), (8, "C"), (9, "V"), (11, "B"), (12, "Q"),
            (13, "W"), (14, "E"), (15, "R"), (16, "Y"), (17, "T"), (31, "O"),
            (32, "U"), (34, "I"), (35, "P"), (37, "L"), (38, "J"), (40, "K"),
            (45, "N"), (46, "M"),
        ])
        add("Numbers", [
            (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"), (23, "5"),
            (25, "9"), (26, "7"), (28, "8"), (29, "0"),
        ])
        add("Punctuation", [
            (24, "="), (27, "-"), (30, "]"), (33, "["), (39, "'"), (41, ";"),
            (42, "\\"), (43, ","), (44, "/"), (47, "."), (50, "`"),
        ])
        add("Editing", [
            (36, "Return"), (48, "Tab"), (49, "Space"), (51, "Delete"),
            (53, "Escape"), (117, "Forward Delete"), (115, "Home"),
            (119, "End"), (116, "Page Up"), (121, "Page Down"),
        ])
        add("Arrows", [
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
        ])
        add("Function", [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
            (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
            (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ])
        return keys.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.code < $1.code
        }
    }()

    static let categories: [String] = ["Letters", "Numbers", "Punctuation", "Editing", "Arrows", "Function"]

    static func name(for code: UInt16) -> String {
        all.first(where: { $0.code == code })?.name ?? "Key \(code)"
    }

    static func key(_ name: String) -> KeyboardKey? {
        all.first(where: { $0.name == name })
    }

    static func letter(_ name: String) -> KeyboardKey? {
        all.first(where: { $0.name == name })
    }
}

// MARK: - Quick presets

enum KeyboardLayerPreset: String, CaseIterable, Identifiable {
    case wasdArrows
    case hjklArrows
    case ijklArrows
    case homeRowSymbols
    case homeRowFunctions
    case spaceReturn
    case deleteForward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wasdArrows: return "WASD → Arrows"
        case .hjklArrows: return "HJKL → Arrows"
        case .ijklArrows: return "IJKL → Arrows"
        case .homeRowSymbols: return "Home row → Symbols"
        case .homeRowFunctions: return "Home row → Functions"
        case .spaceReturn: return "Space → Return"
        case .deleteForward: return "Delete → Forward Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .wasdArrows, .hjklArrows, .ijklArrows: return "arrowkeys"
        case .homeRowSymbols: return "textformat.abc"
        case .homeRowFunctions: return "function"
        case .spaceReturn: return "return"
        case .deleteForward: return "delete.left"
        }
    }

    var mappings: [KeyboardLayerMapping] {
        func key(_ name: String) -> KeyboardKey {
            KeyboardKeyCatalog.key(name) ?? KeyboardKey(code: 0, name: name, category: "")
        }

        switch self {
        case .wasdArrows:
            return [
                KeyboardLayerMapping(source: key("W"), target: key("↑")),
                KeyboardLayerMapping(source: key("A"), target: key("←")),
                KeyboardLayerMapping(source: key("S"), target: key("↓")),
                KeyboardLayerMapping(source: key("D"), target: key("→")),
            ]
        case .hjklArrows:
            return [
                KeyboardLayerMapping(source: key("H"), target: key("←")),
                KeyboardLayerMapping(source: key("J"), target: key("↓")),
                KeyboardLayerMapping(source: key("K"), target: key("↑")),
                KeyboardLayerMapping(source: key("L"), target: key("→")),
            ]
        case .ijklArrows:
            return [
                KeyboardLayerMapping(source: key("I"), target: key("↑")),
                KeyboardLayerMapping(source: key("J"), target: key("←")),
                KeyboardLayerMapping(source: key("K"), target: key("↓")),
                KeyboardLayerMapping(source: key("L"), target: key("→")),
            ]
        case .homeRowSymbols:
            return [
                KeyboardLayerMapping(source: key("A"), target: key("1"), shift: true),
                KeyboardLayerMapping(source: key("S"), target: key("2"), shift: true),
                KeyboardLayerMapping(source: key("D"), target: key("3"), shift: true),
                KeyboardLayerMapping(source: key("F"), target: key("4"), shift: true),
                KeyboardLayerMapping(source: key("G"), target: key("5"), shift: true),
                KeyboardLayerMapping(source: key("H"), target: key("6"), shift: true),
                KeyboardLayerMapping(source: key("J"), target: key("7"), shift: true),
                KeyboardLayerMapping(source: key("K"), target: key("8"), shift: true),
                KeyboardLayerMapping(source: key("L"), target: key("9"), shift: true),
                KeyboardLayerMapping(source: key(";"), target: key("0"), shift: true),
            ]
        case .homeRowFunctions:
            let sources = ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";"]
            let targets = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10"]
            return zip(sources, targets).map {
                KeyboardLayerMapping(source: key($0.0), target: key($0.1))
            }
        case .spaceReturn:
            return [KeyboardLayerMapping(source: key("Space"), target: key("Return"))]
        case .deleteForward:
            return [KeyboardLayerMapping(source: key("Delete"), target: key("Forward Delete"))]
        }
    }
}
