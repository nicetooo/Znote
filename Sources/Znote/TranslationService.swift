import Foundation
import NaturalLanguage

/// Translates text with auto-flip: English ↔ Chinese.
/// Uses Google Translate free endpoint (no API key needed).
class TranslationService {

    /// Translation result with language info
    struct Result {
        let text: String
        let sourceLang: String
        let targetLang: String
    }

    /// What to ask the endpoint for.
    struct Plan: Equatable {
        /// Language the text is taken to be in ("zh", "en", "ja", …) — shown in history.
        let source: String
        /// "en" or "zh-CN".
        let target: String
        /// The request's `sl` value: a language code, or "auto".
        let sourceParam: String
    }

    /// Translate text. Calls completion on a background thread.
    func translate(_ text: String, completion: @escaping (String?) -> Void) {
        let result = translateWithInfo(text)
        completion(result?.text)
    }

    /// Translate text, returning full result with language info.
    func translateWithInfo(_ text: String) -> Result? {
        let plan = TranslationService.plan(for: text)
        log("Translation: \(plan.source) → \(plan.target) (sl=\(plan.sourceParam))")

        if let translated = googleTranslate(text, from: plan.sourceParam, to: plan.target) {
            return Result(text: translated, sourceLang: plan.source, targetLang: plan.target)
        }
        return nil
    }

    // MARK: - Direction

    /// Decide which way to translate. Chinese goes to English; everything
    /// else goes to Chinese.
    ///
    /// Text that mixes Chinese characters with Latin words needs care on both
    /// ends. NLLanguageRecognizer mostly reads the Latin letters and calls
    /// "这个 API 的 response 格式不对" Indonesian, so the direction for such
    /// text is decided from its makeup instead. And Google's own auto-detect
    /// calls any text containing Chinese characters Chinese — asked to turn
    /// "Please check the 配置文件" into Chinese it returns it untouched — so
    /// when the target is Chinese the source language is named explicitly.
    static func plan(for text: String) -> Plan {
        let makeup = Makeup(text)

        // No Chinese characters at all, or Japanese / Korean (kana or hangul
        // next to the kanji): the recognizer handles single-script text well.
        guard makeup.han > 0, !makeup.hasKanaOrHangul else {
            let source = detectLanguage(text)
            return Plan(source: source, target: source == "zh" ? "en" : "zh-CN", sourceParam: "auto")
        }
        if makeup.isChineseSentence {
            return Plan(source: "zh", target: "en", sourceParam: "auto")
        }
        // A Latin-script sentence with Chinese words in it. Assumed English:
        // the Latin part is often too short to identify reliably.
        return Plan(source: "en", target: "zh-CN", sourceParam: "en")
    }

    /// Counts that tell a Chinese sentence using English terms ("merge 一下
    /// PR") from an English sentence using Chinese words ("Send it to 张三").
    private struct Makeup {
        private(set) var han = 0
        private(set) var hasKanaOrHangul = false
        private(set) var latinWords = 0
        /// Stretches of Chinese grammatical characters (的 了 是 一下 这个 …).
        private(set) var chineseFunctionRuns = 0
        /// English grammatical words (the, to, is, please …).
        private(set) var englishFunctionWords = 0
        private var firstIsHan: Bool?
        private var lastIsHan: Bool?

        init(_ text: String) {
            var word = ""
            var inFunctionRun = false

            func sawLetter(isHan: Bool, _ me: inout Makeup) {
                if me.firstIsHan == nil { me.firstIsHan = isHan }
                me.lastIsHan = isHan
            }
            func endWord(_ me: inout Makeup) {
                guard !word.isEmpty else { return }
                me.latinWords += 1
                sawLetter(isHan: false, &me)
                if Makeup.isEnglishFunctionWord(word) { me.englishFunctionWords += 1 }
                word = ""
            }

            for scalar in text.unicodeScalars {
                if Makeup.isHan(scalar) {
                    endWord(&self)
                    han += 1
                    sawLetter(isHan: true, &self)
                    if Makeup.chineseFunctionCharacters.contains(scalar) {
                        if !inFunctionRun { chineseFunctionRuns += 1 }
                        inFunctionRun = true
                    } else {
                        inFunctionRun = false
                    }
                } else if Makeup.isLatinLetter(scalar) {
                    word.unicodeScalars.append(scalar)
                    inFunctionRun = false
                } else {
                    endWord(&self)
                    inFunctionRun = false
                    if Makeup.isKanaOrHangul(scalar) { hasKanaOrHangul = true }
                }
            }
            endWord(&self)
        }

