#!/usr/bin/env python3
"""Independent acceptance test for the pdfcore Rust core: loads the dylib through ctypes
(the same path the Swift bridge uses) and validates the C ABI + JSON contract on real PDFs.

Usage: python3 scripts/accept-core.py [--dylib PATH]
"""
import argparse
import ctypes
import json
import math
import os
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLES = os.path.join(ROOT, "samples")


def find_dylib(explicit=None):
    candidates = [
        explicit,
        os.environ.get("PDFCORE_DYLIB"),
        os.path.join(ROOT, "app", ".build", "core", "libpdfcore.dylib"),
        os.path.join(ROOT, "core", "target", "release", "libpdfcore.dylib"),
        os.path.join(ROOT, "core", "target", "debug", "libpdfcore.dylib"),
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


class Core:
    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        lib = self.lib
        lib.pc_open.restype = ctypes.c_void_p
        lib.pc_open.argtypes = [ctypes.c_char_p]
        lib.pc_close.argtypes = [ctypes.c_void_p]
        lib.pc_page_count.restype = ctypes.c_int32
        lib.pc_page_count.argtypes = [ctypes.c_void_p]
        lib.pc_page_width.restype = ctypes.c_double
        lib.pc_page_width.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        lib.pc_page_height.restype = ctypes.c_double
        lib.pc_page_height.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        lib.pc_render_page.restype = ctypes.c_int32
        lib.pc_render_page.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_double,
                                       ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32),
                                       ctypes.POINTER(ctypes.POINTER(ctypes.c_uint8))]
        lib.pc_page_layout_json.restype = ctypes.POINTER(ctypes.c_char)
        lib.pc_page_layout_json.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        lib.pc_document_structure_json.restype = ctypes.POINTER(ctypes.c_char)
        lib.pc_document_structure_json.argtypes = [ctypes.c_void_p]
        lib.pc_search_json.restype = ctypes.POINTER(ctypes.c_char)
        lib.pc_search_json.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.pc_free_json.argtypes = [ctypes.c_void_p]
        lib.pc_free_buffer.argtypes = [ctypes.c_void_p]
        lib.pc_last_error.restype = ctypes.c_char_p
        lib.pc_version.restype = ctypes.c_char_p

    def open(self, path):
        doc = self.lib.pc_open(path.encode())
        return doc

    def take_json(self, ptr):
        if not ptr:
            err = self.lib.pc_last_error()
            raise RuntimeError(f"NULL JSON: {err.decode() if err else 'no error'}")
        raw = ctypes.string_at(ptr)
        self.lib.pc_free_json(ctypes.cast(ptr, ctypes.c_void_p))
        return json.loads(raw.decode("utf-8"))

    def structure(self, doc):
        return self.take_json(self.lib.pc_document_structure_json(doc))

    def layout(self, doc, page):
        return self.take_json(self.lib.pc_page_layout_json(doc, page))

    def search(self, doc, query):
        return self.take_json(self.lib.pc_search_json(doc, query.encode()))

    def render(self, doc, page, scale):
        w = ctypes.c_int32()
        h = ctypes.c_int32()
        buf = ctypes.POINTER(ctypes.c_uint8)()
        rc = self.lib.pc_render_page(doc, page, scale, ctypes.byref(w), ctypes.byref(h), ctypes.byref(buf))
        if rc != 0:
            raise RuntimeError(f"render failed: {rc} {self.lib.pc_last_error()}")
        n = w.value * h.value * 4
        data = ctypes.string_at(buf, n)
        self.lib.pc_free_buffer(ctypes.cast(buf, ctypes.c_void_p))
        return w.value, h.value, data


failures = []
checks = 0


def check(name, cond, detail=""):
    global checks
    checks += 1
    status = "OK  " if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail else ""))
    if not cond:
        failures.append(name)


def valid_number(v):
    return isinstance(v, (int, float)) and math.isfinite(v)


