#!/usr/bin/env python3
"""守卫的自测：CI 里跑，证明 security-scan.py 真的抓得住东西。

security-scan:allow-file —— 下面 MUST_CATCH 里全是故意写的假密钥（形状与真货
一致，但没有一个是可用的用凭据），所以本文件声明跳过自身的内容扫描。删掉
这行标记，守卫就会连自己一起报——那才是预期行为。

没装东西、不联网：在临时目录里建一个迷你仓库，塞进"应该被抓"和"不应该被抓"
两组样例，断言规则命中情况。只对着一个永远为绿的扫描器是不可信的。

    python3 scripts/test-security-scan.py
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (样例内容, 期望命中的规则 id)。样例都是假的，但形状与真货一致。
MUST_CATCH: list[tuple[str, str]] = [
    ('let k = "sk-proj-QWERTYUIOPASDFGHJKLZXCVBNM1234567890abcd"', "secret/openai-family"),
    ('let k = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"', "secret/anthropic"),
    ('let k = "sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef"', "secret/openrouter"),
    ('let k = "xai-AbCdEfGhIjKlMnOpQrStUvWx"', "secret/xai"),
    ('let k = "gsk_AbCdEfGhIjKlMnOpQrStUvWxYz012345"', "secret/groq"),
    ('let k = "AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7"', "secret/google-api"),
    ('let k = "3f2b1a4c-5d6e-7f80-9a1b-2c3d4e5f6a7b:fx"', "secret/deepl"),
    ('let k = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"', "secret/github"),
    ('let k = "AKIA3XQZ7K2M9PLW4RTU"', "secret/aws"),
    ('let k = "xoxb-123456789012-abcdefghijklmnopqrstuvwx"', "secret/slack"),
    ('let k = "hf_AbCdEfGhIjKlMnOpQrStUvWxYz012345"', "secret/huggingface"),
    ("-----BEGIN RSA PRIVATE KEY-----", "secret/private-key"),
    ('let key = "8f3a9c1d7b2e4f605a1c8d9e0f2b3a4c5d6e7f8091a2b3c4"', "secret/high-entropy"),
    ('let apiKey = "Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0Lm"', "secret/high-entropy"),
    ('touch dev@realcorp.io', "personal/email"),
    ('IDENTITY="Apple Development: dev@realcorp.io (AB12CD34EF)"', "personal/apple-team-id"),
    ('let p = "/Users/jerry/Developer/Lumi/build"', "personal/home-path"),
]

# 这些必须保持安静，否则日常开发会被无意义的红点淹没。
MUST_STAY_QUIET: list[str] = [
    'let k = "sk-YOUR_API_KEY"',
    'let k = "sk-xxxxxxxxxxxxxxxxxxxx"',
    'let k = "your-key-here-replace-me-please"',
    'key = "data-relationship-lens-focus"',
    'let email = "tianruijia2008@users.noreply.github.com"',
    'let id = "com.tianruijia.Lumi"',
    '// 示例：apiKey = "sk-placeholder-placeholder"',
    'utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95',
    'let hash = "e3b0c44298fc1c149afbf4c8996fb924"   // 空串的 sha256',
    'let url = "https://api.deepseek.com/v1/chat/completions"',
    'let k = "AKIAIOSFODNN7EXAMPLE"',      # AWS 文档里公开发布的样板值
]


# ---------------------------------------------------------------- 契约自测
# 这一组验证"注释里写明的契约"真的会在被破坏时失败。
# 做法：把 invariants 阶段会读到的那些文件拷到临时目录，改一处，看是否报出来。

INVARIANT_FIXTURES: list[tuple[str, str, str, str]] = [
    # (相对路径, 旧文本, 新文本, 期望命中的规则)
    (f"{''}{'EXTENSION_PLACEHOLDER'}/background.js", "47121", "47122", "invariant/port-mismatch"),
    (f"{''}{'EXTENSION_PLACEHOLDER'}/background.js", "127.0.0.1:47121", "evil.example.net:47121",
     "invariant/bridge-host"),
    (f"{''}{'EXTENSION_PLACEHOLDER'}/content.js", "http://www.w3.org/1999/xhtml",
     "http://tracker.example.net/beacon", "invariant/new-egress"),
    ("build.sh", 'codesign --force --options runtime \\\n         --entitlements',
     'codesign --force --options runtime --deep \\\n         --entitlements',
     "invariant/codesign-deep"),
    ("Lumi.entitlements", "<key>com.apple.security.app-sandbox</key>            <false/>",
     "<key>com.apple.security.app-sandbox</key>            <true/>", "invariant/sandbox"),
    ("Package.swift", "let package = Package(",
     "let package = Package(dependencies: [.package(url: \"https://x/y\", from: \"1.0.0\")],", 
     "invariant/dependency-added"),
]

MANIFEST_FIXTURE = (
    "Extensions/Safari/WebExtension/manifest.json",
    '"http://127.0.0.1/*"', '"*://*/*"', "invariant/wildcard-permission",
)


def invariant_rules(scanner, relative: str, old: str, new: str) -> set[str]:
    """把仓库里 invariants 需要的那几个文件拷出来，改一处，跑一遍。"""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        wanted = ["Package.swift", "build.sh", "Lumi.entitlements",
                  "Extensions/Safari/Extension.entitlements",
                  "Sources/Lumi/PageBridge/PageBridge.swift"]
        wanted += [str(p.relative_to(REPO))
                   for p in (REPO / "Extensions/Safari/WebExtension").rglob("*") if p.is_file()]
        for item in wanted:
            source = REPO / item
            if not source.is_file():
                continue
            target = root / item
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        target = root / relative
        text = target.read_text(encoding="utf-8")
        if old not in text:
            return {"__fixture-missing__"}
        target.write_text(text.replace(old, new, 1), encoding="utf-8")
        return {f.rule for f in scanner.scan_invariants(root)}


def load_scanner():
    spec = importlib.util.spec_from_file_location("scanner", REPO / "scripts" / "security-scan.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def rules_for(scanner, relative: str, text: str) -> set[str]:
    """把样例写成一个真文件，走一遍真正的扫描路径。"""
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text + "\n", encoding="utf-8")
        return {f.rule for f in scanner.scan_secrets(Path(tmp), [relative], staged=False)}


def main() -> int:
    scanner = load_scanner()

    # git 缺失时跳过（自测不阻塞开发），但不假装通过。
    if subprocess.run(["git", "--version"], capture_output=True).returncode != 0:
        print("✗ 找不到 git，无法自测", file=sys.stderr)
        return 2

    failures: list[str] = []
    for text, expected in MUST_CATCH:
        actual = rules_for(scanner, "Sources/Lumi/Core/Sample.swift", text)
        if expected not in actual:
            failures.append(f"漏报：期望 {expected}，实际 {sorted(actual) or '无'}\n        {text}")
    for text in MUST_STAY_QUIET:
        actual = rules_for(scanner, "Sources/Lumi/Core/Sample.swift", text)
        if actual:
            failures.append(f"误报：{sorted(actual)}\n        {text}")
    for name, expected in ((".env", "secret-file/env-file"),
                           ("certs/dev.p12", "secret-file/key-material"),
                           ("id_rsa", "secret-file/ssh-key")):
        actual = rules_for(scanner, name, "harmless")
        if expected not in actual:
            failures.append(f"漏报文件名规则：期望 {expected}，实际 {sorted(actual) or '无'}（{name}）")

    for relative, old, new, expected in INVARIANT_FIXTURES + [MANIFEST_FIXTURE]:
        relative = relative.replace("EXTENSION_PLACEHOLDER", "Extensions/Safari/WebExtension")
        actual = invariant_rules(scanner, relative, old, new)
        if expected not in actual:
            failures.append(f"契约漏报：{relative} 期望 {expected}，实际 {sorted(actual) or '无'}")

    total = len(MUST_CATCH) + len(MUST_STAY_QUIET) + 3 + len(INVARIANT_FIXTURES) + 1
    if failures:
        print(f"✗ 守卫自测未通过（{len(failures)}/{total}）：")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"✓ 守卫自测通过：{len(MUST_CATCH)} 种泄露全部命中，"
          f"{len(MUST_STAY_QUIET) + 3} 类正常内容零误报，"
          f"{len(INVARIANT_FIXTURES) + 1} 条契约改坏都会被抓住")
    return 0


if __name__ == "__main__":
    sys.exit(main())
