#!/usr/bin/env python3
"""Collect SKILL.md files from configured agent directories and build the board.

    python3 scan_skills.py            scan and build
    python3 scan_skills.py --open     build, then open the board
    python3 scan_skills.py --config other.json
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"
EXAMPLE_PATH = ROOT / "config.example.json"
TEMPLATE_DIR = ROOT / "templates"


# --- config ---

def default_config():
    return {
        "title": "Skill Board",
        "sources": [
            {"key": "codex", "label": "Codex CLI", "short": "Codex",
             "path": "~/.codex/skills", "depth": 2, "color": "#2E8B62"},
            {"key": "claude", "label": "Claude Code", "short": "Claude",
             "path": "~/.claude/skills", "depth": 2, "color": "#C15F3C"},
            {"key": "workbuddy", "label": "WorkBuddy", "short": "WorkBuddy",
             "path": "~/.workbuddy/skills", "depth": 2, "color": "#2563EB"},
        ],
        "aliases": [],
        "outputs": {
            "json": "dist/skills.json",
            "board": "dist/board.html",
            "popover": "dist/popover.html",
        },
    }


def load_config(explicit=None):
    path = Path(explicit) if explicit else CONFIG_PATH
    if not path.exists():
        src = EXAMPLE_PATH if EXAMPLE_PATH.exists() else None
        if src and path == CONFIG_PATH:
            shutil.copyfile(src, CONFIG_PATH)
            print(f"created {CONFIG_PATH.name} from {src.name}", file=sys.stderr)
        else:
            cfg = default_config()
            path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
            print(f"created {path.name} with defaults", file=sys.stderr)
    cfg = json.loads(path.read_text(encoding="utf-8"))
    cfg.setdefault("title", "Skill Board")
    cfg.setdefault("sources", [])
    cfg.setdefault("aliases", [])
    cfg.setdefault("outputs", {})
    return cfg


def expand(p):
    return Path(os.path.expanduser(str(p)))


# --- parsing ---

def parse_frontmatter(md_path):
    """Minimal YAML frontmatter reader - flat keys plus indented continuation."""
    try:
        text = md_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    data = {}
    key = None
    for raw in text[3:end].splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_\-]+):\s*(.*)$", raw)
        if m and not raw.startswith(" "):
            key, val = m.group(1), m.group(2).strip()
            data[key] = val
        elif key and raw.startswith(" "):
            data[key] = (data.get(key, "") + " " + raw.strip()).strip()
    for k, v in list(data.items()):
        if isinstance(v, str) and len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            data[k] = v[1:-1]
    return data


def clean_desc(value, limit=240):
    if not value:
        return ""
    text = re.sub(r"\s+", " ", value).strip()
    return text[:limit] + ("…" if len(text) > limit else "")


def walk_skills(root, depth):
    """Yield directories containing SKILL.md, without descending into them."""
    if not root.exists():
        return
    base = len(root.parts)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        current = Path(dirpath)
        if len(current.parts) - base > depth:
            dirnames[:] = []
            continue
        # skip dot dirs, keep .system (codex ships builtins there)
        dirnames[:] = [d for d in dirnames
                       if (not d.startswith(".") or d == ".system") and d != "node_modules"]
        if "SKILL.md" in filenames:
            yield current
            dirnames[:] = []


def scan_source(source):
    key = source["key"]
    root = expand(source["path"])
    depth = int(source.get("depth", 2))
    slug_from = source.get("slug_from", "dir")
    dedup_by = source.get("dedup", "slug")
    cat_mode = source.get("category", "first")

    out, seen = [], {}
    for directory in walk_skills(root, depth):
        try:
            rel = str(directory.relative_to(root))
        except ValueError:
            rel = str(directory)
        if rel == ".":
            rel = ""
        parts = [p for p in rel.split(os.sep) if p]

        slug = directory.name
        category = ""
        if cat_mode == "first" and len(parts) >= 2:
            category = parts[0].lstrip(".")
        if slug_from == "after_skills":
            # repo/plugin/version/skills/<slug>, falling back to the plugin name
            if "skills" in parts:
                idx = parts.index("skills")
                slug = parts[idx + 1] if idx + 1 < len(parts) else (parts[1] if len(parts) > 1 else directory.name)
            elif len(parts) >= 2:
                slug = parts[1]

        fm = parse_frontmatter(directory / "SKILL.md")
        try:
            mtime = (directory / "SKILL.md").stat().st_mtime
        except OSError:
            mtime = 0

        # repo/plugin/version/skills/slug -> the plugin name is the second segment
        plugin = parts[1] if len(parts) >= 3 else ""

        entry = {
            "agent": key,
            "slug": slug,
            "name": fm.get("name") or slug,
            "display": fm.get("display_name") or fm.get("display_name_zh") or "",
            "desc": clean_desc(fm.get("description_zh") or fm.get("description")
                               or fm.get("description_en") or ""),
            "desc_en": clean_desc(fm.get("description_en") or fm.get("description") or ""),
            "category": category,
            "plugin": plugin,
            "version": fm.get("version", ""),
            "path": str(directory),
            "rel": rel,
            "mtime": mtime,
        }

        dkey = (entry["plugin"], slug) if dedup_by == "parent+slug" else slug
        if dkey in seen:
            if mtime > seen[dkey]["mtime"]:
                out[out.index(seen[dkey])] = entry
                seen[dkey] = entry
        else:
            seen[dkey] = entry
            out.append(entry)
    return out


# --- build ---

def render(template, data, target):
    html = template.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(html, encoding="utf-8")
    return target


def main():
    ap = argparse.ArgumentParser(description="Scan agent skills and build the dashboard.")
    ap.add_argument("--config", help="path to config.json")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--open", dest="do_open", action="store_true", help="open the board when done")
    args = ap.parse_args()

    cfg = load_config(args.config)
    agents, skills = [], []

    for src in cfg["sources"]:
        found = scan_source(src)
        found.sort(key=lambda s: (s["category"], s["slug"]))
        skills.extend(found)
        root = expand(src["path"])
        agents.append({
            "key": src["key"],
            "label": src.get("label", src["key"]),
            "short": src.get("short") or src.get("label", src["key"]),
            "color": src.get("color", "#2563EB"),
            "root": str(root),
            "exists": root.exists(),
            "count": len(found),
        })

    aliases = []
    for al in cfg["aliases"]:
        link = expand(al["link"])
        if link.is_symlink():
            aliases.append({
                "agent": al.get("label", str(link)),
                "link": str(link),
                "target": os.path.realpath(link),
            })

    now = datetime.now()
    data = {
        "title": cfg["title"],
        "generated_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        "generated_ts": int(now.timestamp()),
        "total": len(skills),
        "agents": agents,
        "shared": aliases,
        "skills": skills,
    }

    outputs = cfg.get("outputs", {})
    board_tpl = (TEMPLATE_DIR / "board.html").read_text(encoding="utf-8")
    pop_tpl = (TEMPLATE_DIR / "popover.html").read_text(encoding="utf-8")

    written = []
    json_path = expand(outputs.get("json", "dist/skills.json"))
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    written.append(json_path)

    board_path = expand(outputs.get("board", "dist/board.html"))
    written.append(render(board_tpl, data, board_path))

    pop_path = expand(outputs.get("popover", "dist/popover.html"))
    written.append(render(pop_tpl, data, pop_path))

    if not args.quiet:
        print(f"{len(skills)} skills from {len(agents)} sources")
        for a in agents:
            flag = "" if a["exists"] else "  (missing)"
            print(f"  {a['label']:<24} {a['count']:>4}  {a['root']}{flag}")
        for w in written:
            print(f"  -> {w}")

    if args.do_open:
        subprocess.run(["open", str(board_path)], check=False)


if __name__ == "__main__":
    main()
