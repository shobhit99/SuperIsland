import Foundation

struct EmojiSearchResult: Identifiable, Hashable {
    let emoji: String
    let name: String
    let keywords: [String]
    let rank: Int

    var id: String { emoji }
}

final class EmojiSearchIndex {
    private struct Builder {
        let emoji: String
        var name: String
        var keywords: Set<String>
        var rank: Int
    }

    static let shared = EmojiSearchIndex()

    private let allResults: [EmojiSearchResult]
    private let resultsByEmoji: [String: EmojiSearchResult]
    private let defaultEmojiOrder: [String]

    private init() {
        let built = Self.buildIndex()
        allResults = built.results
        resultsByEmoji = Dictionary(uniqueKeysWithValues: built.results.map { ($0.emoji, $0) })
        defaultEmojiOrder = built.defaultEmojiOrder
    }

    func result(for emoji: String) -> EmojiSearchResult? {
        resultsByEmoji[emoji]
    }

    func search(query rawQuery: String, recents: [String], limit: Int) -> [EmojiSearchResult] {
        let query = Self.normalize(rawQuery)
        if query.isEmpty {
            var ordered: [EmojiSearchResult] = []
            var seen = Set<String>()

            for emoji in recents {
                guard let result = resultsByEmoji[emoji], seen.insert(result.id).inserted else { continue }
                ordered.append(result)
                if ordered.count >= limit { return ordered }
            }

            for emoji in defaultEmojiOrder {
                guard let result = resultsByEmoji[emoji], seen.insert(result.id).inserted else { continue }
                ordered.append(result)
                if ordered.count >= limit { return ordered }
            }

            return ordered
        }

        let queryTokens = Self.tokens(from: query)
        guard !queryTokens.isEmpty else { return [] }

        let ranked = allResults.compactMap { result -> (EmojiSearchResult, Int)? in
            let score = score(result: result, query: query, queryTokens: queryTokens)
            guard score > 0 else { return nil }
            return (result, score)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.rank != rhs.0.rank { return lhs.0.rank < rhs.0.rank }
                return lhs.0.name < rhs.0.name
            }
            .prefix(limit)
            .map(\.0)
    }

    private func score(result: EmojiSearchResult, query: String, queryTokens: [String]) -> Int {
        var total = 0
        let name = Self.normalize(result.name)

        for token in queryTokens {
            var best = 0

            if name == token {
                best = max(best, 600)
            } else if name.hasPrefix(token) {
                best = max(best, 280)
            } else if name.contains(token) {
                best = max(best, 180)
            }

            for keyword in result.keywords {
                let normalizedKeyword = Self.normalize(keyword)

                if normalizedKeyword == token {
                    best = max(best, 520)
                } else if normalizedKeyword.hasPrefix(token) {
                    best = max(best, 320)
                } else if normalizedKeyword.contains(token) {
                    best = max(best, 220)
                } else if Self.isFuzzyMatch(token, in: normalizedKeyword) {
                    best = max(best, 120)
                }
            }

            guard best > 0 else { return 0 }
            total += best
        }

        if name.hasPrefix(query) {
            total += 120
        } else if name.contains(query) {
            total += 60
        }

        return total - min(result.rank, 400)
    }

