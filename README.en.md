# Lumi

**English** · [简体中文](README.md)

A native macOS translation tool: select text to look it up or translate it, read long articles side by side
paragraph by paragraph, proofread someone else's translation, and read Safari pages bilingually.
Inspired by [Easydict](https://github.com/tisfeng/Easydict); the code is written from scratch.

![The lookup window: the system dictionary entry for serendipity](docs/screenshots/panel.png)

> **Status**: a personal project the author uses every day, but still early. Requires **macOS 26** or
> later; there is no prebuilt package yet, so you need to build it yourself following
> [the steps below](#install). Maintained in spare time — issues may not get a quick reply.

For implementation details, design choices and debugging, see the
[technical notes (TECHSHEET.md, in Chinese)](TECHSHEET.md).

## What it does

### Translate a selection

Select text in any app and press **⌥D**; the translation appears in a small window next to it.

- **Several engines at once**: the system dictionary, the system translator, Google, DeepL, and large
  language models (OpenAI, Claude, Gemini, DeepSeek, Ollama, or any OpenAI-compatible API). You switch
  between results inside one window, so it never grows into a long stack.
- **Words read like a dictionary**: system dictionary entries are laid out as headword, pronunciation,
  numbered senses and examples instead of one dense paragraph.
- **Works offline**: without a network it falls back to the system translator (download the language
  packs in System Settings beforehand).
- **⌥A** opens an input box; **⌥S** captures a region of the screen, recognises the text in it, and
  translates that.
- Read aloud, copy, or pin the window so it stays open when you click elsewhere.

### Workbench: long texts side by side

Press **⌥W** to open the workbench, paste or drop in an article (.txt or .md), and read it paragraph by
paragraph next to the translation.

![Workbench reading view: a Markdown article translated paragraph by paragraph](docs/screenshots/workbench-translate.png)

- **Two engines**: **On-device** uses the system translator — free and offline. **Online** uses a large
  language model that takes context and your notes into account (e.g. "this is a machine-learning
  paper", "translate attention as 注意力"), so terminology stays consistent across the whole text.
- **Possible omissions are flagged**: paragraphs that lost a number or are suspiciously short are marked;
  click one to jump to it.
- **Markdown support**: open a .md file or paste Markdown text. Headings, lists, tables, quotes and code
  blocks render as they are, code and formulas are not translated, and an outline sits on the left.
  The exported translation is still well-formed Markdown.
- Articles you've read stay under **Recent documents**; next time you pick up where you left off, and
  paragraphs already translated are not paid for twice.

### Workbench: proofread a translation

Press **⇧⌘N**, paste the source on the left and the translation on the right, and start proofreading.

![Workbench proofreading: four findings, including an omission, a wrong number and inconsistent terminology](docs/screenshots/workbench-proofread.png)

- **Paragraphs are aligned automatically**, even when the translator merged, split or dropped some.
  If the alignment is wrong, fix it by hand from the paragraph menu.
- **Two layers of checks**: machine checks for numbers, glossary terms, links and paragraphs that are
  clearly too short — offline and free; then a language model reviews each paragraph for omissions,
  additions, mistranslations, terminology, numbers and grammar. Finally the terminology of the whole text
  is compared to catch inconsistent renderings.
- **One finding at a time**: the problem is highlighted in the translation, with a suggested fix and the
  reason beside it. Accept or dismiss it in one click, undo, or edit the text yourself.
- Keep a glossary (e.g. `attention = 注意力`), copy all findings as a checklist, or export the corrected
  translation.
- Articles from the reading view can be proofread too: click **Proofread** after translating.

### Workbench: etymology

Press **⌘E** and enter an English word to see where it came from and how its meanings changed.

![The etymology page: nice, from Latin nescius ("ignorant") to today's "pleasant"](docs/screenshots/workbench-etymology.png)

- The word's history is drawn as a chain, step by step: from Proto-Indo-European through Latin, Old
  French and Middle English to today.
- Each sense is drawn on a timeline showing the centuries it was in use; obsolete senses are marked.
- **All facts come from Wiktionary.** The language model only turns them into a readable paragraph; every
  sentence cites its source, and nothing missing from the source is added.

### Safari page translation

Lumi ships with a Safari extension: press **⌥T** to put a translation under every paragraph of a page.

![A Wikipedia page in Safari, translated bilingually](docs/screenshots/safari.png)

- It uses the engines you've already set up in Lumi, with the same prompts as the workbench, so page
  titles and terminology come out well.
- Point at a paragraph and tap ⌥ to translate just that paragraph.
- Write notes (a glossary) per website.
- When Lumi isn't running, it falls back to Google Translate.

## Interface language

The interface comes in Chinese and English. Switch under **Settings › General › Interface Language**; the
change applies immediately, no restart needed. It only affects interface text — translation results,
the prompts sent to models and etymology parsing are unaffected.

Each option in the language picker is written **in its own language** (简体中文 / English), so you can
always find your way back.

## Shortcuts

| Action | Shortcut |
|---|---|
| Translate the selection | ⌥D |
| Open the input box | ⌥A |
| Translate a screenshot | ⌥S |
| Open the workbench | ⌥W |
| Workbench: new reading / proofread / etymology | ⌘N / ⇧⌘N / ⌘E |
| Workbench: start translating or proofreading | ⌘↩ |
| Safari: translate / restore the page | ⌥T |

The first four are global shortcuts and can be changed in Settings.

## Install

You need:

- **macOS 26** or later;
- a Swift toolchain — either Xcode or just the Command Line Tools (`xcode-select --install`);
- a signing identity. A free Apple ID personal-team certificate is enough; **no paid developer account
  is needed**.

Steps:

```bash
git clone https://github.com/tianruijia2008/Lumi.git
cd Lumi
security find-identity -v -p codesigning            # list your signing identities
echo "Apple Development: Your Name (TEAMID)" > .lumi-identity
./build.sh release
./run.sh
```

On first launch macOS asks for two permissions; turn them on under **System Settings › Privacy &
Security**:

- **Accessibility**: to read the selected text in other apps (needed for ⌥D).
- **Screen Recording**: to recognise text in screenshots (needed for ⌥S).

**Always launch with `./run.sh` or by double-clicking in Finder** — don't run the executable inside the
`.app` directly, or the permissions are granted to your terminal instead of Lumi. Keep the signing
identity the same, too: a new identity needs to be authorised again. The reasons are in the
[technical notes](TECHSHEET.md#运行与-tcc-授权).

Then enter the API keys for the services you want in Settings. If you only use the system dictionary
and system translator, nothing needs to be filled in.

**Enable the Safari extension**: Safari › Settings › Developer › tick **Allow unsigned extensions**, then
enable **Lumi Page Translate** under Extensions. With a free certificate, Safari forgets **Allow unsigned
extensions** every time it restarts — that's an Apple restriction.

## Privacy

- **API keys are stored only in the system Keychain**, never in a file.
- The text you translate is sent only to the services you have enabled. The system dictionary and
  system translator run entirely on your Mac.
- The Safari extension only talks to Lumi on your Mac (`127.0.0.1`). **When Lumi isn't running, the
  extension falls back to Google Translate, and the page text is sent to Google**; to avoid that, pin a
  different engine in the extension's popup.
- "Google" uses an unofficial free endpoint that may stop working at any time.

## Known limitations

- Requires macOS 26 or later; no prebuilt package.
- The Safari extension must be re-allowed every time Safari restarts (a limitation of free signing).
- Translated pages don't keep links or bold text, and content inside iframes isn't translated.
- On-device translation quality depends on the system translator and is clearly below large language
  models.
- When looking up some English words, the system dictionary may match a homophone in the Chinese
  dictionary (a priority issue in the system dictionary).

## Contributing

Issues and PRs are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) first.
The code structure is described in [STRUCTURE.md](STRUCTURE.md) and implementation details in
[TECHSHEET.md](TECHSHEET.md) (both in Chinese).

## License

[GPL-3.0](LICENSE)
