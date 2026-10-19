"""A portable, static gallery of a validated edit. No source paths, script or network assets."""
from __future__ import annotations

from html import escape
from io import BytesIO
from pathlib import Path, PurePosixPath
from urllib.parse import quote


PREVIEW_EDGE = 1600
PREVIEW_BYTES = 1_500_000


def _local_file(output: Path, relative: str) -> Path:
    """Only link files inside the finished folder, even if a caller passes an unsafe path."""
    from .workspace import PhotoError
    value = PurePosixPath(relative)
    if value.is_absolute() or ".." in value.parts or not value.parts:
        raise PhotoError("Gallery files must be relative to the finished folder.")
    path = output.joinpath(*value.parts)
    if path.is_symlink() or not path.is_file() or output.resolve() not in path.resolve().parents:
        raise PhotoError("Gallery file is missing or outside the finished folder.")
    return path


def _url(relative: str) -> str:
    # Percent-encode filenames before HTML escaping: #, ?, quotes and non-ASCII are filename data.
    return escape(quote(relative, safe="/"), quote=True)


def _preview(source: Path, destination: Path) -> dict:
    from PIL import Image
    from .workspace import PhotoError, display_image, _write_new
    with Image.open(source) as opened:
        opened.draft(opened.mode, (PREVIEW_EDGE, PREVIEW_EDGE))
        image, color_basis, srgb = display_image(opened)
        image.thumbnail((PREVIEW_EDGE, PREVIEW_EDGE))
    # A fresh RGB image carries pixels only. In particular, Pillow must not inherit EXIF or XMP.
    clean = Image.new("RGB", image.size)
    clean.paste(image)
    for quality in (88, 76, 64, 50, 35):
        stream = BytesIO()
        clean.save(stream, format="JPEG", quality=quality, icc_profile=srgb)
        data = stream.getvalue()
        if len(data) <= PREVIEW_BYTES:
            _write_new(destination, data)
            return {"width": clean.width, "height": clean.height, "bytes": len(data), "color_basis": color_basis}
    raise PhotoError("Could not fit a gallery preview within its 1.5 MB limit; incomplete export removed.")


STYLE = """
:root { color-scheme: light; --paper: #f5f3ed; --ink: #252822; --muted: #596052; --line: #cecfc4; --accent: #315946; }
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 2rem; }
body { margin: 0; color: var(--ink); background: var(--paper); font-family: 'Avenir Next', Avenir, 'Trebuchet MS', sans-serif; font-size: 16px; line-height: 1.55; }
a { color: inherit; text-underline-offset: .23em; text-decoration-thickness: 1px; }
a:hover { color: var(--accent); }
a:focus-visible { outline: 3px solid var(--accent); outline-offset: 5px; }
.skip { position: absolute; top: -5rem; left: 1rem; padding: .6rem 1rem; background: var(--paper); z-index: 2; }
.skip:focus { top: 1rem; }
.page { width: min(1440px, 100%); margin: 0 auto; padding: 0 clamp(20px, 5vw, 80px); }
.masthead { display: flex; justify-content: space-between; gap: 1rem; align-items: baseline; padding: 28px 0 20px; border-bottom: 1px solid var(--line); }
.brand, .eyebrow, .section-type, .position { font-size: .74rem; font-weight: 600; letter-spacing: .1em; text-transform: uppercase; }
.masthead p { margin: 0; }
.edition { font-size: .8rem; color: var(--muted); }
header { padding: clamp(40px, 7vw, 90px) 0 32px; max-width: 940px; }
.eyebrow { color: var(--muted); margin: 0 0 16px; }
h1, h2 { font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif; font-weight: 400; }
h1 { font-size: clamp(2.8rem, 6vw, 5.4rem); line-height: 1.03; letter-spacing: -.045em; margin: 0 0 28px; }
.brief { font-size: clamp(1.05rem, 1.7vw, 1.3rem); max-width: 760px; margin: 0 0 20px; overflow-wrap: anywhere; white-space: pre-wrap; }
.byline { font-size: .85rem; color: var(--muted); margin: 0; overflow-wrap: anywhere; }
nav { display: flex; flex-wrap: wrap; gap: 10px 30px; padding: 18px 0; border-block: 1px solid var(--line); font-size: .9rem; }
nav a { padding: 5px 0; }
nav span { color: var(--muted); margin-left: 8px; font-variant-numeric: tabular-nums; }
section { padding: clamp(48px, 7vw, 88px) 0 10px; }
.section-heading { display: grid; grid-template-columns: minmax(0, 1fr) minmax(200px, .7fr); gap: 24px 60px; align-items: end; margin-bottom: 32px; }
.section-type { color: var(--muted); margin: 0 0 10px; }
h2 { font-size: clamp(2rem, 3.5vw, 3.1rem); line-height: 1.1; letter-spacing: -.025em; margin: 0; overflow-wrap: anywhere; }
.why { margin: 0; max-width: 590px; overflow-wrap: anywhere; white-space: pre-wrap; }
.photos { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); align-items: start; gap: 44px 32px; list-style: none; padding: 0; margin: 0; }
.series .photos { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 36px 24px; }
.photos.one { grid-template-columns: minmax(0, 1fr); max-width: 960px; }
figure { margin: 0; }
.photo { display: flex; align-items: center; justify-content: center; background: #e9e8e0; aspect-ratio: 3 / 2; }
.photo img { display: block; width: 100%; height: 100%; object-fit: contain; }
.photo:hover { outline: 1px solid var(--muted); outline-offset: 4px; }
figcaption { padding-top: 14px; }
.caption-top { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
.position { color: var(--muted); }
.original { flex-shrink: 0; font-size: .78rem; }
.note { margin: 8px 0 0; font-size: .94rem; line-height: 1.5; overflow-wrap: anywhere; white-space: pre-wrap; }
footer { margin-top: clamp(55px, 8vw, 110px); padding: 24px 0 40px; border-top: 1px solid var(--line); display: flex; flex-wrap: wrap; justify-content: space-between; gap: 10px 28px; font-size: .8rem; color: var(--muted); }
footer p { margin: 0; max-width: 680px; }
footer a { display: inline-block; margin-right: 18px; padding: 4px 0; }
@media (max-width: 850px) { .series .photos { grid-template-columns: repeat(2, minmax(0, 1fr)); } .section-heading { gap: 24px; } }
@media (max-width: 600px) { .masthead { padding-top: 20px; } .edition { font-size: .72rem; } header { padding-top: 40px; } .section-heading { grid-template-columns: 1fr; gap: 16px; margin-bottom: 24px; } .photos, .series .photos { grid-template-columns: 1fr; gap: 32px; } nav { gap: 8px 24px; } .note { font-size: 1rem; } .original { padding: 4px 0; } }
@media (prefers-reduced-motion: reduce) { html { scroll-behavior: auto; } }
@media print { body { background: white; } .page { padding: 0; } .skip, nav, .original, footer a { display: none; } header { padding: 24px 0; } section { padding-top: 30px; } figure { break-inside: avoid; } }
"""