    private static func buildIndex() -> (results: [EmojiSearchResult], defaultEmojiOrder: [String]) {
        var builders: [String: Builder] = [:]
        var rank = 0

        func insert(_ emoji: String, name: String, keywords: [String], rankOverride: Int? = nil) {
            let normalizedName = prettify(name)
            let mergedKeywords = Set(tokens(from: normalizedName) + keywords.map(normalize))

            if var existing = builders[emoji] {
                if existing.name.count > normalizedName.count {
                    existing.name = normalizedName
                }
                existing.keywords.formUnion(mergedKeywords)
                existing.rank = min(existing.rank, rankOverride ?? existing.rank)
                builders[emoji] = existing
                return
            }

            builders[emoji] = Builder(
                emoji: emoji,
                name: normalizedName,
                keywords: mergedKeywords,
                rank: rankOverride ?? rank
            )
            rank += 1
        }

        for scalar in emojiScalars() {
            let value = scalar.value
            if isExcludedBaseScalar(value) { continue }
            guard let name = scalar.properties.name?.lowercased() else { continue }
            insert(preferredDisplay(for: scalar), name: name, keywords: [])

            if scalar.properties.isEmojiModifierBase {
                for modifier in skinToneModifiers {
                    let modifierName = modifier.properties.name?
                        .lowercased()
                        .replacingOccurrences(of: "emoji modifier ", with: "")
                        .replacingOccurrences(of: "fitzpatrick ", with: "")
                        ?? "skin tone"
                    insert(
                        preferredDisplay(for: scalar) + String(modifier),
                        name: "\(name) \(modifierName)",
                        keywords: ["skin tone", modifierName]
                    )
                }
            }
        }

        for (emoji, name, keywords) in keycapEntries {
            insert(emoji, name: name, keywords: keywords)
        }

        for code in Locale.Region.isoRegions.map(\.identifier).sorted() {
            let normalizedCode = code.uppercased()
            guard normalizedCode.count == 2,
                  normalizedCode.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }),
                  let flag = flagEmoji(for: normalizedCode) else {
                continue
            }

