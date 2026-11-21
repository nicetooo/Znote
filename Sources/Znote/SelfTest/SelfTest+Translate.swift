import Foundation

/// Scenario `translate` — selection translation, end to end against Google's
/// endpoint. Needs network, so `run.sh` only runs it when asked.
///
/// Each case states which way a reader would expect the text to go; a case
/// passes when the app picked that direction AND the text actually changed.
/// The same table drives the offline direction checks in the `logic` scenario.
extension SelfTest {
    struct TranslateCase {
        let text: String
        /// "en" = should come out in English, "zh" = in Chinese.
        let want: String
        /// Something the translation must still contain (end-to-end only).
        var contains: String? = nil
    }

    static let translateCases: [TranslateCase] = [
        // Single-language controls
        .init(text: "今天下午三点开会，请大家准时参加。", want: "en"),
        .init(text: "The meeting starts at three this afternoon.", want: "zh"),
        .init(text: "這個功能還沒有測試", want: "en"),
        // Short selections
        .init(text: "测试", want: "en"),
        .init(text: "你好", want: "en"),
        .init(text: "取消", want: "en"),
        .init(text: "Hello", want: "zh"),
        .init(text: "OK", want: "zh"),
        .init(text: "OK，没问题", want: "en"),

        // ── Chinese sentence carrying English terms → English ──
        .init(text: "这个 API 的 response 格式不对", want: "en"),
        .init(text: "我们用 React 和 TypeScript 写 frontend，然后 deploy 到 Vercel", want: "en"),
        .init(text: "请 review 一下这个 pull request，看看 CI 为什么 failed", want: "en"),
        .init(text: "这个function的return value是undefined", want: "en"),
        .init(text: "GitHub Actions 构建失败", want: "en"),
        .init(text: "git push origin main 之后报错", want: "en"),
        .init(text: "merge 一下 PR", want: "en"),
        .init(text: "bug 修复了", want: "en"),
        .init(text: "deadline 是明天", want: "en"),
        // (second batch, written before the fix and not used to design it)
        .init(text: "帮我 check 一下 the logs", want: "en"),
        .init(text: "明天的 meeting 改到下午三点", want: "en"),
        .init(text: "这是一个 test", want: "en"),
        .init(text: "TODO: 修复登录问题", want: "en"),
        .init(text: "Error: 文件不存在", want: "en"),
        .init(text: "Python 是最好的语言", want: "en"),
        .init(text: "我 love 你", want: "en"),
        .init(text: "方案 A 比方案 B 好", want: "en"),                 // "A" is a label, not an article
        .init(text: "IT 部门说 VPN 今天不能用", want: "en"),            // "IT" is not the pronoun
        .init(text: "iPhone 15 Pro Max 多少钱", want: "en"),
        .init(text: "他说 the show must go on 然后就走了", want: "en"),
        // (third batch: written after the fix and run blind, to measure it honestly)
        .init(text: "这个 PR 我已经 approve 了", want: "en"),
        .init(text: "下周一 release，记得更新 changelog", want: "en"),
        .init(text: "server 挂了，谁在 on call", want: "en"),
        .init(text: "把 log level 调成 debug 再跑一次", want: "en"),
        .init(text: "老板说 Q3 的 OKR 要重新对齐", want: "en"),
        .init(text: "这个需求 PM 还没给 PRD", want: "en"),
        .init(text: "Docker 容器起不来", want: "en"),
        .init(text: "npm install 报了一堆 warning", want: "en"),
        .init(text: "用户反馈 app 闪退", want: "en"),
        .init(text: "周五 standup 取消", want: "en"),
        .init(text: "看一下 Slack 上的消息", want: "en"),
        .init(text: "这段 code 需要 refactor", want: "en"),

        // ── English sentence carrying Chinese words → Chinese ──
        .init(text: "Please check the 配置文件 before you deploy", want: "zh"),
        .init(text: "The 用户 clicked 取消 and the 弹窗 closed", want: "zh"),
        .init(text: "Send it to 张三 tomorrow", want: "zh"),
        // (second batch)
        .init(text: "I think 这个方案 is better", want: "zh"),
        .init(text: "The deadline for 项目 is next Friday", want: "zh"),
        .init(text: "Zhang Wei (张伟) will join us tomorrow", want: "zh"),
        .init(text: "The quick brown fox 跳过了 the lazy dog", want: "zh"),
        .init(text: "张三 said hello to 李四", want: "zh"),
        .init(text: "Let's 开会 at 3pm", want: "zh"),
        // (third batch)
        .init(text: "Can you send me the 报销单 by Friday?", want: "zh"),
        .init(text: "We need to update the 营业执照 before the audit", want: "zh"),
        .init(text: "My 微信 is not working", want: "zh"),
        .init(text: "She ordered 宫保鸡丁 and a beer", want: "zh"),
        .init(text: "The 春节 holiday starts next week", want: "zh"),
        .init(text: "He lives in 朝阳区 near the park", want: "zh"),
        .init(text: "What does 加油 mean?", want: "zh"),
        .init(text: "I'll take the 高铁 to Shanghai", want: "zh"),

        // ── Other languages keep going to Chinese ──
        .init(text: "これはテストです", want: "zh"),
        .init(text: "Bonjour tout le monde", want: "zh"),

        // ── Characters that are special inside a URL must survive the request ──
        .init(text: "Tom & Jerry are good friends", want: "zh", contains: "杰瑞"),
        .init(text: "C++ and C# are different languages", want: "zh", contains: "C++"),
        .init(text: "研发 & 测试都通过了", want: "en", contains: "test"),
    ]

    static func runTranslate(_ r: inout Report) {
        let service = TranslationService()

        for (index, c) in translateCases.enumerated() {
            let t = Date()
            let result = service.translateWithInfo(c.text)
            let elapsed = ms(since: t)

            guard let result else {
                if index == 0 {
                    // The very first request failing means there is no network
                    // to test against — an environment problem, not a verdict.
                    r.errors.append("no response from the translation endpoint (offline or blocked?)")
                    return
                }
                r.step(c.text, ok: false, ms: elapsed, ["failed": "request failed"])
                continue
            }

            let direction = result.targetLang == "en" ? "en" : "zh"
            var failed: [String] = []
            if direction != c.want { failed.append("went →\(direction), expected →\(c.want)") }
            if result.text == c.text { failed.append("returned unchanged") }
            if let part = c.contains, !result.text.lowercased().contains(part.lowercased()) {
                failed.append("lost \"\(part)\"")
            }

            var detail = ["detected": result.sourceLang, "target": result.targetLang, "text": result.text]
            if !failed.isEmpty { detail["failed"] = failed.joined(separator: "; ") }
            r.step(c.text, ok: failed.isEmpty, ms: elapsed, detail)

            Thread.sleep(forTimeInterval: 0.3)   // be gentle with the free endpoint
        }
    }
}
