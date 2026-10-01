import Foundation

/// Wiktionary's language codes, named the way the reader names them: a Chinese
/// reader sees 拉丁语, an English reader sees Latin.
///
/// Only the languages English actually descends through or borrows from often
/// enough to appear in a chain. Anything else falls back to the name Wiktionary
/// itself printed, which is English but at least correct.
///
/// `name` is `@MainActor` because it reads `Localization.shared.language`; the
/// callers that use it (views, the teaser, the narration material) all run on
/// the main actor, so nothing non-isolated is left needing a name.
enum LanguageNames {
    @MainActor
    static func name(_ code: String, fallback: String? = nil) -> String {
        let table = Localization.shared.language == .en ? english : chinese
        if let known = table[code] { return known }
        // Wiktionary's etymology-only codes are dotted variants of a real one
        // (`la-lat`, `la-med`); the base name is closer than no name.
        if let base = code.split(separator: "-").first, let known = table[String(base)],
           !code.hasSuffix("-pro") {
            return known
        }
        return fallback ?? code
    }

    private static let chinese: [String: String] = [
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

    private static let english: [String: String] = [
        "en": "English", "enm": "Middle English", "ang": "Old English", "sco": "Scots",
        "fr": "French", "frm": "Middle French", "fro": "Old French", "xno": "Anglo-Norman",
        "nrf": "Norman", "pro": "Old Occitan", "oc": "Occitan", "frk": "Frankish",
        "la": "Latin", "la-lat": "Late Latin", "la-med": "Medieval Latin", "la-vul": "Vulgar Latin",
        "la-new": "New Latin", "la-cla": "Classical Latin", "LL.": "Late Latin", "ML.": "Medieval Latin",
        "VL.": "Vulgar Latin", "NL.": "New Latin",
        "grc": "Ancient Greek", "grc-koi": "Koine Greek", "el": "Greek", "gkm": "Medieval Greek",
        "it": "Italian", "es": "Spanish", "pt": "Portuguese", "ca": "Catalan", "ro": "Romanian",
        "de": "German", "goh": "Old High German", "gmh": "Middle High German", "nl": "Dutch", "dum": "Middle Dutch",
        "odt": "Old Dutch", "osx": "Old Saxon", "gml": "Middle Low German", "nds": "Low German", "fy": "Frisian",
        "ofs": "Old Frisian", "non": "Old Norse", "is": "Icelandic", "da": "Danish", "sv": "Swedish",
        "no": "Norwegian", "nb": "Norwegian Bokmål", "nn": "Norwegian Nynorsk", "got": "Gothic",
        "ga": "Irish", "sga": "Old Irish", "mga": "Middle Irish", "gd": "Scottish Gaelic",
        "cy": "Welsh", "br": "Breton", "kw": "Cornish",
        "ru": "Russian", "pl": "Polish", "cs": "Czech", "cu": "Old Church Slavonic",
        "ar": "Arabic", "fa": "Persian", "pal": "Middle Persian", "peo": "Old Persian",
        "he": "Hebrew", "hbo": "Biblical Hebrew", "arc": "Aramaic", "akk": "Akkadian",
        "sa": "Sanskrit", "hi": "Hindi", "ur": "Urdu", "pi": "Pali", "ta": "Tamil",
        "tr": "Turkish", "ota": "Ottoman Turkish", "hu": "Hungarian", "fi": "Finnish",
        "ja": "Japanese", "zh": "Chinese", "cmn": "Mandarin", "yue": "Cantonese", "nan": "Min Nan", "ko": "Korean",
        "ms": "Malay", "tl": "Tagalog", "nah": "Nahuatl", "qu": "Quechua", "egy": "Egyptian",
        "ine-pro": "Proto-Indo-European", "gem-pro": "Proto-Germanic", "gmw-pro": "Proto-West Germanic",
        "gmq-pro": "Proto-North Germanic", "itc-pro": "Proto-Italic", "cel-pro": "Proto-Celtic",
        "grk-pro": "Proto-Greek", "sla-pro": "Proto-Slavic", "ine-bsl-pro": "Proto-Balto-Slavic",
        "iir-pro": "Proto-Indo-Iranian", "sem-pro": "Proto-Semitic", "urj-pro": "Proto-Uralic",
    ]

    /// Codes whose forms are reconstructed as a family rather than recorded.
    /// A form starting with `*` says the same thing; this catches the entries
    /// that forget the asterisk.
    static func isProto(_ code: String) -> Bool { code.hasSuffix("-pro") }
}
