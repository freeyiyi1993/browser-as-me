# browser-as-me · playwright recipes

> 给 cc 用的复制即用代码片段。所有片段都假设 CDP Chrome 已经在 9222（如果不在，先跑 `scripts/ensure_chrome.sh`）。

shebang 用任意装了 `playwright` 的 python（建议 venv / pipx 隔离）：
```
#!/usr/bin/env python3
```

或在终端跑：
```bash
python3 <<'PY'
... 代码 ...
PY
```

> 前置：`pip install playwright && python -m playwright install chromium`

---

## 1. 连接 + 拿 cookie

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    # 所有 cookie
    for c in ctx.cookies():
        print(c["domain"], c["name"])
```

## 2. 在已登录站取页面内容

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    try:
        page.goto("https://example.com/protected", wait_until="domcontentloaded")
        # 等关键元素出现再读，避免 SPA 还没渲染
        page.wait_for_selector(".content", timeout=10000)
        text = page.inner_text(".content")
        print(text)
    finally:
        page.close()
```

## 3. 拦截 XHR / API 调用拿原始 JSON

适用于"网页好看但我想要后端 API 数据"的场景：

```python
captured = []

def on_response(resp):
    if "api/v1/something" in resp.url and resp.status == 200:
        try:
            captured.append(resp.json())
        except Exception:
            pass

with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    page = ctx.new_page()
    page.on("response", on_response)
    try:
        page.goto("https://example.com/page-that-triggers-api")
        page.wait_for_load_state("networkidle")
    finally:
        page.close()

print(captured)
```

## 4. 操作已存在的 tab（不开新 tab）

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    ctx = browser.contexts[0]
    # 找已经打开的 feishu doc tab
    target = next((p for p in ctx.pages if "feishu.cn" in p.url), None)
    if not target:
        raise SystemExit("no feishu tab open — open one in CDP Chrome first")
    title = target.title()
    print(title)
    # 不要 close — 这是用户已经打开的 tab
```

## 5. 截图（高频调试）

```python
with sync_playwright() as pw:
    browser = pw.chromium.connect_over_cdp("http://localhost:9222")
    page = browser.contexts[0].new_page()
    try:
        page.goto("https://example.com/protected")
        page.screenshot(path="/tmp/shot.png", full_page=True)
    finally:
        page.close()
```

## 6. 处理需要 SSO 跳转的页面

很多企业内网站点会跳第三方 SSO（如 `corp-sso.example.com`）。已登录就秒回，没登录就停在 SSO 页：

```python
SSO_HOST = "corp-sso.example.com"  # 改成你的 SSO host

page.goto(target_url, wait_until="domcontentloaded", timeout=30000)
# 等待跳转完成（URL 变成 target 域名）或 SSO 失败
page.wait_for_url(lambda u: SSO_HOST not in u, timeout=15000)
if "login" in page.url.lower():
    raise SystemExit("登录态过期，请在 CDP Chrome 重新登一下")
```

## 7. 长任务的 timeout 兜底

```python
# Playwright 默认 30s navigation timeout。复杂 SPA 可能不够。
page.set_default_navigation_timeout(60000)
page.set_default_timeout(60000)
```

## 8. 不能做 / 容易踩坑

- ❌ `browser.close()` — 会杀掉 LaunchAgent 那个 Chrome
- ❌ `ctx.close()` — 复用主人的 context，关了下次没了
- ❌ `pw.chromium.launch(...)` — 那是启动新 Chrome，不是连现有的
- ❌ `page.bring_to_front()` — 抢主人 Mac 当前 Space 焦点。99% 操作不需要前台（DOM-level fill/click/screenshot/evaluate/set_input_files/goto 都行）。需要键盘事件时用元素级 `locator.press("Escape")` 而不是窗口级 `bring_to_front`。详见 SKILL.md「减少抢焦点 / Space 隔离」
- ✅ 永远 `page.close()` 自己开的 tab
- ✅ 永远 `with sync_playwright()` 用 context manager，进程退出时 pw 自动清理

## 9. async 版本（如果任务很复杂需要并发）

```python
import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as pw:
        browser = await pw.chromium.connect_over_cdp("http://localhost:9222")
        ctx = browser.contexts[0]
        page = await ctx.new_page()
        try:
            await page.goto("https://example.com")
            ...
        finally:
            await page.close()

asyncio.run(main())
```
