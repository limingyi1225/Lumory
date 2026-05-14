//
//  NarrativeStreamSplitterTests.swift
//  ChronoteTests
//
//  wave15 — 模型 raw output → (headline, body) 切分逻辑契约。
//
//  覆盖:
//  - 标准 [HEADLINE]/[BODY] marker 切分
//  - 模型不守 marker 的 fallback(headline=nil + 全 body)
//  - 只 [HEADLINE] 没 [BODY] 退化
//  - marker 周围 whitespace trim
//  - headline 太长(模型 leak 正文进 [HEADLINE])→ 截前两句 + 后半并回 body
//  - fallbackHeadline:body 第一段第一句、中文全宽标点、无标点 30 字截断
//

import Testing
import Foundation
@testable import Lumory

struct NarrativeStreamSplitterTests {

    // MARK: - split

    @Test func split_validMarkers_returnsBoth() {
        let raw = """
        [HEADLINE]
        五月里你回到了那段熟悉的孤独
        [BODY]
        你这个月开始得很有力气。然后慢慢变得安静。

        最后一周你又开始写诗了。
        """
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        #expect(headline == "五月里你回到了那段熟悉的孤独")
        #expect(body.contains("你这个月开始得很有力气"))
        #expect(body.contains("最后一周你又开始写诗了"))
    }

    @Test func split_missingHeadlineMarker_fallbackBody() {
        // 模型只输出 raw text → headline=nil,全文当 body
        let raw = "你这个月经历了三次低谷,但每次都通过散步走了出来。"
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        #expect(headline == nil)
        #expect(body == "你这个月经历了三次低谷,但每次都通过散步走了出来。")
    }

    @Test func split_missingBodyMarker_fallbackBody() {
        // 只 [HEADLINE] 没 [BODY] — 不可信,丢弃 headline 退化整段当 body。
        // 但 [HEADLINE] marker 必须清掉(codex review):否则用户在 fallbackHeadline 里
        // 看到 "[HEADLINE]" 字面量当 placeholder 标题,非常丑。
        let raw = "[HEADLINE]\n光是这一句话\n但是没有后续的 BODY"
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        #expect(headline == nil)
        #expect(body.contains("光是这一句话"))
        #expect(!body.contains("[HEADLINE]"), "marker 必须从 body 清掉,防止用户看到 protocol 字面量")
    }

    @Test func split_reversedMarkers_stripsAllProtocolMarkers() {
        let raw = "[BODY]\n真正正文\n[HEADLINE]\n迟到标题"
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        #expect(headline == nil)
        #expect(!body.contains("[BODY]"))
        #expect(!body.contains("[HEADLINE]"))
        #expect(body.contains("真正正文"))
    }

    @Test func split_extraWhitespaceTrimmed() {
        // marker 周围 \n\n 跟前后空格都应该 trim
        let raw = """


        [HEADLINE]


        简单一句

        [BODY]


        正文。

        """
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        #expect(headline == "简单一句")
        #expect(body == "正文。")
    }

    @Test func split_headlineTooLong_mergesLeakIntoBody() {
        // headline > 80 字符,模型把正文 leak 进 [HEADLINE] — 截前两句 + 后半并回 body 前
        // (codex 反馈:不能静默丢模型输出)
        // 拼足 > 80 char 让 truncate 路径触发
        let leakedHeadline = """
        这段时间像一杯凉茶慢慢见底而沉静。你开始注意到那些被忽略的细节也在呼吸。这本是 BODY 的开场,模型放错位置了,但也包含了真正有价值的观察内容希望不被丢失,这是非常长非常长的延伸正文。
        """
        let raw = """
        [HEADLINE]
        \(leakedHeadline)
        [BODY]
        正文段落 1。

        正文段落 2。
        """
        let (headline, body) = NarrativeStreamSplitter.split(rawOutput: raw)
        let h = headline ?? ""
        // 前两句应在 headline 内
        #expect(h.contains("一杯凉茶"))
        #expect(h.contains("被忽略的细节"))
        // leak 内容(第三句开始)应并回 body 前
        #expect(body.contains("这本是 BODY 的开场"))
        #expect(body.contains("正文段落 1"))
        // headline 长度被截 — 应小于完整 leakedHeadline 长度
        #expect(!h.isEmpty)
        #expect(h.count < leakedHeadline.count)
    }

    // MARK: - fallbackHeadline

    @Test func fallbackHeadline_findsFirstSentence() {
        let body = "你这个月开始得很有力气。然后慢慢变得安静。最后一周你又开始写诗了。"
        let h = NarrativeStreamSplitter.fallbackHeadline(fromBody: body)
        #expect(h == "你这个月开始得很有力气。")
    }

    @Test func fallbackHeadline_chineseFullwidthPunctuation() {
        // body 用全宽 ?! 应被识别成句末
        let body = "这段时间值得吗?\n\n后面段落。"
        let h = NarrativeStreamSplitter.fallbackHeadline(fromBody: body)
        #expect(h == "这段时间值得吗?")
    }

    @Test func fallbackHeadline_noPunctuation_truncates30() {
        let longLine = String(repeating: "字", count: 50)  // 50 个"字",无标点
        let h = NarrativeStreamSplitter.fallbackHeadline(fromBody: longLine)
        #expect(h.hasSuffix("…"))
        #expect(h.count == 31)  // 30 字 + "…"
    }

    @Test func fallbackHeadline_shortNoPunctuation_returnsAsIs() {
        // 短文无标点 → 不截断不加 …
        let short = "短句子无标点"
        let h = NarrativeStreamSplitter.fallbackHeadline(fromBody: short)
        #expect(h == short)
    }

    @Test func fallbackHeadline_trimsLeadingWhitespace() {
        // first paragraph leading whitespace 应被 trim
        let body = "   \n\n  你今天醒得早。下午散了步。\n\n后面段落。"
        let h = NarrativeStreamSplitter.fallbackHeadline(fromBody: body)
        // 应取得"你今天醒得早。"(无前导空白),不是"   你今天醒得早。"
        #expect(h.hasPrefix("你"))
        #expect(h == "你今天醒得早。")
    }

    // MARK: - limits

    @Test func streamLimits_appendMarksDroppedSuffix() {
        var raw = String(repeating: "a", count: NarrativeStreamLimits.rawOutputCharacterLimit - 2)
        let didDrop = NarrativeStreamLimits.append("bcdef", to: &raw)
        #expect(didDrop == true)
        #expect(raw.count == NarrativeStreamLimits.rawOutputCharacterLimit)
        #expect(raw.hasSuffix("bc"))

        let secondDrop = NarrativeStreamLimits.append("z", to: &raw)
        #expect(secondDrop == true)
        #expect(raw.count == NarrativeStreamLimits.rawOutputCharacterLimit)
        #expect(!raw.hasSuffix("z"))
    }
}
