#!/usr/bin/env python3
"""Lumi 仓库守卫：密钥 / 个人信息 / 仓库卫生 / 文档漂移。

同一个脚本被三处调用，避免"本地过了 CI 挂"：

    python3 scripts/security-scan.py --phase secrets --staged   # pre-commit 钩子
    python3 scripts/security-scan.py --phase secrets            # 扫全部已跟踪文件
    python3 scripts/security-scan.py --phase hygiene
    python3 scripts/security-scan.py --phase docs
    python3 scripts/security-scan.py --phase invariants         # 代码注释里写明的设计契约
    python3 scripts/security-scan.py                            # 全部（CI 默认）

只用 Python 标准库，不需要联网、不需要装东西。
退出码：0 干净 / 1 发现问题 / 2 用法或环境错误。

隐私：命中内容一律脱敏后再打印，日志里不会出现完整密钥。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

# ---------------------------------------------------------------- 规则表

# (规则 id, 正则, 人话说明)。这些前缀是厂商自己定义的，误报率极低。
SECRET_PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    ("openai-family", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
     "OpenAI / DeepSeek / Moonshot / SiliconFlow 风格的 API key"),
    ("anthropic", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "Anthropic API key"),
    ("openrouter", re.compile(r"\bsk-or-v1-[A-Za-z0-9]{32,}"), "OpenRouter API key"),
    ("xai", re.compile(r"\bxai-[A-Za-z0-9]{20,}"), "xAI API key"),
    ("groq", re.compile(r"\bgsk_[A-Za-z0-9]{20,}"), "Groq API key"),
    ("google-api", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"), "Google / Gemini API key"),
    ("deepl", re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:fx\b"),
     "DeepL API key（UUID:fx 形式）"),
    ("github", re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
     "GitHub token"),
    ("aws", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    ("slack", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"), "Slack token"),
    ("stripe", re.compile(r"\b[sr]k_live_[A-Za-z0-9]{20,}"), "Stripe live key"),
    ("huggingface", re.compile(r"\bhf_[A-Za-z0-9]{20,}"), "HuggingFace token"),
    ("google-oauth", re.compile(r"\bGOCSPX-[A-Za-z0-9_-]{20,}"), "Google OAuth client secret"),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"),
     "私钥文件内容"),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
     "JWT（可能是会话令牌）"),
]

# 关键词 + 高熵串：抓"手滑粘贴"的通用密钥。必须是 `key = "..."` 这种赋值形态，
# 而不是同一行里恰好出现 key 字样——否则 HTML 里的 `data-relationship-lens-focus`
# 之类会全部命中。
ENTROPY_ASSIGNMENT = re.compile(
    r"(?i)\b(api[_-]?key|apikey|access[_-]?key|secret|token|password|passwd|"
    r"credential|client[_-]?secret|key)\b\s*[:=]\s*\"?'?([A-Za-z0-9+/=_\-]{24,})"
)
# 生成物：由规格/脚本产出，不当作人工内容逐行扫（规格本身会被扫）。
GENERATED = re.compile(
    r"^docs/.*\.html$"
    r"|^docs/.*\.visual-check\.(json|html|png)$"
    r"|\.min\.(js|css)$"
    r"|\.(woff2?|pcm|png|icns|jpg|jpeg|webp)$"
)

EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
APPLE_TEAM = re.compile(r"\([A-Z0-9]{10}\)")
# 文档里会合法地出现 /Users/<name>、/Users/you 这类占位写法，不报；
# 写成真实用户名的那种必须报（具体样例见 scripts/test-security-scan.py）。
HOME_PATH = re.compile(
    r"/Users/(?!(?:Shared|you|me|name|user|username|xxx+|USER|<)\b)[A-Za-z0-9._\-]+")

# 文档里写清楚为什么允许：这些是命名空间/示例，不是联系方式，而且改了会破坏
# TCC 授权与 Keychain 条目的对应关系（见 STRUCTURE.md 第 6 节）。
ALLOWED_IDENTIFIERS = (
    "com.tianruijia.",              # bundle id 前缀，改了会影响 TCC / Keychain
    "tianruijia2008@users.noreply.github.com",  # 已经是 noreply 地址
)
# 占位串：文档和模板里应该出现，不该报警。
# 注意：绝不能拿这些词做子串匹配——真密钥里出现一串 "123456" 并不稀奇，
# 早期版本就是因此漏掉了一个 `sk-proj-…123456…`。
PLACEHOLDER_STRONG = (
    "your", "example", "sample", "dummy", "fake", "placeholder", "redacted",
    "changeme", "replace-me", "replaceme", "notreal", "todo", "fixme",
)
PLACEHOLDER_LOOSE = PLACEHOLDER_STRONG + ("xxxx", "test", "123456", "abcdef", "foo", "bar")
# 厂商文档里公开发布的样板值：它们不是泄露，但形状和真货一样。
KNOWN_DUMMIES = ("AKIAIOSFODNN7EXAMPLE",)

# 绝对不该出现在仓库里的文件名 / 目录名。
FORBIDDEN_PATH_PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    ("build-dir", re.compile(r"(^|/)\.build/"), "SwiftPM 构建产物目录"),
    ("app-bundle", re.compile(r"(^|/)build/"), "build.sh 组装出的 .app"),
    ("bundle-suffix", re.compile(r"\.(app|appex|dSYM|xcarchive)/"), "打包产物"),
    ("code-signature", re.compile(r"_CodeSignature/"), "代码签名产物"),
    ("xcuserstate", re.compile(r"\.xcuserstate$|xcuserdata/"), "Xcode 用户状态"),
    ("swiftpm", re.compile(r"(^|/)\.swiftpm/"), "SwiftPM 本地状态"),
    ("ds-store", re.compile(r"(^|/)\.DS_Store$"), "Finder 垃圾文件"),
    ("object-file", re.compile(r"\.(o|swiftmodule|swiftdoc|pcm|dia)$"), "编译中间产物"),
    ("key-material", re.compile(r"\.(p12|pfx|pem|key|keystore|jks|mobileprovision|provisionprofile)$"),
     "证书 / 描述文件 / 私钥"),
    ("env-file", re.compile(r"(^|/)\.env(\.|$)|(^|/)\.env$"), "环境变量文件（常放密钥）"),
    ("ssh-key", re.compile(r"(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$"), "SSH 私钥"),
    ("credentials", re.compile(r"(^|/)(credentials|token|secrets?)\.json$"), "凭据 JSON"),
]

MAX_FILE_BYTES = 5 * 1024 * 1024      # 单文件上限，超过说明误提交了二进制
SCAN_SIZE_LIMIT = 2 * 1024 * 1024     # 超过就不再逐行扫内容（避免读大文件）
# 文件内标记：跳过这个文件的内容扫描。只给"本身就必须包含假密钥"的文件用
# （例如守卫的自测样例），且必须写在文件前几行、评审时一眼能看到。
# 路径规则、大小检查仍然生效；跳过时会在日志里点名。
ALLOW_FILE_MARKER = "security-scan:allow-file"
PLACEHOLDER_NAMESPACE = {"users.noreply.github.com", "example.com", "example.org",
                         "localhost", "test.com", "invalid"}

# ---------------------------------------------------------------- 基础设施


class ScanAbort(Exception):
    """用法或环境问题（退出码 2），不是"发现密钥"。"""


def git(*args: str, root: Path) -> str:
    try:
        out = subprocess.run(["git", *args], cwd=str(root), check=True,
                             capture_output=True, text=True)
    except FileNotFoundError as exc:  # 没装 git
        raise ScanAbort("找不到 git 可执行文件") from exc
    except subprocess.CalledProcessError as exc:
        raise ScanAbort(f"git {' '.join(args)} 失败：{exc.stderr.strip()}") from exc
    return out.stdout


def repo_root(start: Path) -> Path | None:
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=str(start),
                             capture_output=True, text=True)
    except FileNotFoundError:
        return None
    if out.returncode != 0:
        return None
    return Path(out.stdout.strip())


def tracked_files(root: Path) -> list[str]:
    raw = git("ls-files", "-z", root=root)
    return sorted(p for p in raw.split("\0") if p)


def staged_files(root: Path) -> list[str]:
    raw = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z", root=root)
    return sorted(p for p in raw.split("\0") if p)


def walk_files(root: Path) -> list[str]:
    """非 git 环境下的退而求其次：目录遍历。

    权威扫描永远是 git 的文件清单（已跟踪 / 已 staged）；这里只是方便
    在没有仓库时也能跑，所以要手动排除 .gitignore 里的本机文件。
    """
    skip = {".git", ".build", "build", "node_modules"}
    local_only = re.compile(r"(^|/)\.lumi-identity$|(^|/)\.env|(^|/)\.DS_Store$")
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for name in filenames:
            relative = str(Path(dirpath, name).relative_to(root))
            if local_only.search(relative):
                continue
            found.append(relative)
    return sorted(found)


def staged_content(root: Path, path: str) -> bytes:
    """读索引里的 blob，而不是工作区文件：`git add -p` 之后两者可能不同。"""
    try:
        out = subprocess.run(["git", "show", f":{path}"], cwd=str(root),
                             check=True, capture_output=True)
        return out.stdout
    except (FileNotFoundError, subprocess.CalledProcessError):
        try:
            return (root / path).read_bytes()
        except OSError:
            return b""


def read_text(root: Path, path: str, staged: bool) -> str | None:
    try:
        size = (root / path).stat().st_size if not staged else None
    except OSError:
        size = None
    if size is not None and size > SCAN_SIZE_LIMIT:
        return None
    data = staged_content(root, path) if staged else _read_bytes(root, path)
    if data is None or b"\0" in data[:4096]:
        return None
    try:
        return data.decode("utf-8", errors="replace")
    except Exception:
        return None


def _read_bytes(root: Path, path: str) -> bytes | None:
    try:
        return (root / path).read_bytes()
    except OSError:
        return None


def entropy(text: str) -> float:
    if not text:
        return 0.0
    counts = Counter(text)
    return -sum((n / len(text)) * math.log2(n / len(text)) for n in counts.values())


def redact(value: str) -> str:
    if len(value) <= 10:
        return value[:2] + "*" * max(1, len(value) - 2)
    return f"{value[:6]}…{value[-4:]}（{len(value)} 字符）"


def is_placeholder(value: str, strict: bool = True) -> bool:
    """判断“看起来就是占位符”。

    strict=True  —— 厂商前缀模式（sk-…、AIza…）用，只认强占位词，宁可误报。
    strict=False —— 通用熵模式用（行里本来就是 key = "..." 的形态），
                    允许宽一点，免得文档例句把 CI 卡成红的。
    """
    lowered = value.lower()
    body = re.sub(r"^(sk-ant-|sk-or-v1-|sk-|gsk_|xai-|hf_|gh[pousr]_|AKIA|AIza|GOCSPX-)",
                  "", lowered).strip("'\"<>")
    if value in KNOWN_DUMMIES or len(set(body)) <= 3:   # 官方样板值 / sk-aaaa…
        return True
    if "xxxx" in body:
        return True
    if body.startswith(tuple(PLACEHOLDER_STRONG)):
        return True
    if len(value) < 24 and any(word in body for word in PLACEHOLDER_STRONG):
        return True
    if not strict and any(word in body for word in PLACEHOLDER_LOOSE):
        return True
    return False


class Finding:
    __slots__ = ("path", "line", "rule", "detail")

    def __init__(self, path: str, line: int, rule: str, detail: str) -> None:
        self.path, self.line, self.rule, self.detail = path, line, rule, detail

    def render(self) -> str:
        location = f"{self.path}:{self.line}" if self.line else self.path
        return f"  {location}  [{self.rule}] {self.detail}"


def report(title: str, findings: list[Finding], hint: str = "") -> bool:
    print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")
    if not findings:
        print("  ✓ 通过")
        return True
    for finding in findings:
        print(finding.render())
    print(f"\n  ✗ {len(findings)} 处问题")
    if hint:
        print(f"  → {hint}")
    return False


# ---------------------------------------------------------------- phase: secrets


def scan_secrets(root: Path, files: list[str], staged: bool,
                 allowed_files: list[str] | None = None) -> list[Finding]:
    findings: list[Finding] = []
    allowed_files = allowed_files if allowed_files is not None else []
    for path in files:
        # 1) 文件名本身就是问题（私钥、.env、证书……）
        for rule, pattern, why in FORBIDDEN_PATH_PATTERNS:
            if rule in {"key-material", "env-file", "ssh-key", "credentials"} and pattern.search(path):
                findings.append(Finding(path, 0, f"secret-file/{rule}", why))
        # 2) 内容
        # 生成物（交付的 HTML、visual-check receipt）不逐行扫密钥形状——它们体积大、
        # 全是机器写的，扫了也没法改；但**个人信息照样查**：receipt 里就带着绝对
        # 家目录路径（.artifact.path），那是真会泄露用户名的东西。
        generated = bool(GENERATED.search(path))
        text = read_text(root, path, staged)
        if text is None:
            continue
        if not generated and ALLOW_FILE_MARKER in "\n".join(text.splitlines()[:8]):
            allowed_files.append(path)
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            for rule, pattern, why in (() if generated else SECRET_PATTERNS):
                for match in pattern.finditer(line):
                    value = match.group(0)
                    if is_placeholder(value):
                        continue
                    findings.append(Finding(path, lineno, f"secret/{rule}",
                                            f"{why}：{redact(value)}"))
            for match in (() if generated else ENTROPY_ASSIGNMENT.finditer(line)):
                value = match.group(2)
                # 真密钥几乎总含数字；要求有数字是为了放过
                # `key = "data-relationship-lens-focus"` 这类连字符标识符。
                if not any(ch.isdigit() for ch in value):
                    continue
                if is_placeholder(value, strict=False) or entropy(value) < 3.5:
                    continue
                findings.append(Finding(path, lineno, "secret/high-entropy",
                                        f"高熵串（{redact(value)}）赋值给了 {match.group(1)}"))
            for match in EMAIL.finditer(line):
                address = match.group(0)
                if any(allowed in address for allowed in ALLOWED_IDENTIFIERS):
                    continue
                if address.split("@")[-1].lower() in PLACEHOLDER_NAMESPACE:
                    continue
                findings.append(Finding(path, lineno, "personal/email", f"邮箱地址：{address}"))
            for match in HOME_PATH.finditer(line):
                if "com.tianruijia." in line:      # bundle id，见 ALLOWED_IDENTIFIERS
                    continue
                findings.append(Finding(path, lineno, "personal/home-path",
                                        f"绝对家目录路径：{match.group(0)}"))
            if APPLE_TEAM.search(line) and re.search(r"(?i)apple development|developer id|team ?id", line):
                findings.append(Finding(path, lineno, "personal/apple-team-id",
                                        "签名身份里的团队 ID / 邮箱，请改为从 LUMI_IDENTITY 或本地文件读取"))
    return findings


# ---------------------------------------------------------------- phase: hygiene


def scan_hygiene(root: Path, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        for rule, pattern, why in FORBIDDEN_PATH_PATTERNS:
            if rule in {"key-material", "env-file", "ssh-key", "credentials"}:
                continue                      # 交给 secrets 阶段报，避免重复
            if pattern.search(path):
                findings.append(Finding(path, 0, f"hygiene/{rule}", why))
                break
        absolute = root / path
        try:
            size = absolute.stat().st_size
        except OSError:
            continue
        if size > MAX_FILE_BYTES:
            findings.append(Finding(path, 0, "hygiene/large-file",
                                    f"{size / 1024 / 1024:.1f} MB（上限 5 MB）"))
        header = _read_bytes(root, path)
        if header and header[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                                     b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
            findings.append(Finding(path, 0, "hygiene/mach-o", "编译产物（Mach-O 可执行文件）"))
    return findings


# ---------------------------------------------------------------- phase: docs


# 文档类文件：链接都要有效（新增一份文档就加进来，别让它变成第二个漂移源）。
DOC_FILES = ("STRUCTURE.md", "README.md", "TECHSHEET.md", "AGENTS.md",
             "CONTRIBUTING.md", "CLAUDE.md")
# Claude Code 的记忆文件用 `@路径` 导入别的文件（如 CLAUDE.md -> @AGENTS.md）。
# 这种导入没有 markdown 链接语法，所以要单独查目标是否存在。
AT_IMPORT = re.compile(r"^@([A-Za-z0-9_./\-]+\.md)\s*$")
CENSUS_ROW = re.compile(r"^\|\s*`(\w+)`\s*\|\s*(\d+)\s*\|\s*([\d,]+)\s*\|")
CENSUS_TOTAL = re.compile(r"^\|\s*\*\*合计\*\*\s*\|\s*\*\*(\d+)\*\*\s*\|\s*\*\*([\d,]+)\*\*\s*\|")
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def spec_files(root: Path) -> list[Path]:
    """docs/archify 下的**规格**（排除 *.deliver.json 交付回执）。"""
    return sorted(p for p in (root / "docs" / "archify").glob("*.json")
                  if not p.name.endswith(".deliver.json"))


def scan_docs(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    structure = root / "STRUCTURE.md"
    if not structure.is_file():
        return [Finding("STRUCTURE.md", 0, "docs/missing", "找不到结构文档")]

    # 1) 相对链接必须存在
    for doc in DOC_FILES:
        path = root / doc
        if not path.is_file():
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for target in MARKDOWN_LINK.findall(line):
                if target.startswith(("http://", "https://", "#", "mailto:")):
                    continue
                clean = target.split("#", 1)[0].strip()
                if not clean:
                    continue
                if not (root / clean).exists():
                    findings.append(Finding(doc, lineno, "docs/dead-link",
                                            f"链接目标不存在：{clean}"))
            imported = AT_IMPORT.match(line.strip())
            if imported and not (root / imported.group(1)).exists():
                findings.append(Finding(doc, lineno, "docs/dead-import",
                                        f"@ 导入的文件不存在：{imported.group(1)}"))

    # 2) 模块清单必须和真实文件数一致（防止文档悄悄过期）
    counts: dict[str, tuple[int, int]] = {}
    sources = root / "Sources" / "Lumi"
    if sources.is_dir():
        for directory in sorted(p for p in sources.iterdir() if p.is_dir()):
            files = sorted(directory.glob("*.swift"))
            counts[directory.name] = (len(files),
                                      sum(len(f.read_text(encoding="utf-8").splitlines())
                                          for f in files))
    total_files = sum(c[0] for c in counts.values())
    total_lines = sum(c[1] for c in counts.values())

    documented: dict[str, tuple[int, int]] = {}
    for lineno, line in enumerate(structure.read_text(encoding="utf-8").splitlines(), 1):
        match = CENSUS_ROW.match(line)
        if match:
            documented[match.group(1)] = (int(match.group(2)), int(match.group(3).replace(",", "")))
            continue
        total = CENSUS_TOTAL.match(line)
        if total:
            if (int(total.group(1)), int(total.group(2).replace(",", ""))) != (total_files, total_lines):
                findings.append(Finding("STRUCTURE.md", lineno, "docs/drift",
                                        f"合计写的是 {total.group(1)} 文件 / {total.group(2)} 行，"
                                        f"实际是 {total_files} 文件 / {total_lines} 行"))
    for module, (files, lines) in documented.items():
        actual = counts.get(module)
        if actual is None:
            findings.append(Finding("STRUCTURE.md", 0, "docs/drift",
                                    f"表里写了模块 {module}，但 Sources/Lumi/{module} 不存在"))
        elif actual != (files, lines):
            findings.append(Finding("STRUCTURE.md", 0, "docs/drift",
                                    f"{module}：表里 {files} 文件 / {lines} 行，"
                                    f"实际 {actual[0]} 文件 / {actual[1]} 行"))
    for module in counts:
        if module not in documented:
            findings.append(Finding("STRUCTURE.md", 0, "docs/drift",
                                    f"新模块 {module} 没写进模块清单"))

    # 3) 两张图的规格必须是合法 JSON，且产物存在（STRUCTURE.md 顶部就承诺了）
    for spec in spec_files(root):
        try:
            data = json.loads(spec.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            findings.append(Finding(str(spec.relative_to(root)), 0, "docs/invalid-json", str(exc)[:120]))
            continue
        if "diagram_type" not in data:
            findings.append(Finding(str(spec.relative_to(root)), 0, "docs/invalid-spec",
                                    "缺少 diagram_type"))
        artifact = root / "docs" / f"lumi-{data.get('diagram_type', 'x')}.html"
        if not artifact.is_file():
            findings.append(Finding(str(spec.relative_to(root)), 0, "docs/missing-artifact",
                                    f"缺少对应的 HTML：{artifact.name}"))

    # 4) 交付回执：规格 sha256 与产物 sha256 都必须对得上。
    #    这条把 规格 -> HTML -> 浏览器证据 连成一条链：
    #    改了规格没重新 deliver、或改了 HTML 没重新 deliver，都会在这里断。
    for spec in spec_files(root):
        receipt = spec.with_name(spec.name.replace(".json", ".deliver.json"))
        if not receipt.is_file():
            findings.append(Finding(f"docs/archify/{receipt.name}", 0, "docs/missing-receipt",
                                    f"缺少 {spec.name} 的交付回执（重新跑一次 deliver --json 并存入）"))
            continue
        try:
            data = json.loads(receipt.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            findings.append(Finding(str(receipt.relative_to(root)), 0, "docs/invalid-receipt",
                                    str(exc)[:120]))
            continue
        spec_sha = hashlib.sha256(spec.read_bytes()).hexdigest()
        if data.get("specification", {}).get("sha256") != spec_sha:
            findings.append(Finding(str(receipt.relative_to(root)), 0, "docs/stale-receipt",
                                    f"{spec.name} 在交付之后被改过，需要重新 deliver"))
        artifact = root / "docs" / f"lumi-{data.get('type', 'x')}.html"
        if artifact.is_file() and data.get("artifact", {}).get("sha256") \
                and hashlib.sha256(artifact.read_bytes()).hexdigest() != data["artifact"]["sha256"]:
            findings.append(Finding(str(receipt.relative_to(root)), 0, "docs/stale-receipt",
                                    f"{artifact.name} 与交付回执不符（HTML 被手改过）"))
        validation = data.get("validation", {})
        if validation.get("compositionStatus") != "pass" or validation.get("errors"):
            findings.append(Finding(str(receipt.relative_to(root)), 0, "docs/failed-receipt",
                                    f"交付回执不是 showcase 通过：{validation}"))

    # 5) 图产物指纹：receipt 里的 sha256 必须等于仓库里那份 HTML，
    #    这样“手改生成的 HTML”和“重新 deliver 后忘了重跑 visual-check”都会被发现。
    for receipt in sorted((root / "docs").glob("*.visual-check.json")):
        relative = str(receipt.relative_to(root))
        try:
            data = json.loads(receipt.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            findings.append(Finding(relative, 0, "docs/invalid-receipt", str(exc)[:120]))
            continue
        artifact = root / "docs" / Path(data.get("artifact", {}).get("path", "")).name
        recorded = data.get("artifact", {}).get("sha256", "")
        if not artifact.is_file():
            findings.append(Finding(relative, 0, "docs/missing-artifact",
                                    f"receipt 指向的 {artifact.name} 不在库里"))
        elif recorded:
            if hashlib.sha256(artifact.read_bytes()).hexdigest() != recorded:
                findings.append(Finding(relative, 0, "docs/stale-receipt",
                                        f"{artifact.name} 的 sha256 与 receipt 不符"
                                        "（HTML 被手改，或 deliver 后没重跑 visual-check）"))
        if data.get("status") not in (None, "pass"):
            findings.append(Finding(relative, 0, "docs/failed-receipt",
                                    f"入库的浏览器证据状态是 {data.get('status')}，不是 pass"))
    return findings


# ------------------------------------------------------- phase: invariants

# 这些是"目前只写在注释里"的契约。注释不会在 CI 里失败，所以把它们变成检查：
# 每一条都对应代码里一句 hard-won 的说明，改坏了会以真实故障的形式出现。
EXTENSION_DIR = "Extensions/Safari/WebExtension"

# 扩展允许联系的主机。多一个都必须是有意识的评审决定，而不是"没人注意"：
#   127.0.0.1                 本机 PageBridge（主路径，见 PageBridge.swift）
#   translate.googleapis.com  Lumi 没在运行时的 Google 兜底翻译
#                             （会把段落发给 Google——既定设计，但必须写在明面上）
#   www.w3.org                XHTML 命名空间字符串，不是网络请求
ALLOWED_EXTENSION_HOSTS = {
    "127.0.0.1": "本机 PageBridge（:47121）",
    "translate.googleapis.com": "Lumi 未运行时的 Google 兜底翻译（会把段落发给 Google）",
    "www.w3.org": "XHTML 命名空间字符串，不是网络请求",
}
HOST_IN_URL = re.compile(r"https?://([A-Za-z0-9._\-]+)")
WILDCARD_PERMISSION = re.compile(r"\*://|^\*$|<all_urls>")


def read_repo_file(root: Path, relative: str) -> str | None:
    path = root / relative
    return path.read_text(encoding="utf-8") if path.is_file() else None


def _codesign_invocations(build_text: str) -> list[tuple[int, str]]:
    """把 build.sh 里每一条 codesign 命令捞出来，合并续行、忽略注释行。

    不能直接在全文里 grep "--deep"：build.sh 本来就有一条
    `codesign --verify --deep --strict`（校验嵌套签名，完全正常）。
    要管的是**签名**那两条。
    """
    invocations: list[tuple[int, str]] = []
    start = 0
    parts: list[str] = []
    for number, line in enumerate(build_text.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        if not parts and not line.lstrip().startswith("codesign"):
            continue
        if not parts:
            start = number
        continued = line.rstrip().endswith("\\")
        parts.append(line.rstrip().rstrip("\\").strip())
        if not continued:
            invocations.append((start, " ".join(parts)))
            parts = []
    if parts:
        invocations.append((start, " ".join(parts)))
    return invocations


def _is_verification(command: str) -> bool:
    return "--verify" in command


def _check_port_agreement(root: Path, findings: list[Finding]) -> None:
    """PageBridge.swift 的注释写着"必须与扩展里的 LUMI_PORT 一致"——没有东西在检查它。"""
    swift = read_repo_file(root, "Sources/Lumi/PageBridge/PageBridge.swift")
    js = read_repo_file(root, f"{EXTENSION_DIR}/background.js")
    if swift is None or js is None:
        findings.append(Finding("Sources/Lumi/PageBridge/PageBridge.swift", 0, "invariant/unreadable",
                                "读不到 PageBridge.swift 或 background.js，端口一致性无法验证"))
        return
    swift_port = re.search(r"static let port\s*:\s*UInt16\s*=\s*([0-9_]+)", swift)
    js_endpoint = re.search(r"LUMI\s*=\s*['\"](https?://[^'\"]+)['\"]", js)
    if not swift_port or not js_endpoint:
        findings.append(Finding("Sources/Lumi/PageBridge/PageBridge.swift", 0,
                                "invariant/port-unparsable",
                                "没能从代码里解析出端口声明，请更新这条规则而不是删掉它"))
        return
    expected = int(swift_port.group(1).replace("_", ""))
    host, _, port = js_endpoint.group(1).partition("://")
    actual_host, _, actual_port = port.partition(":")
    if host != "http":
        findings.append(Finding(f"{EXTENSION_DIR}/background.js", 0, "invariant/bridge-scheme",
                                f"扩展访问桥用的是 {host}，回环桥只可能是 http"))
    if actual_host not in ("127.0.0.1", "localhost", "[::1]"):
        findings.append(Finding(f"{EXTENSION_DIR}/background.js", 0, "invariant/bridge-host",
                                f"扩展指向的主机是 {actual_host}，桥必须只在回环上"))
    if actual_port != str(expected):
        findings.append(Finding(f"{EXTENSION_DIR}/background.js", 0, "invariant/port-mismatch",
                                f"扩展用 {actual_port}，PageBridge 用 {expected}——"
                                "两者不一致时网页翻译会静默失效"))


def _check_extension_egress(root: Path, findings: list[Finding]) -> None:
    """扩展的网络出口 = 用户的隐私边界，新主机必须是一次有意识的改动。"""
    extension = root / EXTENSION_DIR
    if not extension.is_dir():
        findings.append(Finding(EXTENSION_DIR, 0, "invariant/unreadable", "找不到扩展目录"))
        return
    hosts: dict[str, str] = {}
    for path in sorted(extension.rglob("*")):
        if not path.is_file() or path.suffix not in {".js", ".json", ".html"}:
            continue
        relative = str(path.relative_to(root))
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in HOST_IN_URL.finditer(text):
            hosts.setdefault(match.group(1), relative)
        if path.name == "manifest.json":
            try:
                manifest = json.loads(text)
            except json.JSONDecodeError as exc:
                findings.append(Finding(relative, 0, "invariant/manifest", str(exc)[:120]))
                continue
            # content_scripts 的 <all_urls> 是机制本身（要在页面里注入），
            # 但 host_permissions 里的通配符等于把出口开给整个互联网。
            for permission in manifest.get("host_permissions", []):
                if WILDCARD_PERMISSION.search(permission):
                    findings.append(Finding(relative, 0, "invariant/wildcard-permission",
                                            f"host_permissions 含通配：{permission}"))
    for host, where in sorted(hosts.items()):
        if host not in ALLOWED_EXTENSION_HOSTS:
            findings.append(Finding(where, 0, "invariant/new-egress",
                                    f"扩展出现了新的对外主机：{host}"
                                    "（确认过就加进 ALLOWED_EXTENSION_HOSTS 并写明原因）"))


def _check_entitlements_and_signing(root: Path, findings: list[Finding]) -> None:
    """build.sh 的注释解释了为什么不能 --deep、appex 为什么必须 sandbox。
    这些一旦被"简化"掉，表现是 Safari 拒绝加载扩展 / TCC 授权失效，离原因很远。"""
    app_entitlements = root / "Lumi.entitlements"
    extension_entitlements = root / "Extensions/Safari/Extension.entitlements"
    for path, expected_sandbox, why in (
        (app_entitlements, False, "App 需要 Accessibility / 屏幕录制，必须关沙箱"),
        (extension_entitlements, True, "Safari 拒绝加载未沙箱的扩展"),
    ):
        if not path.is_file():
            findings.append(Finding(str(path.relative_to(root)), 0, "invariant/missing", "文件不存在"))
            continue
        try:
            data = plistlib.loads(path.read_bytes())
        except Exception as exc:
            findings.append(Finding(str(path.relative_to(root)), 0, "invariant/entitlements",
                                    f"不是合法 plist：{exc}"))
            continue
        sandbox = data.get("com.apple.security.app-sandbox")
        if sandbox is not expected_sandbox:
            findings.append(Finding(str(path.relative_to(root)), 0, "invariant/sandbox",
                                    f"app-sandbox={sandbox}，应为 {expected_sandbox}（{why}）"))
    build = read_repo_file(root, "build.sh")
    if build is None:
        findings.append(Finding("build.sh", 0, "invariant/unreadable", "找不到 build.sh"))
        return
    for lineno, command in _codesign_invocations(build):
        if _is_verification(command):
            continue                      # `codesign --verify --deep` 是校验，无害
        if "--entitlements" not in command:
            findings.append(Finding("build.sh", lineno, "invariant/codesign-entitlements",
                                    f"签名没有显式指定 entitlements：{command[:70]}…"))
        if "--deep" in command:
            findings.append(Finding("build.sh", lineno, "invariant/codesign-deep",
                                    "--deep 会把 App 的 entitlements 盖到 appex 上，"
                                    "Safari 就不认这个扩展了"))
        if "APPEX" in command and "Extension.entitlements" not in command:
            findings.append(Finding("build.sh", lineno, "invariant/appex-entitlements",
                                    "appex 必须用 Extension.entitlements（sandbox=true），"
                                    "不能用 App 那份"))


def _check_no_dependencies(root: Path, findings: list[Finding]) -> None:
    """STRUCTURE.md 把"零第三方依赖"写成已验证事实，那就让它在 CI 里成立。"""
    package = read_repo_file(root, "Package.swift")
    if package is None:
        findings.append(Finding("Package.swift", 0, "invariant/unreadable", "找不到 Package.swift"))
        return
    if re.search(r"\.package\s*\(", package):
        findings.append(Finding("Package.swift", 0, "invariant/dependency-added",
                                "出现了外部依赖：请同时更新本规则与 STRUCTURE.md 的"
                                "『零第三方依赖』声明（那是个已验证事实，不能悄悄失效）"))


SHELL_SCRIPTS = (".githooks/pre-commit", ".githooks/pre-push", "build.sh", "run.sh",
                 "scripts/install-hooks.sh")
# `$name` 紧跟着非 ASCII 字符（例如 "到「$name」"）时，某些 /bin/sh 会把多字节字符
# 当成变量名的一部分，于是变量展开成空、而且吃掉半个 UTF-8 字符——报错信息里
# 出现 mojibake，最关键的信息（远端名、URL）反而消失。写成 ${name} 就没这问题。
DOLLAR_NAME = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*")


def _check_shell_interpolation(root: Path, findings: list[Finding]) -> None:
    for relative in SHELL_SCRIPTS:
        text = read_repo_file(root, relative)
        if text is None:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if line.lstrip().startswith("#"):
                continue
            for match in DOLLAR_NAME.finditer(line):
                following = line[match.end():match.end() + 1]
                if not following or ord(following) < 0x80:
                    continue
                # 单引号里的 $ 不会展开，跳过
                if line[:match.start()].count("'") % 2 == 1:
                    continue
                findings.append(Finding(relative, lineno, "invariant/shell-interpolation",
                                        f"{match.group(0)} 紧邻非 ASCII 字符，请写成 "
                                        f"${{{match.group(0)[1:]}}}（否则会展开成空并破坏 UTF-8）"))


# 界面文案（i18n）自检：英文界面不能出现"静默回落成中文"的地方。
#
# 表是按中文原文当 key 的（见 Core/Localization.swift），所以三件事都能机械地查：
#   1. 每个 t("…") / tDetached("…") 都有对应的英文条目（缺了界面就会漏出中文）
#   2. 表里没有没人用的条目（key 打错字时正是这个症状）
#   3. key 本身必须是中文原文（包错了字符串——例如把英文包进去——这里会报）
T_CALL = re.compile(r'\bt(?:Detached)?\(\s*"((?:[^"\\]|\\.)*)"')
TABLE_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"', re.M)
TABLE_FILE = re.compile(r"^Strings[A-Za-z]+\.swift$")
CJK = re.compile(r"[\u4e00-\u9fff]")
# 英文里绝不该出现的字符：汉字 + 中日韩标点（「」、。〈〉）+ 全角标点（：（），？！）。
# 注意**不含**省略号 … 和弯引号 “”—它们在英文里是合法的（"Settings…"、"using “x”"）。
CJK_OR_FULLWIDTH = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")


def _localization_keys(root: Path):
    """返回（代码里用到的 key，所有表的 key -> (英文, 文件, 行号)，每张表各自的条目）。

    第三项按表分开，是为了能发现"同一句中文被两张表各翻译成一个不同英文"——
    那种情况下合并顺序会静默决定谁生效，表现是"英文界面里某个词莫名其妙不对"。
    """
    sources = sorted((root / "Sources" / "Lumi").rglob("*.swift"))
    used: dict[str, tuple[str, int]] = {}
    defined: dict[str, tuple[str, int]] = {}
    tables: dict[str, dict[str, tuple[str, int]]] = {}
    for path in sources:
        text = path.read_text(encoding="utf-8")
        relative = str(path.relative_to(root))
        is_table = bool(TABLE_FILE.match(path.name))
        if is_table:
            entries: dict[str, tuple[str, int]] = {}
            for match in TABLE_ENTRY.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                entries.setdefault(match.group(1), (match.group(2), line))
                defined.setdefault(match.group(1), (relative, line))
            tables[relative] = entries
            continue
        for match in T_CALL.finditer(text):
            line_start = text.rfind("\n", 0, match.start()) + 1
            line_text = text[line_start:text.find("\n", match.start())]
            if _in_comment(line_text, match.start() - line_start):
                continue          # 文档注释里的示例调用不算调用点
            line = text.count("\n", 0, match.start()) + 1
            used.setdefault(match.group(1), (relative, line))
    return used, defined, tables


def _in_comment(line_text: str, column: int) -> bool:
    """这一行里、这个列位置之前是否已经进入了注释。"""
    stripped = line_text.lstrip()
    if stripped.startswith(("//", "*", "/*")):
        return True
    return "//" in line_text[:column]


def _check_localization(root: Path, findings: list[Finding]) -> None:
    used, defined, tables = _localization_keys(root)
    if not used and not defined:
        return
    # 英文值里不该还有中文：最常见的症状是中文标点（「」／：／……）被原样留在英文里，
    # 这种错机检最容易漏、肉眼看最刺眼。
    for table_path, entries in sorted(tables.items()):
        for key, (value, line) in sorted(entries.items()):
            leaked = CJK_OR_FULLWIDTH.findall(value)
            if leaked:
                findings.append(Finding(
                    table_path, line, "i18n/chinese-in-english",
                    f'"{value[:44]}" 的英文里还留着中文字符 {sorted(set(leaked))}'))

    # 跨表冲突：同一条中文在两处被译成不同英文
    first_seen: dict[str, tuple[str, str, int]] = {}
    for table_path, entries in sorted(tables.items()):
        for key, (value, line) in sorted(entries.items()):
            if key in first_seen:
                previous_value, previous_file, _ = first_seen[key]
                if previous_value != value:
                    findings.append(Finding(
                        table_path, line, "i18n/conflicting-entry",
                        f'"{key[:32]}" 在 {previous_file} 是 "{previous_value}"，'
                        f'这里是 "{value}"——同一句中文只该在一张表里定义'))
                continue
            first_seen[key] = (value, table_path, line)
    for key, (path, line) in sorted(used.items()):
        if key not in defined:
            findings.append(Finding(path, line, "i18n/missing-translation",
                                    f't("…") 没有英文条目，英文界面会漏出中文：{key[:48]}'))
        elif not CJK.search(key):
            findings.append(Finding(path, line, "i18n/not-chinese-key",
                                    f'key 里没有中文，疑似把英文/变量包进了 t()：{key[:48]}'))
    for key, (path, line) in sorted(defined.items()):
        if key not in used:
            findings.append(Finding(path, line, "i18n/unused-entry",
                                    f"表里这条没有任何 t(...) 使用（key 打错字时正是这个症状）：{key[:48]}"))


def scan_invariants(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    _check_port_agreement(root, findings)
    _check_extension_egress(root, findings)
    _check_entitlements_and_signing(root, findings)
    _check_no_dependencies(root, findings)
    _check_shell_interpolation(root, findings)
    _check_localization(root, findings)
    return findings


# ---------------------------------------------------------------- 入口


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lumi 仓库守卫")
    parser.add_argument("--phase", choices=["all", "secrets", "hygiene", "docs", "invariants"],
                        default="all")
    parser.add_argument("--staged", action="store_true", help="只扫索引里已 staged 的内容")
    parser.add_argument("--root", default=None, help="仓库根目录（默认自动探测）")
    args = parser.parse_args(argv)

    start = Path(args.root).resolve() if args.root else Path.cwd()
    root = Path(args.root).resolve() if args.root else repo_root(start)
    in_git = root is not None
    if root is None:
        root = start
        if args.staged:
            print("✗ --staged 需要在 git 仓库里运行", file=sys.stderr)
            return 2

    if args.staged:
        files = staged_files(root)
        if not files:
            print("没有 staged 的改动，跳过。")
            return 0
        where = f"{len(files)} 个 staged 文件"
    elif in_git:
        files = tracked_files(root)
        where = f"{len(files)} 个已跟踪文件"
        if not files:
            # 还没有首次提交时 git ls-files 是空的：扫 0 个文件报"通过"是假绿。
            files = walk_files(root)
            where = f"{len(files)} 个工作区文件（仓库里还没有已跟踪文件）"
    else:
        files = walk_files(root)
        where = f"{len(files)} 个文件（非 git 目录）"

    if not files:
        print("✗ 一个文件都没扫到，拒绝报通过", file=sys.stderr)
        return 2

    phases = (["secrets", "hygiene", "docs", "invariants"] if args.phase == "all"
              else [args.phase])
    if args.staged:
        # invariants 是全仓库性质的设计约束，留给 CI；
        # docs 只在这次真的碰了 docs/ 时才跑——代价是几毫秒，换来的是
        # "改了规格忘了重新 deliver"在提交那一刻就被拦住，而不是等 CI 报红。
        if "invariants" in phases:
            phases.remove("invariants")
        # 文档阶段覆盖的东西不止 docs/ 目录，还包括 SPEC/DOC 文件本身的漂移，
        # 所以它们被 staged 时也要跑（否则"改了代码忘了同步模块清单"会漏过去）。
        touches_docs = any(f.startswith("docs/") or f in DOC_FILES for f in files)
        if "docs" in phases and not touches_docs:
            phases.remove("docs")

    print(f"Lumi repo guard · 仓库 {root}")
    print(f"扫描范围：{where}" + ("（索引内容）" if args.staged else ""))

    ok = True
    hints = {
        "secrets": "请撤销这笔改动、轮换泄露的密钥，并改用 Keychain / 环境变量；"
                   "确属示例的占位串请写成 <YOUR_KEY> 之类。",
        "hygiene": "这些文件应由 .gitignore 排除（构建产物可用 ./build.sh 重新生成）。",
        "docs": "STRUCTURE.md 与真实代码不一致，请同步更新文档（或修代码）。",
        "invariants": "代码里注释写明的契约被改动了——按提示修复，或有意更新规则与文档。",
    }
    if "secrets" in phases:
        allowed: list[str] = []
        ok &= report("phase: secrets — 密钥 / 凭据 / 个人信息",
                     scan_secrets(root, files, args.staged, allowed), hints["secrets"])
        if allowed:
            print(f"  · 已按文件内 `{ALLOW_FILE_MARKER}` 标记跳过内容扫描：{', '.join(allowed)}")
    if "hygiene" in phases:
        ok &= report("phase: hygiene — 构建产物 / 大文件 / 二进制",
                     scan_hygiene(root, files), hints["hygiene"])
    if "docs" in phases:
        ok &= report("phase: docs — 文档漂移 / 死链 / 图规格与交付回执",
                     scan_docs(root), hints["docs"])
    if "invariants" in phases:
        ok &= report("phase: invariants — 注释里写明的契约（端口 / 出口 / 签名 / 依赖）",
                     scan_invariants(root), hints["invariants"])

    print("\n" + ("✓ 全部通过" if ok else "✗ 未通过，详见上面各组"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ScanAbort as abort:
        print(f"✗ 环境问题：{abort}", file=sys.stderr)
        sys.exit(2)
