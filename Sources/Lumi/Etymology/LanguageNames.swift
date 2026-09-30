import Foundation

/// Wiktionary's language codes, named the way a Chinese reader would name them.
///
/// Only the languages English actually descends through or borrows from often
/// enough to appear in a chain. Anything else falls back to the name Wiktionary
/// itself printed, which is English but at least correct.
enum LanguageNames {
    static func name(_ code: String, fallback: String? = nil) -> String {
        if let known = table[code] { return known }
        // Wiktionary's etymology-only codes are dotted variants of a real one
        // (`la-lat`, `la-med`); the base name is closer than no name.
        if let base = code.split(separator: "-").first, let known = table[String(base)],
           !code.hasSuffix("-pro") {
            return known
        }
        return fallback ?? code
    }

    private static let table: [String: String] = [
        "en": "英语", "enm": "中古英语", "ang": "古英语", "sco": "苏格兰语",
        "fr": "法语", "frm": "中古法语", "fro": "古法语", "xno": "盎格鲁-诺曼语",
        "nrf": "诺曼语", "pro": "古奥克语", "oc": "奥克语", "frk": "法兰克语",
        "la": "拉丁语", "la-lat": "晚期拉丁语", "la-med": "中世纪拉丁语", "la-vul": "通俗拉丁语",
        "la-new": "新拉丁语", "la-cla": "古典拉丁语", "LL.": "晚期拉丁语", "ML.": "中世纪拉丁语",
        "VL.": "通俗拉丁语", "NL.": "新拉丁语",
        "grc": "古希腊语", "grc-koi": "通用希腊语", "el": "希腊语", "gkm": "中古希腊语",
        "it": "意大利语", "es": "西班牙语", "pt": "葡萄牙语", "ca": "加泰罗尼亚语", "ro": "罗马尼亚语",
        "de": "德语", "goh": "古高地德语", "gmh": "中古高地德语", "nl": "荷兰语", "dum": "中古荷兰语",
        "odt": "古荷兰语", "osx": "古撒克逊语", "gml": "中古低地德语", "nds": "低地德语", "fy": "弗里斯兰语",
        "ofs": "古弗里斯兰语", "non": "古诺尔斯语", "is": "冰岛语", "da": "丹麦语", "sv": "瑞典语",
        "no": "挪威语", "nb": "书面挪威语", "nn": "新挪威语", "got": "哥特语",
        "ga": "爱尔兰语", "sga": "古爱尔兰语", "mga": "中古爱尔兰语", "gd": "苏格兰盖尔语",
        "cy": "威尔士语", "br": "布列塔尼语", "kw": "康沃尔语",
        "ru": "俄语", "pl": "波兰语", "cs": "捷克语", "cu": "古教会斯拉夫语",
        "ar": "阿拉伯语", "fa": "波斯语", "pal": "中古波斯语", "peo": "古波斯语",
        "he": "希伯来语", "hbo": "古希伯来语", "arc": "阿拉米语", "akk": "阿卡德语",
        "sa": "梵语", "hi": "印地语", "ur": "乌尔都语", "pi": "巴利语", "ta": "泰米尔语",
        "tr": "土耳其语", "ota": "奥斯曼土耳其语", "hu": "匈牙利语", "fi": "芬兰语",
        "ja": "日语", "zh": "汉语", "cmn": "官话", "yue": "粤语", "nan": "闽南语", "ko": "朝鲜语",
        "ms": "马来语", "tl": "他加禄语", "nah": "纳瓦特尔语", "qu": "克丘亚语", "egy": "古埃及语",
        "ine-pro": "原始印欧语", "gem-pro": "原始日耳曼语", "gmw-pro": "原始西日耳曼语",
        "gmq-pro": "原始北日耳曼语", "itc-pro": "原始意大利语", "cel-pro": "原始凯尔特语",
        "grk-pro": "原始希腊语", "sla-pro": "原始斯拉夫语", "ine-bsl-pro": "原始波罗的-斯拉夫语",
        "iir-pro": "原始印度-伊朗语", "sem-pro": "原始闪米特语", "urj-pro": "原始乌拉尔语",
    ]

    /// Codes whose forms are reconstructed as a family rather than recorded.
    /// A form starting with `*` says the same thing; this catches the entries
    /// that forget the asterisk.
    static func isProto(_ code: String) -> Bool { code.hasSuffix("-pro") }
}
