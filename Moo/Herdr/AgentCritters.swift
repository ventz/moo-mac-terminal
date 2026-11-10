//
//  AgentCritters.swift
//  Moo
//
//  Settings → herdr → "Give agents names and pictures": a made-up name and a
//  three-line ASCII critter for each agent in the panel, whose face shows
//  what the agent is doing. Off by default.
//
//  Names and species come from a stable hash of the agent's row id (FNV-1a,
//  not Swift's per-launch Hasher), so an agent keeps its name across
//  redraws and launches with nothing stored. Two agents never share a name:
//  a taken name moves to the next free one, in the order of the rows' ids.
//

import Foundation

nonisolated enum AgentCritters {
    struct Identity: Equatable, Sendable {
        let name: String
        let species: Int
    }

    static let names = [
        "alder", "basil", "cinder", "clove", "dapple", "ember", "fennel", "ferro",
        "gale", "ginger", "holly", "inkwell", "jolt", "juniper", "kestrel", "kipper",
        "larch", "lichen", "marrow", "mote", "nettle", "nib", "opal", "orrin",
        "pebble", "pip", "quince", "ruckus", "sorrel", "sprocket", "tansy", "thimble",
        "tumble", "umber", "vetch", "widget", "wren", "yarrow", "zest", "zinnia",
    ]

    /// A face: two eyes and a mouth, one character each.
    struct Face: Equatable, Sendable {
        let leftEye: Character
        let mouth: Character
        let rightEye: Character
    }

    static func face(for status: HerdrAgentStatus) -> Face {
        switch status {
        case .working: return Face(leftEye: "o", mouth: ".", rightEye: "o")
        case .blocked: return Face(leftEye: "O", mouth: "_", rightEye: "O")
        case .done: return Face(leftEye: "^", mouth: "_", rightEye: "^")
        case .idle: return Face(leftEye: "-", mouth: ".", rightEye: "-")
        case .error: return Face(leftEye: "x", mouth: "_", rightEye: "x")
        case .unknown: return Face(leftEye: ".", mouth: "_", rightEye: ".")
        }
    }

    /// Each species: three lines of seven columns. `L`, `M` and `R` are
    /// the face's left eye, mouth and right eye, and appear nowhere else.
    static let species: [[String]] = [
        // cat
        [#" /\_/\ "#, #"( LMR )"#, #" > ^ < "#],
        // owl
        [#" ,___, "#, #" (LMR) "#, #" /)_)  "#],
        // rabbit
        [#" (\ /) "#, #" (LMR) "#, #" (")(")"#],
        // robot
        [#" .---. "#, #" |LMR| "#, #" '-=-' "#],
        // ghost
        [#"  .-.  "#, #" (LMR) "#, #" /`~`\ "#],
    ]

    /// The critter's three lines, with its face for this status.
    static func art(species index: Int, status: HerdrAgentStatus) -> String {
        let face = face(for: status)
        let lines = species[index % species.count].map { line in
            String(line.map { character -> Character in
                switch character {
                case "L": return face.leftEye
                case "M": return face.mouth
                case "R": return face.rightEye
                default: return character
                }
            })
        }
        return lines.joined(separator: "\n")
    }

    /// A name and species for every id, no name used twice while there are
    /// names to go round.
    static func assign(_ ids: [String]) -> [String: Identity] {
        var identities: [String: Identity] = [:]
        var taken: Set<Int> = []
        for id in Set(ids).sorted() {
            let hash = stableHash(id)
            var index = Int(hash % UInt64(names.count))
            if taken.count < names.count {
                while taken.contains(index) { index = (index + 1) % names.count }
            }
            taken.insert(index)
            identities[id] = Identity(
                name: names[index],
                species: Int((hash >> 32) % UInt64(species.count))
            )
        }
        return identities
    }

    /// FNV-1a: the same on every launch and every Mac.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
