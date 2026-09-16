// ClipboardBundle.swift
// MWB 剪贴板「打包串」的编解码。
//
// 【为什么需要它】MWB 的 ClipboardText(124) **不是纯文本通道**：它的载荷是一个多格式打包串，
// 把剪贴板上每种格式拼成 `<3 字符前缀><内容>`，再用一个 GUID 分隔符串起来。
//
// 权威来源：PowerToys `src/modules/MouseWithoutBorders/App/Core/Clipboard.cs`
//   L47   private const string TEXT_TYPE_SEP = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}";
//   L1148 st.Split(new string[] { TEXT_TYPE_SEP }, StringSplitOptions.RemoveEmptyEntries)
//   L1159 tmp = txt[3..];                        // 砍掉 3 字符前缀
//   L1161 txt.StartsWith("RTF") -> DataFormats.Rtf
//   L1166 txt.StartsWith("HTM") -> DataFormats.Html
//   L1171 txt.StartsWith("TXT") -> DataFormats.UnicodeText
//   L1176 else   -> 仅当是**第一条**时，把「整条」（不砍 3 字符）当 UnicodeText
//   前缀比较用 CurrentCultureIgnoreCase → **不区分大小写**
//
// 编码：`Common.GetBytesU` = ASCIIEncoding.Unicode = **UTF-16LE**（Deflate 在它之后）。
//
// 线格式（UTF-16LE 之前的那一串，也就是解压后拿到的东西）：
//   "TXT"+纯文本 + SEP + "HTM"+CF_HTML全文 + SEP [+ "RTF"+RTF源 + SEP]
//
// 【踩过的坑】我们原来把解压出来的整串直接 `setString` 写进剪贴板，于是在 Windows 的企业微信里
// 复制一段话，粘到 Mac 上就变成：
//   TXT昨天整理了一下 帮忙看看有什么问题吗{4CFF57F7-…}HTMVersion:0.9\r\nStartHTML:0000000117…
// 即「TXT 条目 + 分隔符 GUID + HTM 条目（CF_HTML 全文）」。用户 2026-09-16 报的乱码就是这个。

import Foundation

public enum MWBClipboardBundle {