def check_bbox(bbox, w, h, label, tol=2.0):
    ok = (isinstance(bbox, dict) and all(k in bbox for k in ("x", "y", "w", "h"))
          and all(valid_number(bbox[k]) for k in ("x", "y", "w", "h"))
          and bbox["w"] > -tol and bbox["h"] > -tol
          and -tol <= bbox["x"] <= w + tol and -tol <= bbox["y"] <= h + tol)
    if not ok:
        check(label, False, f"bbox={bbox} page={w:.0f}x{h:.0f}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    dylib = find_dylib(args.dylib)
    if not dylib:
        print("libpdfcore.dylib not found — build the core (scripts/build-core.sh)")
        return 2
    print(f"dylib: {dylib}")
    core = Core(dylib)
    print("version:", core.lib.pc_version().decode())

    # ---------- document 1: attention.pdf ----------
    attention = os.path.join(SAMPLES, "attention.pdf")
    if not os.path.isfile(attention):
        print("samples/attention.pdf is missing; run ./scripts/fetch-samples.sh (downloads the arXiv paper)")
        return 2
    doc = core.open(attention)
    check("open attention.pdf", bool(doc))
    if not doc:
        print("last error:", core.lib.pc_last_error())
        return 2

    n = core.lib.pc_page_count(doc)
    check("page_count == 15", n == 15, f"got {n}")
    w0 = core.lib.pc_page_width(doc, 0)
    h0 = core.lib.pc_page_height(doc, 0)
    check("page size ≈ letter", abs(w0 - 612) < 2 and abs(h0 - 792) < 2, f"{w0:.1f}x{h0:.1f}")

    t0 = time.time()
    st = core.structure(doc)
    dt = time.time() - t0
    check("structure < 1.5 s", dt < 1.5, f"{dt*1000:.0f} ms")
    check("structure schema", st.get("schema") == 1)
    check("pageCount in structure", st.get("pageCount") == 15)
    check("title found", bool(st.get("title")) and "attention" in st["title"].lower(), repr(st.get("title")))

    headings = st.get("headings") or []
    titles = [h.get("title", "") for h in headings]
    joined = " | ".join(titles)
    check("headings >= 10", len(headings) >= 10, f"{len(headings)}")
    for expected in ["Introduction", "Background", "Model Architecture", "Conclusion"]:
        check(f"heading contains {expected}", expected.lower() in joined.lower())
    for expected in ["Encoder and Decoder Stacks", "Attention"]:
        check(f"subsection contains {expected}", expected.lower() in joined.lower())

    levels = {h.get("title"): h.get("level") for h in headings}
    intro = next((lvl for t, lvl in levels.items() if "Introduction" in t), None)
    enc = next((lvl for t, lvl in levels.items() if "Encoder and Decoder Stacks" in t), None)
    check("Introduction level 1", intro == 1, f"level={intro}")
    check("3.1 Encoder... level 2", enc == 2, f"level={enc}")

    # a heading must not be a header/footer
    bad = [t for t in titles if any(s in t.lower() for s in ["provided proper attribution", "arxiv:", "page "])]
    check("no header/footer in headings", not bad, repr(bad[:3]))

    rows = []
    for h in headings:
        page = h.get("page", -1)
        check(f"heading page in range: {h.get('title', '')[:30]}", 0 <= page < 15, f"page={page}")
        pw = core.lib.pc_page_width(doc, page)
        ph = core.lib.pc_page_height(doc, page)
        if not check_bbox(h.get("bbox"), pw, ph, f"heading bbox: {h.get('title','')[:30]}"):
            break
        rows.append((h.get("level"), h.get("title"), page))

    # quality: no duplicates, no junk from figure captions, sane sizes
    check("no duplicate heading titles", len(set(titles)) == len(titles),
          str([t for t in titles if titles.count(t) > 1][:3]))
    junk = [t for t in titles if "Input-Input" in t or t.lower().startswith("layer")]
    check("no figure-label junk headings", not junk, repr(junk[:3]))
    letter_ratio = [t for t in titles if len(t) > 3 and sum(ch.isalpha() for ch in t) / len(t) < 0.55]
    check("heading titles mostly letters", not letter_ratio, repr(letter_ratio[:3]))
    check("heading count sane (10..30)", 10 <= len(titles) <= 30, f"{len(titles)}")

    intro_size = None
    for b in core.layout(doc, 1).get("blocks", []):
        if b.get("kind") == "heading" and "Introduction" in b.get("text", ""):
            intro_size = (b.get("font") or {}).get("size")
    check("attention: Introduction size ≈12", intro_size is not None and 10.5 <= intro_size <= 13.5, str(intro_size))

    # levels: 1..6
    ok_levels = all(isinstance(lvl, int) and 1 <= lvl <= 6 for lvl, _, _ in rows)
    check("heading levels 1..6", ok_levels)

    # ---------- layout of page 0 ----------
    lay = core.layout(doc, 0)
    check("layout schema", lay.get("schema") == 1)
    check("layout index", lay.get("index") == 0)
    check("layout size", abs(lay["width"] - w0) < 0.5 and abs(lay["height"] - h0) < 0.5)
    blocks = lay.get("blocks") or []
    check("blocks present", len(blocks) >= 5, f"{len(blocks)}")
    kinds = {}
    word_count = 0
    for b in blocks:
        kinds[b.get("kind")] = kinds.get(b.get("kind"), 0) + 1
        check_bbox(b.get("bbox"), lay["width"], lay["height"], f"block bbox {b.get('id')}")
        for line in b.get("lines") or []:
            check_bbox(line.get("bbox"), lay["width"], lay["height"], f"line bbox {b.get('id')}")
            for w in line.get("words") or []:
                word_count += 1
                if not check_bbox(w.get("bbox"), lay["width"], lay["height"], f"word bbox {b.get('id')}"):
                    break
    check("words extracted", word_count >= 200, f"{word_count}")
    check("has body kind", kinds.get("body", 0) > 0, str(kinds))
    check("bodyFontSize sane", 6 <= lay.get("bodyFontSize", 0) <= 14, str(lay.get("bodyFontSize")))

    # words → block text are consistent
    sample_block = next((b for b in blocks if b.get("kind") == "body"), blocks[0])
    check("block text nonempty", bool(sample_block.get("text")))
    if sample_block.get("font") is None:
        check("block font present", False)

    # ---------- render ----------
    w, h, data = core.render(doc, 0, 2.0)
    check("render size", w == round(w0 * 2) and h == round(h0 * 2), f"{w}x{h} vs {w0*2:.0f}x{h0*2:.0f}")
    check("render buffer size", len(data) == w * h * 4)
    if len(data) == w * h * 4:
        stride = w * 4
        def row(y):
            return data[y * stride:(y + 1) * stride]
        top = row(0)
        bottom = row(h - 1)
        white = lambda px: px[0] > 240 and px[1] > 240 and px[2] > 240
        check("top row mostly white (not flipped)", sum(1 for i in range(0, len(top), 40) if white(top[i:i+3])) > 0.8 * (len(top)//40))
        check("bottom row mostly white (not flipped)", sum(1 for i in range(0, len(bottom), 40) if white(bottom[i:i+3])) > 0.8 * (len(bottom)//40))
        alphas = range(3, len(data), 4)
        check("alpha == 255 everywhere", all(data[i] == 255 for i in list(alphas)[:20000]))
        nonwhite = 0
        total = 0
        for y in range(0, h, 7):
            base = y * stride
            for x in range(0, w, 7):
                p = base + x * 4
                total += 1
                if not (data[p] > 230 and data[p+1] > 230 and data[p+2] > 230):
                    nonwhite += 1
        frac = nonwhite / max(1, total)
        check("page has ink", 0.005 < frac < 0.6, f"non-white {frac:.1%}")

    # the page background must be light (otherwise a broken fill or an inverted raster)
    def corner_brightness(w, h, data):
        stride = w * 4
        pts = [(4, 4), (w - 5, 4), (4, h - 5), (w - 5, h - 5), (w // 2, 6)]
        vals = []
        for x, y in pts:
            p = y * stride + x * 4
            vals.append((data[p] + data[p + 1] + data[p + 2]) / 3)
        return min(vals)

    check("attention: page background is light", corner_brightness(w, h, data) > 235,
          f"min corner luma={corner_brightness(w, h, data):.0f}")

    # ---------- search ----------
    hits = core.search(doc, "attention")
    check("search returns hits", len(hits.get("hits", [])) > 0, f"{len(hits.get('hits', []))} hits")
    check("search hit pages valid", all(0 <= h["page"] < 15 for h in hits.get("hits", [])))
    check("search bbox valid", all(isinstance(r, dict) and r.get("w", 0) > 0 for h in hits.get("hits", []) for r in h.get("rects", [])))

    core.lib.pc_close(doc)

    # ---------- document 2: Russian ----------
    ru = os.path.join(SAMPLES, "sample-ru.pdf")
    doc = core.open(ru)
    check("open sample-ru.pdf", bool(doc))
    if doc:
        st = core.structure(doc)
        check("ru pageCount == 3", st.get("pageCount") == 3)
        ru_titles = [h.get("title", "") for h in st.get("headings", [])]
        ru_joined = " | ".join(ru_titles)
        check("ru: title Структура PDF-документа", "Структура PDF-документа" in ru_joined, ru_joined[:200])
        check("ru: Введение", "Введение" in ru_joined)
        check("ru: Сильное нажатие", "Сильное нажатие" in ru_joined)
        check("ru: no footer in headings", "демонстрационный документ" not in ru_joined and "из 3" not in ru_joined)
        sizes = {}
        for b in core.layout(doc, 0).get("blocks", []):
            if b.get("kind") == "heading":
                sizes[b.get("text", "")] = (b.get("font") or {}).get("size")
        title_size = next((sz for t, sz in sizes.items() if "Структура PDF-документа" in t), None)
        check("ru: title size ≈28 (effective font size)", title_size is not None and 24 <= title_size <= 31, str(title_size))
        body_size = core.layout(doc, 0).get("bodyFontSize")
        check("ru: bodyFontSize ≈11", body_size is not None and 9.5 <= body_size <= 12.5, str(body_size))
        check("ru: headings >= 8", len(st.get("headings", [])) >= 8, str(len(st.get("headings", []))))
        # render: the heading is at the top edge, not the bottom (flip check)
        w, h, data = core.render(doc, 0, 2.0)
        stride = w * 4
        # orientation: the title text must fall inside its layout bbox
        lay0 = core.layout(doc, 0)
        title_blocks = [b for b in lay0.get("blocks", []) if b.get("kind") == "heading"]
        title_block = max(title_blocks, key=lambda b: (b.get("font") or {}).get("size", 0))
        bx = title_block["bbox"]
        sx = 2.0
        x0 = max(0, int(bx["x"] * sx)); x1 = min(w, int((bx["x"] + bx["w"]) * sx))
        y0 = max(0, int(bx["y"] * sx)); y1 = min(h, int((bx["y"] + bx["h"]) * sx))
        dark = 0
        total = 0
        for y in range(y0, y1, 2):
            base = y * stride
            for x in range(x0, x1, 2):
                pxy = base + x * 4
                total += 1
                if data[pxy] < 120 and data[pxy + 1] < 120 and data[pxy + 2] < 120:
                    dark += 1
        ratio = dark / max(1, total)
        check("ru: render orientation (title ink inside bbox)", ratio > 0.05,
              f"ink in title bbox={ratio:.2f} bbox={tuple(round(v) for v in (bx['x'], bx['y'], bx['w'], bx['h']))}")
        light = corner_brightness(w, h, data)
        check("ru: page background is light", light > 235, f"min corner luma={light:.0f}")
        levels = {h["title"]: h["level"] for h in st.get("headings", [])}
        vved = next((l for t, l in levels.items() if "Введение" in t), None)
        tip = next((l for t, l in levels.items() if "Типографические признаки" in t), None)
        check("ru: Введение level 1", vved == 1, str(vved))
        check("ru: 1.1 level 2", tip == 2, str(tip))
        core.lib.pc_close(doc)

    # ---------- document 3: no text ----------
    scan = os.path.join(SAMPLES, "no-text.pdf")
    doc = core.open(scan)
    check("open no-text.pdf", bool(doc))
    if doc:
        st = core.structure(doc)
        check("no-text: zero headings", len(st.get("headings", [])) == 0, str(len(st.get("headings", []))))
        lay = core.layout(doc, 0)
        words = sum(len(l.get("words") or []) for b in lay.get("blocks", []) for l in b.get("lines", []))
        check("no-text: no words", words == 0, str(words))
        w, h, data = core.render(doc, 0, 1.0)
        check("no-text: render ok", w > 100 and h > 100 and len(data) == w * h * 4)
        core.lib.pc_close(doc)

    # ---------- errors ----------
    bad = core.open(os.path.join(SAMPLES, "does-not-exist.pdf"))
    check("open nonexistent returns NULL", not bad)
    err = core.lib.pc_last_error()
    check("last_error nonempty", bool(err and err.decode()))
    garbage = os.path.join(ROOT, "app", "Package.swift")
    bad = core.open(garbage)
    check("open non-PDF returns NULL", not bad)

    print()
    print(f"TOTAL: {checks - len(failures)}/{checks} checks passed")
    if failures:
        print("FAILURES:")
        for f in failures:
            print(" -", f)
        return 1
    print("CORE ACCEPTANCE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
