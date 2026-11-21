import Foundation

/// Removes Whisper's end-of-audio hallucinations ("Thank you.", "Thanks for
/// watching." …) from a transcript.
///
/// Whisper invents these on trailing silence; they come from YouTube outro
/// captions in its training data. The same words are also ordinary English, so
/// a phrase is only removed when it stands apart from what precedes it:
///   - it is the whole transcript, or
///   - it follows sentence-ending punctuation ("今天开会。Thank you."), or
///   - it follows text in a non-Latin script ("今天开会 Thank you").
/// A phrase that merely finishes a Latin-script sentence ("send it to you.")
/// belongs to that sentence and is kept.
///
/// Known limit: a genuine stand-alone closing sentence ("That's all. Thank
/// you.") is indistinguishable from the hallucination in text and is removed.
enum HallucinationFilter {
    /// Lowercased phrases Whisper is known to append on silence.
    static let phrases: Set<String> = [
        // "Thank you" family
        "thank", "thank.", "thank!",
        "thanks", "thanks.", "thanks!",
        "thank you", "thank you.", "thank you!",
        "thank you so much", "thank you so much.",
        "thank you for watching", "thank you for watching.",
        "thanks for watching", "thanks for watching.", "thanks for watching!",
        "thanks a lot", "thanks a lot.",
        // Subscribe / CTA
        "like and subscribe", "like and subscribe.",
        "subscribe", "subscribe.", "please subscribe",
        // Sign-offs
        "see you next time", "see you next time.",
        "see you in the next video", "see you in the next video.",
        "bye", "bye.", "bye bye", "bye bye.",
        "goodbye", "goodbye.",
        "the end", "the end.",
        // Single-word fragments
        "you", "you.",
        "music",
        "♪",
        "...",
        // Known auto-subtitle artifacts
        "subtitles by the amara.org community",
        "transcribed by https://otter.ai",
    ]

    /// Longest first so "thank you." wins over "you."; ties broken
    /// alphabetically to keep matching (and the log) deterministic.
    private static let phrasesLongestFirst: [String] = phrases.sorted {
        $0.count != $1.count ? $0.count > $1.count : $0 < $1
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    private static let clauseSeparators: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
    private static let danglingSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",，、;；:："))

    /// Returns `text` without trailing hallucinated phrases, or "" if nothing
    /// but hallucination is left.
    static func removeTrailing(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while !result.isEmpty {
            if phrases.contains(result.lowercased()) {
                log("Whisper: filtered pure hallucination: \"\(result)\"")
                return ""
            }
            guard let cut = trailingHallucinationStart(in: result) else { break }

            let removed = result[cut...]
            // Drop the separator left dangling before the phrase, but keep the
            // previous sentence's own terminator.
            let kept = String(result[..<cut]).trimmingCharacters(in: danglingSeparators)
            log("Whisper: stripped trailing hallucination \"\(removed)\" → \"\(kept.suffix(30))\"")
            result = kept
        }
        return result
    }

    /// Start index of a trailing phrase that should be removed, if any.
    private static func trailingHallucinationStart(in text: String) -> String.Index? {
        for phrase in phrasesLongestFirst {
            guard let range = text.range(of: phrase, options: [.caseInsensitive, .anchored, .backwards]) else {
                continue
            }
            let isWords = phrase.first?.isLetter == true
            if standsApart(precededBy: text[..<range.lowerBound], phraseIsWords: isWords) {
                return range.lowerBound
            }
        }
        return nil
    }

    /// Whether a trailing phrase is separate from the text before it, rather
    /// than the end of the sentence the user was speaking.
    private static func standsApart(precededBy prefix: Substring, phraseIsWords: Bool) -> Bool {
        for ch in prefix.reversed() {
            if ch.isWhitespace || clauseSeparators.contains(ch) { continue }
            if sentenceTerminators.contains(ch) { return true }
            if ch.isLetter || ch.isNumber {
                // English words right after non-Latin text: the language
                // switched, which real speech rarely does at the very end.
                // Symbol phrases ("...", "♪") carry no language, so skip them.
                return phraseIsWords && !isLatin(ch)
            }
            return false  // quote, bracket, symbol — can't tell, keep the text
        }
        return true  // nothing but separators before the phrase
    }

    private static func isLatin(_ ch: Character) -> Bool {
        guard let value = ch.unicodeScalars.first?.value else { return false }
        // Basic Latin … Latin Extended-B, plus Latin Extended Additional
        // (Vietnamese). ASCII digits fall in the first range.
        return value < 0x0250 || (0x1E00...0x1EFF).contains(value)
    }
}