    /// 对齐 PowerToys `Clipboard.TEXT_TYPE_SEP`。**这不是随机垃圾，就是格式分隔符。**
    public static let separator = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}"

    /// 解包结果。三个字段都可能为 nil（对端没带那种格式）。
    public struct Parts: Equatable {
        /// `TXT` 条目：纯文本。
        public var text: String?
        /// `HTM` 条目：**已经剥掉 CF_HTML 头**的 HTML 文档。
        public var html: String?
        /// `RTF` 条目：RTF 源（通常是 ASCII）。
        public var rtf: String?
        /// 是否至少认出一个带前缀的条目。false = 对端发的是裸文本（非标准实现/旧版）。
        public var sawTaggedEntry: Bool

        public init(text: String? = nil, html: String? = nil, rtf: String? = nil,
                    sawTaggedEntry: Bool = false) {
            self.text = text
            self.html = html
            self.rtf = rtf
            self.sawTaggedEntry = sawTaggedEntry
        }

        /// 有内容可写吗。
        public var isEmpty: Bool {
            (text?.isEmpty ?? true) && (html?.isEmpty ?? true) && (rtf?.isEmpty ?? true)
        }
    }

    // MARK: - 打包（Mac → Windows）

    /// 把本机剪贴板内容打成 MWB 线格式串。一条有效条目都没有时返回 nil。
    ///
    /// 每条后面都跟一个分隔符（与实测到的 Windows 端行为一致：
    /// 观察到的载荷末尾就是 `…</html>{SEP}`）。
    public static func pack(text: String?, html: String? = nil, rtf: String? = nil) -> String? {
        var out = ""
        var count = 0
        if let t = text, !t.isEmpty { out += "TXT" + t + separator; count += 1 }
        if let h = html, !h.isEmpty { out += "HTM" + h + separator; count += 1 }
        if let r = rtf, !r.isEmpty { out += "RTF" + r + separator; count += 1 }
        return count > 0 ? out : nil
    }

    // MARK: - 解包（Windows → Mac）

    /// 解析对端发来的打包串。
    ///
    /// 两种情形：
    /// - 整串里**没有**分隔符 → 判定为「裸文本」（非标准实现 / 旧版对端），整串按纯文本返回，
    ///   **绝不**做「砍掉前 3 字符」——否则一段以 `HTM`/`TXT`/`RTF` 开头的正常文字会被吃掉 3 个字。
    /// - 有分隔符 → 按 SEP 切分，逐条看前 3 字符（不区分大小写）分发；
    ///   认不出前缀时对齐 PowerToys 的 else 分支：只有第一条会按「整条」兜底成纯文本。
    public static func parse(_ raw: String) -> Parts {
        guard !raw.isEmpty else { return Parts() }

        if !raw.contains(separator) {
            return Parts(text: raw, sawTaggedEntry: false)
        }

        var parts = Parts()
        var index = 0
        // 对齐 StringSplitOptions.RemoveEmptyEntries
        for entry in raw.components(separatedBy: separator) where !entry.isEmpty {
            // 对齐 PowerToys 的 txt.Trim(NullSeparator)：只去 NUL，不动空白，
            // 免得把用户文本里本来就有首尾空格给吃了。
            let trimmed = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if trimmed.isEmpty { continue }

            let tag = String(trimmed.prefix(3)).uppercased()
            let body = String(trimmed.dropFirst(3))

            switch tag {
            case "RTF":
                parts.rtf = body
                parts.sawTaggedEntry = true
            case "HTM":
                parts.html = stripCFHTMLHeader(body)
                parts.sawTaggedEntry = true
            case "TXT":
                parts.text = body
                parts.sawTaggedEntry = true
            default:
                if index == 0, parts.text == nil { parts.text = trimmed }
            }
            index += 1
        }
        return parts
    }

    // MARK: - CF_HTML

    /// 剥掉 Windows CF_HTML 的头部（`Version:0.9` / `StartHTML:…` 那几行），只留真正的 HTML。
    ///
    /// macOS 的 `public.html` 要的是 HTML 文档本身，**不认 CF_HTML 这层壳**；
    /// 原样塞进去会让某些 App 把 `Version:0.9` 当正文显示出来。
    public static func stripCFHTMLHeader(_ s: String) -> String {
        if let r = s.range(of: "<html", options: .caseInsensitive) {
            return String(s[r.lowerBound...])
        }
        // 退化路径：没有 <html>，那就逐行跳过形如 "Key:value" 的头部行
        let lines = s.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if l.isEmpty { i += 1; continue }
            if l.range(of: "^[A-Za-z0-9]+:", options: .regularExpression) != nil { i += 1; continue }
            break
        }
        return i < lines.count ? lines[i...].joined(separator: "\n") : s
    }

    /// 从 HTML 里粗略取纯文本 —— **只在没有 TXT 条目时兜底**用。
    public static func plainText(fromHTML html: String) -> String {
        var s = html
        // 去注释 / script / style（没闭合就砍到底，避免死循环）
        for (open, close) in [("<!--", "-->"), ("<script", "</script>"), ("<style", "</style>")] {
            while true {
                guard let a = s.range(of: open, options: .caseInsensitive) else { break }
                guard let b = s.range(of: close, options: .caseInsensitive,
                                     range: a.upperBound..<s.endIndex) else {
                    s.removeSubrange(a.lowerBound..<s.endIndex)
                    break
                }
                s.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        // 换行类标签先换成 \n，再抹掉其余标签
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|tr|li|h[1-6])>", with: "\n",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // 常见实体
        for (entity, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                             ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: ch, options: .caseInsensitive)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
