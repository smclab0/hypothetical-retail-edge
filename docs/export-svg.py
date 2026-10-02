#!/usr/bin/env python3
"""Export the topology drawing in retail-shed.html as a standalone SVG.

GitHub's README shows images, not HTML pages, so README.md embeds
docs/retail-shed.svg. The drawing in the HTML takes its colours and fonts from
the page's CSS; this copies those tokens into the SVG's own <style> (light,
plus a prefers-color-scheme dark variant) and gives it a background.

Run after editing the diagram:  python3 docs/export-svg.py
"""
import re
from pathlib import Path

DOCS = Path(__file__).resolve().parent
html = (DOCS / "retail-shed.html").read_text()


def tokens(block):
    return dict(re.findall(r"(--[\w-]+):\s*([^;]+);", block))


light = tokens(re.search(r":root \{(.*?)\n\}", html, re.S).group(1))
dark = tokens(re.search(r':root\[data-theme="dark"\] \{(.*?)\}', html, re.S).group(1))
colour_names = [k for k in light if not k in ("--display", "--body", "--mono")]


def decl(t):
    return " ".join(f"{k}: {t[k]};" for k in colour_names if k in t)


svg = re.search(r"<svg viewBox=.*?</svg>", html, re.S).group(0)
width, height = re.search(r'viewBox="0 0 (\d+) (\d+)"', svg).groups()

style = f"""<style>
svg {{ {decl(light)} color: var(--ink); }}
@media (prefers-color-scheme: dark) {{ svg {{ {decl(dark)} }} }}
text {{ font-family: "Public Sans", "Segoe UI", system-ui, sans-serif; fill: currentColor; }}
.mono {{ font-family: "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace; }}
.disp {{ font-family: "Barlow Semi Condensed", "Arial Narrow", sans-serif; font-weight: 600; }}
.muted {{ fill: var(--muted); }}
.acc {{ fill: var(--accent); }}
.wan {{ fill: var(--wan); }}
</style>
<rect width="{width}" height="{height}" fill="var(--panel)"/>"""

svg = svg.replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ', 1)
svg = svg.replace("<defs>", style + "\n        <defs>", 1)
(DOCS / "retail-shed.svg").write_text(svg + "\n")
print(f"wrote {DOCS / 'retail-shed.svg'} ({width}x{height})")