def write_gallery(output: Path, proposals: list[dict], *, intent: str, reviewer: str) -> dict:
    """Create one bounded preview per photo ID from the hash-verified copies, retaining exact edit order.

    The caller owns the new output directory and removes the complete export on any failure.
    """
    from .workspace import _write_new
    preview_dir = output / "gallery-previews"
    preview_dir.mkdir()
    previews = {}
    for proposal in proposals:
        for entry in proposal["files"]:
            source = _local_file(output, entry["file"])
            if entry["id"] not in previews:
                relative = f"gallery-previews/{len(previews) + 1:04d}.jpg"
                previews[entry["id"]] = {"id": entry["id"], "file": relative,
                                         **_preview(source, output / relative)}
    nav, sections = [], []
    for number, proposal in enumerate(proposals, 1):
        section_id = f"edit-{number}"
        name, title = escape(proposal["name"]), escape(proposal["title"] or proposal["name"])
        count = len(proposal["files"])
        nav.append(f'<a href="#{section_id}">{name}<span>{count:02d}</span></a>')
        figures = []
        for position, entry in enumerate(proposal["files"], 1):
            preview = previews[entry["id"]]
            label = escape(str(entry["label"]))
            alt = escape(f"{proposal['name']}, photograph {entry['label']}, position {position}", quote=True)
            note = escape(entry.get("note") or "No review note supplied.")
            figures.append(f'''<li><figure>
<a class="photo" href="{_url(preview['file'])}" aria-label="Enlarge {alt}"><img src="{_url(preview['file'])}" width="{preview['width']}" height="{preview['height']}" alt="{alt}" loading="lazy" decoding="async"></a>
<figcaption><div class="caption-top"><span class="position">{position:02d} / Photo {label}</span><a class="original" href="{_url(entry['file'])}" aria-label="Original photograph {label}" download>Original</a></div><p class="note">{note}</p></figcaption>
</figure></li>''')
        why = f'<p class="why">{escape(proposal["why"])}</p>' if proposal.get("why") else ""
        kind = "series" if proposal["kind"] == "series" else "edit"
        sections.append(f'''<section id="{section_id}" class="{kind}" aria-labelledby="heading-{number}">
<div class="section-heading"><div><p class="section-type">{name} / {count} {"photograph" if count == 1 else "photographs"}</p><h2 id="heading-{number}">{title}</h2></div>{why}</div>
<ol class="photos{' one' if count == 1 else ''}">{''.join(figures)}</ol></section>''')
    brief = f'<p class="brief">{escape(intent)}</p>' if intent else ""
    assumed = sum(p["color_basis"] == "assumed_srgb_no_profile" for p in previews.values())
    unverified = sum(p["color_basis"] == "unprofiled_mode_conversion_color_unverified" for p in previews.values())
    color_note = "Previews use sRGB."
    if assumed:
        color_note += f" sRGB is assumed for {assumed} unprofiled {('photograph' if assumed == 1 else 'photographs')}."
    if unverified:
        color_note += f" Color conversion is unverified for {unverified} {('photograph' if unverified == 1 else 'photographs')} from other unprofiled color modes."
    html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer"><title>Your shoot, finished | Dial In</title>
<style>{STYLE}</style></head><body><a class="skip" href="#edits">Skip to photographs</a>
<div class="page"><div class="masthead"><p class="brand">Dial In</p><p class="edition">A local photo edit · {len(previews)} unique photographs</p></div>
<header><p class="eyebrow">Your photographs, in order</p><h1>Your shoot,<br>finished.</h1>{brief}<p class="byline">Review supplied by {escape(reviewer)}. Select a photograph to enlarge it.</p></header>
<nav aria-label="Photo edits">{''.join(nav)}</nav><main id="edits">{''.join(sections)}</main>
<footer><p>Originals copied unchanged. {color_note} Keep this folder together when moving it.</p><div><a href="RESULTS.md">Text summary</a><a href="results.json">Edit record</a></div></footer>
</div></body></html>
'''
    _write_new(output / "index.html", html, "x", encoding="utf-8")
    return {"file": "index.html", "previews": list(previews.values()), "source_metadata_copied": False,
            "preview_max_edge": PREVIEW_EDGE, "preview_max_bytes": PREVIEW_BYTES}