        /// Whether Chinese supplies the sentence and the Latin words are
        /// borrowed terms, rather than the other way round.
        var isChineseSentence: Bool {
            if latinWords == 0 { return true }
            // 1. Whichever language supplies the grammar words owns the sentence.
            if chineseFunctionRuns != englishFunctionWords {
                return chineseFunctionRuns > englishFunctionWords
            }
            // 2. A sentence usually starts and ends in its own language.
            if let first = firstIsHan, let last = lastIsHan, first == last { return first }
            // 3. Otherwise by bulk; a tie goes to Chinese ("GitHub Actions 构建失败").
            return han >= latinWords
        }

        // MARK: Character classes

        private static func isHan(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2EBEF: return true
            default: return false
            }
        }

        private static func isKanaOrHangul(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true
            default: return false
            }
        }

        private static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
            s.properties.isAlphabetic && (s.value < 0x0250 || (0x1E00...0x1EFF).contains(s.value))
        }

        private static let chineseFunctionCharacters: Set<Unicode.Scalar> = Set(
            ("的了是在我你他她它们們这這那和把被给給从從到不没沒也都就还還很吗嗎呢吧啊着著得之而但"
                + "请請让讓用个個一下么麼什怎谁誰哪些再才只已将將其此该該与與或后後前").unicodeScalars
        )

        private static let englishFunctionWordList: Set<String> = [
            "the", "an", "of", "to", "in", "on", "at", "for", "with", "by", "from", "and", "or", "but", "if",
            "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had",
            "will", "would", "can", "could", "should", "may", "might", "must",
            "you", "he", "she", "it", "we", "they", "me", "my", "your", "his", "her", "its", "our", "their",
            "us", "them", "this", "that", "these", "those", "there", "here", "not", "no", "please", "let",
            "as", "so", "than", "then", "when", "where", "which", "who", "what", "why", "how",
            "before", "after", "about", "into", "just", "also", "very", "too",
        ]

        private static func isEnglishFunctionWord(_ word: String) -> Bool {
            // "I" and "a" only in their sentence case: "方案 A" is a label.
            if word.count == 1 { return word == "I" || word == "a" }
            // All-caps words are acronyms and labels: "IT 部门", "OR 条件".
            if word == word.uppercased() { return false }
            return englishFunctionWordList.contains(word.lowercased())
        }
    }

    // MARK: - Language Detection

    private static func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else {
            return "en" // Default to English
        }

        switch language {
        case .simplifiedChinese, .traditionalChinese:
            return "zh"
        default:
            return language.rawValue
        }
    }

    // MARK: - Google Translate (free endpoint, no API key)

    /// Everything outside this set is percent-encoded. Deliberately strict:
    /// `.urlQueryAllowed` lets "&" and "+" through, which cut the selected
    /// text off at the first "&" and turned every "+" into a space.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func googleTranslate(_ text: String, from sourceParam: String, to targetLang: String) -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: TranslationService.queryValueAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(sourceParam)&tl=\(targetLang)&dt=t&q=\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else {
                log("Translation request failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Response format: [[["translated text","original text",...],...],...]]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let sentences = json.first as? [Any] {
                var translated = ""
                for sentence in sentences {
                    if let parts = sentence as? [Any],
                       let text = parts.first as? String {
                        translated += text
                    }
                }
                if !translated.isEmpty {
                    result = translated
                }
            }
        }

        task.resume()
        semaphore.wait()
        return result
    }
}
