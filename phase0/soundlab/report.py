"""Small helpers for the self-contained HTML reports."""

from __future__ import annotations

import html
import json
import platform
import subprocess
from datetime import datetime
from pathlib import Path

CSS = """
:root{--bg:#fbfaf8;--panel:#ffffff;--text:#1d1d1f;--muted:#6e6e73;--line:#e3e1dc;--accent:#b4232c;
--accent-soft:#f6e3e3;--good:#1f7a4d;--warn:#a15c00;--bad:#b4232c;--chip:#f1efeb}
@media (prefers-color-scheme:dark){:root{--bg:#161616;--panel:#1f1f1f;--text:#ececec;--muted:#9a9a9a;
--line:#333;--accent:#ff6b6b;--accent-soft:#3a2224;--good:#5bd08f;--warn:#f0b35a;--bad:#ff6b6b;--chip:#2a2a2a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",
"Helvetica Neue",Arial,sans-serif}
main{max-width:1200px;margin:0 auto;padding:24px 16px 80px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 10px}h3{font-size:15px;margin:0}
.sub{color:var(--muted);margin:0 0 20px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px;margin:16px 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px}
.card .n{font-size:22px;font-weight:600}.card .l{color:var(--muted);font-size:12px}
table{border-collapse:collapse;width:100%;background:var(--panel);border:1px solid var(--line);border-radius:10px;
overflow:hidden;font-size:13px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{background:var(--chip);font-weight:600;position:sticky;top:0;cursor:default}
th.sortable{cursor:pointer}th.sortable:hover{color:var(--accent)}
tr:last-child td{border-bottom:none}
.scroll{overflow-x:auto}
.bar{height:8px;background:var(--chip);border-radius:4px;overflow:hidden;min-width:80px}
.bar>i{display:block;height:100%;background:var(--accent)}
.chip{display:inline-block;background:var(--chip);border-radius:999px;padding:1px 8px;margin:1px 3px 1px 0;font-size:12px}
.chip.ai{background:var(--accent-soft)}
.muted{color:var(--muted)}.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
button.play{border:1px solid var(--line);background:var(--panel);color:var(--text);border-radius:6px;width:28px;
height:24px;cursor:pointer;font-size:11px}
button.play.on{background:var(--accent);color:#fff;border-color:var(--accent)}
.note{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:8px;
padding:10px 14px;margin:12px 0}
details{margin:6px 0}summary{cursor:pointer}
input[type=search],input[type=number],select{background:var(--panel);color:var(--text);border:1px solid var(--line);
border-radius:6px;padding:5px 8px;font:inherit}
"""

PLAYER_JS = """
const player = new Audio(); let playingBtn = null;
function playFile(btn, uri){
  if (location.protocol.startsWith('http')) uri = '/audio?u=' + encodeURIComponent(uri);  // served by serve_report.py
  if (playingBtn === btn && !player.paused){ player.pause(); btn.classList.remove('on'); btn.textContent='▶'; return; }
  if (playingBtn){ playingBtn.classList.remove('on'); playingBtn.textContent='▶'; }
  player.src = uri; player.currentTime = 0;
  player.play().catch(e => alert('This browser could not play the file. Try Chrome, or run serve_report.py.\\n' + e));
  btn.classList.add('on'); btn.textContent='■'; playingBtn = btn;
}
player.addEventListener('ended', () => { if (playingBtn){ playingBtn.classList.remove('on'); playingBtn.textContent='▶'; }});
function sortTable(th){
  const table = th.closest('table'); const idx = [...th.parentNode.children].indexOf(th);
  const rows = [...table.tBodies[0].rows]; const asc = th.dataset.dir !== 'asc'; th.dataset.dir = asc ? 'asc':'desc';
  rows.sort((a,b)=>{ const x=a.cells[idx].dataset.v ?? a.cells[idx].innerText; const y=b.cells[idx].dataset.v ?? b.cells[idx].innerText;
    const nx=parseFloat(x), ny=parseFloat(y); const c = (!isNaN(nx)&&!isNaN(ny)) ? nx-ny : String(x).localeCompare(String(y));
    return asc ? c : -c; });
  rows.forEach(r => table.tBodies[0].appendChild(r));
}
"""


def esc(s) -> str:
    return html.escape("" if s is None else str(s))


def page(title: str, subtitle: str, body: str, extra_js: str = "") -> str:
    when = datetime.now().strftime("%Y-%m-%d %H:%M")
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title>
<style>{CSS}</style></head><body><main>
<h1>{esc(title)}</h1><p class="sub">{esc(subtitle)} · generated {when}</p>
{body}
</main><script>{PLAYER_JS}{extra_js}</script></body></html>"""


def play_button(uri: str) -> str:
    return f'<button class="play" onclick="playFile(this, {esc(json.dumps(uri))})">▶</button>'


def bar(fraction: float) -> str:
    fraction = max(0.0, min(1.0, fraction))
    return f'<div class="bar" title="{fraction:.0%}"><i style="width:{fraction * 100:.1f}%"></i></div>'


def cards(items: list[tuple[str, str]]) -> str:
    return '<div class="cards">' + "".join(
        f'<div class="card"><div class="n">{esc(n)}</div><div class="l">{esc(l)}</div></div>' for n, l in items
    ) + "</div>"


def write_and_open(path: Path, content: str, open_it: bool = True) -> None:
    path.write_text(content, encoding="utf-8")
    if open_it and platform.system() == "Darwin":
        subprocess.run(["open", str(path)], check=False)


def fmt_duration(seconds) -> str:
    if seconds is None:
        return ""
    seconds = float(seconds)
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(int(round(seconds)), 60)
    if m < 60:
        return f"{m}:{s:02d}"
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}"


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")
