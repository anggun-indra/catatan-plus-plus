#!/usr/bin/env python3
"""Download the Solar outline icons used by the toolbar.

Source: https://solar-icons.dev/icons?style=outline
Served via the Iconify API, which returns the original SVG for each icon.

Writes macport/icons/<command>.svg — one file per Notepad++ toolbar command.
Icons are fetched one at a time: the API returns 403 for long batched URLs.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
OUT = os.path.join(PORT, "icons")

# Notepad++ toolbar command -> Solar outline icon name
ICONS = [
    ("file_new",              "document-add"),
    ("file_open",             "folder-open"),
    ("file_save",             "diskette"),
    ("file_save_all",         "documents"),
    ("file_close",            "close-square"),
    ("file_close_all",        "close-circle"),
    ("file_print",            "printer"),
    ("edit_cut",              "scissors"),
    ("edit_copy",             "copy"),
    ("edit_paste",            "clipboard"),
    ("edit_undo",             "undo-left"),
    ("edit_redo",             "undo-right"),
    ("search_find",           "magnifier"),
    ("search_replace",        "square-transfer-horizontal"),
    ("view_zoom_in",          "magnifier-zoom-in"),
    ("view_zoom_out",         "magnifier-zoom-out"),
    ("view_sync_v",           "sort-vertical"),
    ("view_sync_h",           "sort-horizontal"),
    ("view_wrap",             "paragraph-spacing"),
    ("view_all_chars",        "text-square"),
    ("view_indent_guide",     "align-horizontal-spacing"),
    ("lang_def",              "code-square"),
    ("view_doc_map",          "map"),
    ("view_doc_list",         "documents-minimalistic"),
    ("view_func_list",        "checklist"),
    ("view_file_browser",     "folder"),
    ("view_monitoring",       "eye"),
    ("macro_record",          "record-circle"),
    ("macro_stop",            "stop-circle"),
    ("macro_play",            "play-circle"),
    ("macro_multi",           "playlist"),
    ("macro_save",            "bookmark"),
]

API = "https://api.iconify.design/solar.json?icons="


def fetch(icon_name, attempts=4):
    key = icon_name + "-outline"
    last = None
    for attempt in range(attempts):
        proc = subprocess.run(["curl", "-sS", "--retry", "2", "-m", "20", API + key],
                              capture_output=True, text=True)
        if proc.returncode == 0:
            try:
                data = json.loads(proc.stdout)
            except json.JSONDecodeError:
                last = "invalid JSON"
            else:
                if key in data.get("icons", {}):
                    return data["icons"][key]["body"]
                last = "icon not found: " + key
        else:
            last = proc.stderr.strip()
        time.sleep(1 + attempt)
    raise RuntimeError(last or "unknown error")


def main():
    os.makedirs(OUT, exist_ok=True)
    failures = []
    for command, icon in ICONS:
        try:
            body = fetch(icon)
        except Exception as exc:      # noqa: BLE001 - report and continue
            failures.append("%s: %s" % (command, exc))
            continue
        svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
               'viewBox="0 0 24 24">%s</svg>' % body)
        with open(os.path.join(OUT, command + ".svg"), "w", encoding="utf-8") as f:
            f.write(svg)

    written = len([f for f in os.listdir(OUT) if f.endswith(".svg")])
    print("icons written: %d/%d" % (written, len(ICONS)))
    for failure in failures:
        print("  FAILED", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