            let localizedName = Locale.current.localizedString(forRegionCode: normalizedCode) ?? normalizedCode
            insert(
                flag,
                name: "\(localizedName.lowercased()) flag",
                keywords: ["flag", normalizedCode.lowercased(), localizedName.lowercased()]
            )
        }

        applyBucketAliases(into: &builders)
        applyPhraseAliases(into: &builders)
        applyManualAliases(into: &builders)

        let results = builders.values
            .map { builder in
                EmojiSearchResult(
                    emoji: builder.emoji,
                    name: builder.name,
                    keywords: builder.keywords.sorted(),
                    rank: builder.rank
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.name < rhs.name
            }

        let defaults = [
            "🙂", "😄", "😃", "😁", "😅", "😆",
            "😊", "😉", "😍", "🥳", "😂", "😭",
            "🔥", "❤️", "👍", "👎", "👏", "🙏",
            "🎉", "✅", "✨", "🚀", "🤝", "👀"
        ]

        return (results, defaults)
    }

    private static func applyBucketAliases(into builders: inout [String: Builder]) {
        let aliases: [String: [String]] = [
            "PositiveEmoji": ["happy", "smile", "smiling", "joy", "good", "yay", "love", "celebrate"],
            "SadEmoji": ["sad", "cry", "crying", "down", "upset", "unhappy"],
            "AngerEmoji": ["angry", "anger", "mad", "annoyed", "rage"],
            "AnxietyEmoji": ["shock", "surprised", "surprise", "scared", "anxious", "nervous"],
            "LowEnergyEmoji": ["sleep", "sleepy", "tired", "rest", "yawn"],
            "FeelEmoji": ["sick", "ill", "hurt", "nausea", "fever"],
            "ConfusedEmoji": ["confused", "thinking", "question", "hmm"]
        ]

        guard let dictionary = NSDictionary(contentsOfFile: "/System/Library/PrivateFrameworks/TextInput.framework/Versions/A/Resources/emojiBuckets.plist") as? [String: String] else {
            return
        }

        for (emoji, bucket) in dictionary {
            guard let bucketAliases = aliases[bucket], var builder = builders[emoji] else { continue }
            builder.keywords.formUnion(bucketAliases.map(normalize))
            builders[emoji] = builder
        }
    }

    private static func applyPhraseAliases(into builders: inout [String: Builder]) {
        guard let dictionary = NSDictionary(contentsOfFile: "/System/Library/PrivateFrameworks/NLP.framework/Versions/A/Resources/en_US-phrase-to-emojis.plist") as? [String: [String]] else {
            return
        }

        for (phrase, emojis) in dictionary {
            let keywords = tokens(from: phrase)
            for emoji in emojis {
                guard var builder = builders[emoji] else { continue }
                builder.keywords.formUnion(keywords)
                builders[emoji] = builder
            }
        }
    }

    private static func applyManualAliases(into builders: inout [String: Builder]) {
        let manualAliases: [String: [String]] = [
            "😄": ["smile", "smiley", "happy"],
            "😃": ["smile", "happy"],
            "😁": ["smile", "happy", "grin"],
            "🙂": ["smile", "happy", "slight"],
            "😂": ["laugh", "lol", "lmao"],
            "🤣": ["laugh", "lol", "rofl"],
            "❤️": ["heart", "love", "red"],
            "🔥": ["fire", "lit", "hot"],
            "👍": ["thumb", "thumbs", "approve", "like", "yes"],
            "👎": ["thumb", "thumbs", "dislike", "no"],
            "🙏": ["thanks", "please", "pray"],
            "✨": ["sparkles", "shiny", "magic"],
            "🚀": ["rocket", "launch", "ship"],
            "✅": ["check", "done", "success"],
            "🎉": ["party", "celebrate", "celebration"],
            "👀": ["eyes", "look", "watch"]
        ]

        for (emoji, aliases) in manualAliases {
            guard var builder = builders[emoji] else { continue }
            builder.keywords.formUnion(aliases.map(normalize))
            builders[emoji] = builder
        }
    }

    private static func emojiScalars() -> [UnicodeScalar] {
        let ranges: [ClosedRange<UInt32>] = [
            0x00A9...0x00AE,
            0x2000...0x3300,
            0x1F000...0x1FAFF
        ]

        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(1600)

        for range in ranges {
            for value in range {
                guard let scalar = UnicodeScalar(value), scalar.properties.isEmoji else { continue }
                scalars.append(scalar)
            }
        }

        return scalars
    }

    private static func isExcludedBaseScalar(_ value: UInt32) -> Bool {
        if (0x1F1E6...0x1F1FF).contains(value) { return true }
        if (0x1F3FB...0x1F3FF).contains(value) { return true }
        if (0xE0020...0xE007F).contains(value) { return true }
        if value == 0x20E3 || value == 0x200D || value == 0xFE0F { return true }
        if value == 0x0023 || value == 0x002A || (0x0030...0x0039).contains(value) { return true }
        return false
    }

    private static func preferredDisplay(for scalar: UnicodeScalar) -> String {
        if scalar.properties.isEmojiPresentation {
            return String(scalar)
        }

        return String(scalar) + "\u{FE0F}"
    }

    private static func flagEmoji(for code: String) -> String? {
        guard code.count == 2 else { return nil }
        let base: UInt32 = 0x1F1E6
        var scalars: [UnicodeScalar] = []
        for scalar in code.unicodeScalars {
            let value = scalar.value
            guard (65...90).contains(value),
                  let regional = UnicodeScalar(base + (value - 65)) else {
                return nil
            }
            scalars.append(regional)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static let skinToneModifiers: [UnicodeScalar] = [
        "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"
    ]

    private static let keycapEntries: [(String, String, [String])] = [
        ("#️⃣", "keycap hashtag", ["hash", "number", "pound"]),
        ("*️⃣", "keycap asterisk", ["star", "asterisk"]),
        ("0️⃣", "keycap zero", ["0", "zero"]),
        ("1️⃣", "keycap one", ["1", "one"]),
        ("2️⃣", "keycap two", ["2", "two"]),
        ("3️⃣", "keycap three", ["3", "three"]),
        ("4️⃣", "keycap four", ["4", "four"]),
        ("5️⃣", "keycap five", ["5", "five"]),
        ("6️⃣", "keycap six", ["6", "six"]),
        ("7️⃣", "keycap seven", ["7", "seven"]),
        ("8️⃣", "keycap eight", ["8", "eight"]),
        ("9️⃣", "keycap nine", ["9", "nine"])
    ]

    private static func prettify(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: " sign", with: "")
            .replacingOccurrences(of: " black ", with: " ")
            .replacingOccurrences(of: " squared ", with: " ")
            .replacingOccurrences(of: " symbol", with: "")
            .replacingOccurrences(of: " selector-16", with: "")
            .replacingOccurrences(of: " regional indicator ", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(from string: String) -> [String] {
        normalize(string)
            .split(separator: " ")
            .map(String.init)
    }

    private static func isFuzzyMatch(_ needle: String, in haystack: String) -> Bool {
        guard needle.count >= 2, haystack.count >= needle.count else { return false }

        var haystackIndex = haystack.startIndex
        for char in needle {
            guard let found = haystack[haystackIndex...].firstIndex(of: char) else {
                return false
            }
            haystackIndex = haystack.index(after: found)
        }

        return true
    }
}
