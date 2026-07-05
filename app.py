import json
import mimetypes
import os
import re
import socket
import subprocess
import threading
import time
from collections import deque
from datetime import datetime
from itertools import groupby
from pathlib import Path

from flask import Flask, Response, redirect, render_template_string, request, url_for
import pikepdf
from pikepdf import PdfImage
from PIL import Image


app = Flask(__name__)
OUTPUT_DIR = Path(os.environ.get("SCAN_OUTPUT_DIR", "/scans"))
SETTINGS_PATH = Path(os.environ.get("SCAN_SETTINGS_PATH", str(OUTPUT_DIR / ".scanner-settings.json")))
PREVIEW_DIR_NAME = ".previews"
job_lock = threading.Lock()
ocr_lock = threading.Lock()
ocr_state_lock = threading.Lock()
settings_lock = threading.Lock()
ocr_queue = deque()
last_job = {
    "started": None,
    "finished": None,
    "status": "idle",
    "output": "",
    "error": "",
}
last_ocr_job = {
    "started": None,
    "finished": None,
    "status": "idle",
    "input": "",
    "output": "",
    "error": "",
    "queued": 0,
}
last_scan_completed_at = 0.0
last_button_started_at = 0.0
button_rearm_requested = threading.Event()


def iso_timestamp():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def log_event(event, **fields):
    parts = [iso_timestamp(), event]
    for key, value in fields.items():
        if value is None:
            continue
        text = str(value).replace("\n", "\\n")
        parts.append(f"{key}={text}")
    print(" ".join(parts), flush=True)


SCAN_SETTING_KEYS = [
    "SCAN_LANGUAGE",
    "SCAN_RESOLUTION",
    "SCAN_MODE",
    "SCAN_SOURCE",
    "SCAN_SIMPLEX",
    "SCAN_FORMAT",
    "SCAN_PAGE_MODE",
    "SCAN_OCR_ENABLED",
    "SCAN_REMOVE_BLANK_PAGES",
    "SCAN_CROP_PAGES",
]
BOOL_SCAN_SETTING_KEYS = {
    "SCAN_SIMPLEX",
    "SCAN_OCR_ENABLED",
    "SCAN_REMOVE_BLANK_PAGES",
    "SCAN_CROP_PAGES",
}
TRUE_VALUES = {"1", "true", "yes", "on"}
SCAN_FORMATS = {"pdf", "png"}
SCAN_PAGE_MODES = {"multi", "single"}


def truthy(value):
    return str(value).strip().lower() in TRUE_VALUES


def bool_text(value):
    return "true" if truthy(value) else "false"


def env_default_settings():
    return {
        "SCAN_LANGUAGE": os.environ.get("SCAN_LANGUAGE", "deu+eng"),
        "SCAN_RESOLUTION": os.environ.get("SCAN_RESOLUTION", "300"),
        "SCAN_MODE": os.environ.get("SCAN_MODE", "Color"),
        "SCAN_SOURCE": os.environ.get("SCAN_SOURCE", "ADF Duplex"),
        "SCAN_SIMPLEX": bool_text(os.environ.get("SCAN_SIMPLEX", "false")),
        "SCAN_FORMAT": os.environ.get("SCAN_FORMAT", "pdf").lower(),
        "SCAN_PAGE_MODE": os.environ.get("SCAN_PAGE_MODE", "multi").lower(),
        "SCAN_OCR_ENABLED": bool_text(os.environ.get("SCAN_OCR_ENABLED", "true")),
        "SCAN_REMOVE_BLANK_PAGES": bool_text(os.environ.get("SCAN_REMOVE_BLANK_PAGES", "true")),
        "SCAN_CROP_PAGES": bool_text(os.environ.get("SCAN_CROP_PAGES", "true")),
    }


def normalized_mode_settings(settings):
    base = env_default_settings()
    merged = {}
    for key in SCAN_SETTING_KEYS:
        value = str((settings or {}).get(key, base[key])).strip()
        if key in BOOL_SCAN_SETTING_KEYS:
            value = bool_text(value)
        elif key == "SCAN_FORMAT":
            value = value.lower()
            if value in {"image", "images"}:
                value = "png"
            if value not in SCAN_FORMATS:
                value = base[key] if base[key] in SCAN_FORMATS else "pdf"
        elif key == "SCAN_PAGE_MODE":
            value = value.lower()
            if value not in SCAN_PAGE_MODES:
                value = base[key] if base[key] in SCAN_PAGE_MODES else "multi"
        elif not value:
            value = base[key]
        merged[key] = value
    return merged


def builtin_scan_modes():
    base = normalized_mode_settings(env_default_settings())

    def mode(mode_id, name, **overrides):
        return {
            "id": mode_id,
            "name": name,
            "settings": normalized_mode_settings({**base, **overrides}),
        }

    return [
        mode("duplex-pdf-ocr", "Duplex PDF + OCR"),
        mode(
            "simplex-pdf-ocr",
            "Simplex PDF + OCR",
            SCAN_SOURCE="ADF Simplex",
            SCAN_SIMPLEX="true",
            SCAN_FORMAT="pdf",
            SCAN_PAGE_MODE="multi",
            SCAN_OCR_ENABLED="true",
        ),
        mode(
            "photo-png",
            "Photo PNG",
            SCAN_SOURCE="ADF Simplex",
            SCAN_SIMPLEX="true",
            SCAN_RESOLUTION="600",
            SCAN_MODE="Color",
            SCAN_FORMAT="png",
            SCAN_PAGE_MODE="single",
            SCAN_OCR_ENABLED="false",
            SCAN_REMOVE_BLANK_PAGES="false",
            SCAN_CROP_PAGES="false",
        ),
        mode(
            "duplex-pdf-no-ocr",
            "Duplex PDF",
            SCAN_FORMAT="pdf",
            SCAN_PAGE_MODE="multi",
            SCAN_OCR_ENABLED="false",
        ),
        mode(
            "single-page-pdfs",
            "Single Page PDFs + OCR",
            SCAN_FORMAT="pdf",
            SCAN_PAGE_MODE="single",
            SCAN_OCR_ENABLED="true",
        ),
    ]


def normalize_scan_settings(data):
    builtins = builtin_scan_modes()
    modes = []
    seen = set()
    for fallback, mode in enumerate((data or {}).get("modes") or builtins):
        mode_id = str(mode.get("id") or f"mode-{fallback + 1}").strip()
        if not mode_id or mode_id in seen:
            mode_id = unique_mode_id(str(mode.get("name") or "Mode"), modes)
        seen.add(mode_id)
        modes.append(
            {
                "id": mode_id,
                "name": str(mode.get("name") or "Scan mode").strip() or "Scan mode",
                "settings": normalized_mode_settings(mode.get("settings") or {}),
            }
        )

    if not modes:
        modes = builtins

    default_mode_id = str((data or {}).get("default_mode_id") or "").strip()
    if default_mode_id not in {mode["id"] for mode in modes}:
        default_mode_id = modes[0]["id"]

    return {"version": 1, "default_mode_id": default_mode_id, "modes": modes}


def load_scan_settings():
    with settings_lock:
        if not SETTINGS_PATH.exists():
            settings = normalize_scan_settings(None)
            write_scan_settings_unlocked(settings)
            return settings

        try:
            settings = normalize_scan_settings(json.loads(SETTINGS_PATH.read_text()))
        except Exception as exc:
            log_event("settings.load.failed", path=SETTINGS_PATH, error=exc)
            settings = normalize_scan_settings(None)
        return settings


def write_scan_settings_unlocked(settings):
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    temp_path = SETTINGS_PATH.with_suffix(f"{SETTINGS_PATH.suffix}.tmp")
    temp_path.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    temp_path.replace(SETTINGS_PATH)


def save_scan_settings(settings):
    normalized = normalize_scan_settings(settings)
    with settings_lock:
        write_scan_settings_unlocked(normalized)
    return normalized


def find_mode(settings, mode_id):
    return next((mode for mode in settings["modes"] if mode["id"] == mode_id), None)


def default_mode(settings):
    return find_mode(settings, settings["default_mode_id"]) or settings["modes"][0]


def slugify_mode_name(name):
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "scan-mode"


def unique_mode_id(name, modes, existing_id=None):
    base = slugify_mode_name(name)
    used = {mode["id"] for mode in modes if mode["id"] != existing_id}
    candidate = base
    index = 2
    while candidate in used:
        candidate = f"{base}-{index}"
        index += 1
    return candidate


def mode_from_form(form):
    settings = normalized_mode_settings(
        {
            "SCAN_LANGUAGE": form.get("SCAN_LANGUAGE", ""),
            "SCAN_RESOLUTION": form.get("SCAN_RESOLUTION", ""),
            "SCAN_MODE": form.get("SCAN_MODE", ""),
            "SCAN_SOURCE": form.get("SCAN_SOURCE", ""),
            "SCAN_SIMPLEX": form.get("SCAN_SIMPLEX", "false"),
            "SCAN_FORMAT": form.get("SCAN_FORMAT", "pdf"),
            "SCAN_PAGE_MODE": form.get("SCAN_PAGE_MODE", "multi"),
            "SCAN_OCR_ENABLED": "true" if form.get("SCAN_OCR_ENABLED") else "false",
            "SCAN_REMOVE_BLANK_PAGES": "true" if form.get("SCAN_REMOVE_BLANK_PAGES") else "false",
            "SCAN_CROP_PAGES": "true" if form.get("SCAN_CROP_PAGES") else "false",
        }
    )
    return settings


def mode_env(mode, trigger):
    settings = dict(mode["settings"])
    settings["SCAN_TRIGGER"] = trigger
    settings["SCAN_PROFILE_ID"] = mode["id"]
    settings["SCAN_PROFILE_NAME"] = mode["name"]
    return settings


def mode_summary(mode):
    settings = mode["settings"]
    sides = "Simplex" if truthy(settings["SCAN_SIMPLEX"]) else "Duplex"
    output = "PNG pages" if settings["SCAN_FORMAT"] == "png" else "PDF"
    pages = "single pages" if settings["SCAN_PAGE_MODE"] == "single" else "multipage"
    ocr = "OCR on" if truthy(settings["SCAN_OCR_ENABLED"]) else "OCR off"
    crop = "autocrop on" if truthy(settings["SCAN_CROP_PAGES"]) else "autocrop off"
    return f"{sides}, {output}, {pages}, {ocr}, {crop}, {settings['SCAN_RESOLUTION']} dpi {settings['SCAN_MODE']}"


PAGE = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>scannerserver</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { margin: 0; background: #f5f5f2; color: #202124; }
    main { max-width: 960px; margin: 0 auto; padding: 32px 20px; }
    h1 { font-size: 28px; margin: 0 0 24px; }
    h2 { font-size: 18px; margin: 0 0 12px; }
    section { background: white; border: 1px solid #dadce0; border-radius: 8px; padding: 18px; margin-bottom: 16px; }
    label { display: grid; gap: 6px; font-size: 14px; font-weight: 600; }
    input, select, button { font: inherit; }
    input, select { padding: 8px 10px; border: 1px solid #c7c9cc; border-radius: 6px; background: white; color: #202124; }
    button { padding: 9px 14px; border: 0; border-radius: 6px; background: #0b57d0; color: white; font-weight: 700; cursor: pointer; }
    button:disabled { background: #8a9199; cursor: wait; }
    form { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; align-items: end; }
    .stack-form { grid-template-columns: 1fr; align-items: stretch; }
    .settings-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; align-items: end; }
    .checkbox-grid { display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }
    .button-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .secondary-button { background: #5f6368; }
    .danger-button { background: #b3261e; }
    .mode-list { display: grid; gap: 8px; padding: 0; margin: 0 0 14px; list-style: none; }
    .mode-row { display: grid; gap: 4px; padding: 10px; border: 1px solid #e0e3e7; border-radius: 8px; }
    .mode-row-title { display: flex; gap: 8px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
    .mode-name { font-weight: 700; }
    .mode-summary { color: #5f6368; font-size: 13px; }
    .default-badge { display: inline-block; padding: 2px 8px; border-radius: 999px; background: #e6f4ea; color: #137333; font-size: 12px; font-weight: 700; }
    pre { margin: 0; overflow: auto; white-space: pre-wrap; font-size: 13px; }
    ul { padding-left: 20px; }
    li { margin-bottom: 8px; }
    a { color: #0b57d0; }
    .bulk-delete-form { display: block; }
    .bulk-actions { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 12px; }
    .checkbox-label { display: inline-flex; gap: 8px; align-items: center; font-weight: 700; }
    .file-check { width: 18px; height: 18px; flex: 0 0 auto; }
    .file-groups { display: grid; gap: 18px; }
    .file-day { display: grid; gap: 10px; }
    .file-day-title { margin: 0; font-size: 16px; }
    .file-list { display: grid; gap: 10px; padding: 0; margin: 0; list-style: none; }
    .file-row { display: grid; grid-template-columns: 112px 1fr; gap: 12px; align-items: center; padding: 10px; border: 1px solid #e0e3e7; border-radius: 8px; }
    .file-preview-link { display: block; width: 112px; height: 148px; border-radius: 6px; }
    .file-preview { width: 112px; height: 148px; object-fit: cover; border: 1px solid #dadce0; border-radius: 6px; background: #f1f3f4; }
    .file-details { display: grid; gap: 8px; min-width: 0; }
    .file-title { font-weight: 700; overflow-wrap: anywhere; }
    .file-links { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .file-variant { display: inline-flex; gap: 8px; align-items: center; flex-wrap: wrap; min-width: 0; }
    .file-name { overflow-wrap: anywhere; font-size: 13px; color: #5f6368; }
    .delete-button { background: #b3261e; padding: 5px 9px; font-size: 13px; }
    .bulk-delete-button { background: #b3261e; }
    .file-kind { font-size: 12px; font-weight: 700; color: #5f6368; }
    .status { display: inline-block; padding: 3px 8px; border-radius: 999px; background: #e8f0fe; color: #174ea6; font-size: 13px; font-weight: 700; }
    @media (max-width: 560px) {
      .file-row { grid-template-columns: 72px 1fr; }
      .file-preview-link, .file-preview { width: 72px; height: 96px; }
    }
    @media (prefers-color-scheme: dark) {
      body { background: #171717; color: #f1f3f4; }
      section { background: #202124; border-color: #3c4043; }
      input, select { background: #171717; color: #f1f3f4; border-color: #5f6368; }
      a { color: #8ab4f8; }
      .mode-row { border-color: #3c4043; }
      .mode-summary { color: #bdc1c6; }
      .default-badge { background: #1e3b27; color: #81c995; }
      .file-row { border-color: #3c4043; }
      .file-preview { border-color: #3c4043; background: #171717; }
    }
  </style>
</head>
<body>
  <main>
    <h1>scannerserver</h1>
    <section>
      <h2>Scan</h2>
      <form method="post" action="{{ url_for('scan') }}">
        <label>Scan mode
          <select name="mode_id">
            {% for mode in scan_settings.modes %}
            <option value="{{ mode.id }}" {% if mode.id == scan_settings.default_mode_id %}selected{% endif %}>{{ mode.name }}{% if mode.id == scan_settings.default_mode_id %} (button){% endif %}</option>
            {% endfor %}
          </select>
        </label>
        <div class="button-row">
          <button {% if last_job.status == "running" %}disabled{% endif %}>Start scan</button>
          <button class="secondary-button" formaction="{{ url_for('set_default_mode') }}">Use for button</button>
        </div>
      </form>
    </section>
    <section>
      <h2>Modes</h2>
      <ul class="mode-list">
        {% for mode in scan_settings.modes %}
        <li class="mode-row">
          <div class="mode-row-title">
            <span class="mode-name">{{ mode.name }}</span>
            {% if mode.id == scan_settings.default_mode_id %}<span class="default-badge">button</span>{% endif %}
          </div>
          <div class="mode-summary">{{ mode_summaries[mode.id] }}</div>
        </li>
        {% endfor %}
      </ul>
      <form method="get" action="{{ url_for('index') }}">
        <label>Edit mode
          <select name="edit_mode">
            {% for mode in scan_settings.modes %}
            <option value="{{ mode.id }}" {% if mode.id == edit_mode.id %}selected{% endif %}>{{ mode.name }}</option>
            {% endfor %}
            <option value="new" {% if not edit_mode.id %}selected{% endif %}>New mode</option>
          </select>
        </label>
        <button class="secondary-button">Load</button>
      </form>
      <form class="stack-form" method="post" action="{{ url_for('save_mode') }}">
        <input type="hidden" name="mode_id" value="{{ edit_mode.id }}">
        <div class="settings-grid">
          <label>Name
            <input name="name" value="{{ edit_mode.name }}">
          </label>
          <label>Sides
            <select name="SCAN_SIMPLEX">
              <option value="false" {% if edit_mode.settings.SCAN_SIMPLEX == "false" %}selected{% endif %}>Duplex</option>
              <option value="true" {% if edit_mode.settings.SCAN_SIMPLEX == "true" %}selected{% endif %}>Simplex</option>
            </select>
          </label>
          <label>Output
            <select name="SCAN_FORMAT">
              <option value="pdf" {% if edit_mode.settings.SCAN_FORMAT == "pdf" %}selected{% endif %}>PDF</option>
              <option value="png" {% if edit_mode.settings.SCAN_FORMAT == "png" %}selected{% endif %}>PNG pages</option>
            </select>
          </label>
          <label>Pages
            <select name="SCAN_PAGE_MODE">
              <option value="multi" {% if edit_mode.settings.SCAN_PAGE_MODE == "multi" %}selected{% endif %}>Multipage file</option>
              <option value="single" {% if edit_mode.settings.SCAN_PAGE_MODE == "single" %}selected{% endif %}>One file per page</option>
            </select>
          </label>
          <label>Resolution
            <select name="SCAN_RESOLUTION">
              {% for value in ["200", "300", "400", "600"] %}
              <option value="{{ value }}" {% if edit_mode.settings.SCAN_RESOLUTION == value %}selected{% endif %}>{{ value }} dpi</option>
              {% endfor %}
            </select>
          </label>
          <label>Color mode
            <select name="SCAN_MODE">
              {% for value in ["Color", "Gray", "Lineart"] %}
              <option value="{{ value }}" {% if edit_mode.settings.SCAN_MODE == value %}selected{% endif %}>{{ value }}</option>
              {% endfor %}
            </select>
          </label>
          <label>Source
            <input name="SCAN_SOURCE" value="{{ edit_mode.settings.SCAN_SOURCE }}">
          </label>
          <label>OCR language
            <input name="SCAN_LANGUAGE" value="{{ edit_mode.settings.SCAN_LANGUAGE }}">
          </label>
        </div>
        <div class="checkbox-grid">
          <label class="checkbox-label"><input class="file-check" type="checkbox" name="SCAN_OCR_ENABLED" {% if edit_mode.settings.SCAN_OCR_ENABLED == "true" %}checked{% endif %}> OCR</label>
          <label class="checkbox-label"><input class="file-check" type="checkbox" name="SCAN_CROP_PAGES" {% if edit_mode.settings.SCAN_CROP_PAGES == "true" %}checked{% endif %}> Autocrop</label>
          <label class="checkbox-label"><input class="file-check" type="checkbox" name="SCAN_REMOVE_BLANK_PAGES" {% if edit_mode.settings.SCAN_REMOVE_BLANK_PAGES == "true" %}checked{% endif %}> Remove blanks</label>
          <label class="checkbox-label"><input class="file-check" type="checkbox" name="set_default" {% if edit_mode.id == scan_settings.default_mode_id %}checked{% endif %}> Button default</label>
        </div>
        <div class="button-row">
          <button>Save mode</button>
          {% if edit_mode.id %}
          <button class="danger-button" formaction="{{ url_for('delete_mode') }}" onclick='return confirm({{ ("Delete mode " ~ edit_mode.name ~ "?")|tojson }})'>Delete mode</button>
          {% endif %}
        </div>
      </form>
    </section>
    <section>
      <h2>Status</h2>
      <p><span class="status">{{ last_job.status }}</span></p>
      {% if last_job.started %}<p>Started: {{ last_job.started }}</p>{% endif %}
      {% if last_job.finished %}<p>Finished: {{ last_job.finished }}</p>{% endif %}
      {% if last_job.output %}<pre>{{ last_job.output }}</pre>{% endif %}
      {% if last_job.error %}<pre>{{ last_job.error }}</pre>{% endif %}
      <h2>OCR</h2>
      <p><span class="status">{{ last_ocr_job.status }}</span> {% if last_ocr_job.queued %}{{ last_ocr_job.queued }} queued{% endif %}</p>
      {% if last_ocr_job.started %}<p>Started: {{ last_ocr_job.started }}</p>{% endif %}
      {% if last_ocr_job.finished %}<p>Finished: {{ last_ocr_job.finished }}</p>{% endif %}
      {% if last_ocr_job.input %}<p>Input: {{ last_ocr_job.input }}</p>{% endif %}
      {% if last_ocr_job.output %}<pre>{{ last_ocr_job.output }}</pre>{% endif %}
      {% if last_ocr_job.error %}<pre>{{ last_ocr_job.error }}</pre>{% endif %}
    </section>
    <section>
      <h2>Files</h2>
      {% if file_groups %}
      <form class="bulk-delete-form" method="post" action="{{ url_for('delete_selected_files') }}">
        <div class="bulk-actions">
          <label class="checkbox-label"><input class="file-check" id="select-all-files" type="checkbox"> Select all</label>
          <button class="bulk-delete-button" onclick="return confirmBulkDelete()">Delete selected</button>
        </div>
        <div class="file-groups">
          {% for group in file_groups %}
          <div class="file-day">
            <h3 class="file-day-title">{{ group.day }}</h3>
            <ul class="file-list">
              {% for document in group.files %}
          <li class="file-row">
            <a class="file-preview-link" href="{{ url_for('view_file', name=document.view_name) }}" target="_blank" aria-label="Open {{ document.view_kind }} for {{ document.title }}">
              <img class="file-preview" src="{{ url_for('preview', name=document.preview_name) }}" alt="">
            </a>
            <div class="file-details">
              <div class="file-title">{{ document.title }}</div>
              <div class="file-links">
                {% for file in document.files %}
                <div class="file-variant">
                  <input class="file-check file-select" type="checkbox" name="files" value="{{ file.name }}">
                  <a href="{{ url_for('download', name=file.name) }}">{{ file.kind }}</a>
                  <span class="file-name">{{ file.name }}</span>
                  <button class="delete-button" formaction="{{ url_for('delete_file', name=file.name) }}" onclick='return confirm({{ ("Delete " ~ file.name ~ "?")|tojson }})'>Delete</button>
                </div>
                {% endfor %}
              </div>
            </div>
          </li>
              {% endfor %}
            </ul>
          </div>
          {% endfor %}
        </div>
      </form>
      {% else %}
      <p>No scans yet.</p>
      {% endif %}
    </section>
    <section>
      <h2>Scanner discovery</h2>
      <pre>{{ devices }}</pre>
    </section>
  </main>
  <script>
    const selectAllFiles = document.getElementById("select-all-files");
    const fileSelections = () => Array.from(document.querySelectorAll(".file-select"));

    if (selectAllFiles) {
      selectAllFiles.addEventListener("change", () => {
        fileSelections().forEach((checkbox) => {
          checkbox.checked = selectAllFiles.checked;
        });
      });
    }

    function confirmBulkDelete() {
      const selected = fileSelections().filter((checkbox) => checkbox.checked);
      if (selected.length === 0) {
        return false;
      }
      return confirm(`Delete ${selected.length} selected file${selected.length === 1 ? "" : "s"}?`);
    }
  </script>
</body>
</html>
"""


def list_devices():
    if os.environ.get("SCAN_BACKEND") == "wifi":
        scanner_ip = os.environ.get("SCANNER_IP", "not configured")
        return f"ScanSnap Wi-Fi backend configured for {scanner_ip}."

    try:
        result = subprocess.run(
            ["scanimage", "-L"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception as exc:
        return f"Could not list scanners: {exc}"

    text = (result.stdout + result.stderr).strip()
    return text or "No scanners found."


def run_logged_subprocess(command, env):
    stdout_lines = []
    stderr_lines = []
    started_at = time.monotonic()
    log_event("subprocess.start", command=" ".join(command))

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        bufsize=1,
    )

    def stream_output(pipe, stream_name, lines):
        try:
            for line in iter(pipe.readline, ""):
                line = line.rstrip("\n")
                lines.append(line)
                log_event("subprocess.output", command=command[0], stream=stream_name, line=line)
        finally:
            pipe.close()

    threads = [
        threading.Thread(target=stream_output, args=(process.stdout, "stdout", stdout_lines), daemon=True),
        threading.Thread(target=stream_output, args=(process.stderr, "stderr", stderr_lines), daemon=True),
    ]
    for thread in threads:
        thread.start()

    returncode = process.wait()
    for thread in threads:
        thread.join(timeout=2.0)

    duration = f"{time.monotonic() - started_at:.3f}"
    log_event("subprocess.finished", command=command[0], returncode=returncode, duration_seconds=duration)
    return subprocess.CompletedProcess(command, returncode, "\n".join(stdout_lines), "\n".join(stderr_lines))


def scan_output_paths(stdout):
    paths = []
    for line in stdout.splitlines():
        text = line.strip()
        if not text:
            continue
        path = Path(text)
        if path.exists():
            paths.append(str(path))
    return paths


def should_enqueue_ocr(env, path):
    if not truthy(env.get("SCAN_OCR_ENABLED", "true")):
        return False
    scan_path = Path(path)
    return scan_path.is_file() and scan_path.suffix.lower() == ".pdf" and not scan_path.name.endswith(".ocr.pdf")


def run_scan_locked(env_overrides):
    global last_job, last_scan_completed_at
    trigger = env_overrides.get("SCAN_TRIGGER", "web")
    started_at = time.monotonic()
    try:
        log_event("scan.start", trigger=trigger, profile=env_overrides.get("SCAN_PROFILE_NAME"))
        last_job = {
            "started": datetime.now().isoformat(timespec="seconds"),
            "finished": None,
            "status": "running",
            "output": "",
            "error": "",
        }
        env = os.environ.copy()
        env.update(env_overrides)
        log_event(
            "scan.command.start",
            trigger=trigger,
            backend=env.get("SCAN_BACKEND", "sane"),
            source=env.get("SCAN_SOURCE", "ADF Duplex"),
            format=env.get("SCAN_FORMAT", "pdf"),
            profile=env.get("SCAN_PROFILE_NAME"),
        )
        result = run_logged_subprocess(["scan-once"], env)
        raw_paths = scan_output_paths(result.stdout)
        raw_output = "\n".join(raw_paths) if raw_paths else result.stdout.strip()
        last_job = {
            "started": last_job["started"],
            "finished": datetime.now().isoformat(timespec="seconds"),
            "status": "done" if result.returncode == 0 else f"failed ({result.returncode})",
            "output": raw_output,
            "error": result.stderr.strip(),
        }
        last_scan_completed_at = time.monotonic()
        log_event(
            "scan.finished",
            trigger=trigger,
            returncode=result.returncode,
            raw_paths=",".join(raw_paths),
            duration_seconds=f"{time.monotonic() - started_at:.3f}",
        )
        if result.returncode == 0:
            for raw_path in raw_paths:
                if should_enqueue_ocr(env, raw_path):
                    log_event("scan.ocr.enqueue", raw_path=raw_path)
                    enqueue_ocr(raw_path, env_overrides)
                else:
                    log_event("scan.ocr.skipped", raw_path=raw_path, enabled=env.get("SCAN_OCR_ENABLED", "true"))
    finally:
        if os.environ.get("SCAN_BACKEND") == "wifi":
            button_rearm_requested.set()
            log_event("button.rearm.requested", trigger=trigger)
        job_lock.release()
        log_event("scan.lock.released", trigger=trigger)


def start_scan_thread(env_overrides=None):
    if not job_lock.acquire(blocking=False):
        log_event("scan.start.rejected", reason="scan-running", trigger=(env_overrides or {}).get("SCAN_TRIGGER", "web"))
        return False
    thread = threading.Thread(target=run_scan_locked, args=(env_overrides or {},), daemon=True)
    thread.start()
    return True


def ocr_queue_length():
    with ocr_state_lock:
        return len(ocr_queue)


def set_ocr_job(update):
    global last_ocr_job
    with ocr_state_lock:
        last_ocr_job = {
            **last_ocr_job,
            **update,
            "queued": len(ocr_queue),
        }


def enqueue_ocr(raw_path, env_overrides):
    with ocr_state_lock:
        ocr_queue.append({"raw_path": raw_path, "env": dict(env_overrides or {})})
        last_ocr_job["queued"] = len(ocr_queue)
        if last_ocr_job["status"] == "idle":
            last_ocr_job["status"] = "queued"
        log_event("ocr.queued", raw_path=raw_path, queued=len(ocr_queue))
    start_ocr_worker()


def start_ocr_worker():
    if not ocr_lock.acquire(blocking=False):
        return
    thread = threading.Thread(target=ocr_worker, daemon=True)
    thread.start()


def ocr_worker():
    try:
        while True:
            with ocr_state_lock:
                if not ocr_queue:
                    last_ocr_job["queued"] = 0
                    if last_ocr_job["status"] == "queued":
                        last_ocr_job["status"] = "idle"
                    return
                job = ocr_queue.popleft()
                last_ocr_job.update(
                    {
                        "started": datetime.now().isoformat(timespec="seconds"),
                        "finished": None,
                        "status": "running",
                        "input": job["raw_path"],
                        "output": "",
                        "error": "",
                        "queued": len(ocr_queue),
                    }
                )

            env = os.environ.copy()
            env.update(job["env"])
            log_event("ocr.start", raw_path=job["raw_path"])
            result = subprocess.run(
                ["ocr-scan", job["raw_path"]],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            log_event("ocr.finished", raw_path=job["raw_path"], returncode=result.returncode)
            set_ocr_job(
                {
                    "finished": datetime.now().isoformat(timespec="seconds"),
                    "status": "done" if result.returncode == 0 else f"failed ({result.returncode})",
                    "output": result.stdout.strip(),
                    "error": result.stderr.strip(),
                }
            )
    finally:
        ocr_lock.release()


def is_button_notice(data):
    return len(data) >= 12 and data[4:8] == b"VENS"


def arm_button_client():
    started_at = time.monotonic()
    log_event("button.arm.start")
    try:
        result = subprocess.run(
            ["scansnap-button-arm"],
            check=False,
            capture_output=True,
            text=True,
            timeout=float(os.environ.get("SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS", "45")),
            env=os.environ.copy(),
        )
    except Exception as exc:
        log_event("button.arm.exception", error=exc, duration_seconds=f"{time.monotonic() - started_at:.3f}")
        return False

    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        log_event(
            "button.arm.failed",
            returncode=result.returncode,
            details=details,
            duration_seconds=f"{time.monotonic() - started_at:.3f}",
        )
        return False

    details = result.stdout.strip()
    log_event(
        "button.arm.succeeded",
        details=details or "ScanSnap button client armed",
        duration_seconds=f"{time.monotonic() - started_at:.3f}",
    )
    return True


def scanner_reachable(scanner_ip):
    if not scanner_ip:
        log_event("scanner.reachability", result="missing-scanner-ip")
        return False

    port = int(os.environ.get("SCANSNAP_BUTTON_REACHABILITY_PORT", "53219"))
    timeout = float(os.environ.get("SCANSNAP_BUTTON_REACHABILITY_TIMEOUT_SECONDS", "1"))
    client_ip = os.environ.get("SCANSNAP_CLIENT_IP", "")

    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(timeout)
    started_at = time.monotonic()
    try:
        if client_ip:
            probe.bind((client_ip, 0))
        probe.connect((scanner_ip, port))
        log_event(
            "scanner.reachability",
            result="reachable",
            scanner_ip=scanner_ip,
            port=port,
            duration_seconds=f"{time.monotonic() - started_at:.3f}",
        )
        return True
    except OSError as exc:
        log_event(
            "scanner.reachability",
            result="unreachable",
            scanner_ip=scanner_ip,
            port=port,
            error=exc,
            duration_seconds=f"{time.monotonic() - started_at:.3f}",
        )
        return False
    finally:
        probe.close()


def button_listener():
    global last_button_started_at
    scanner_ip = os.environ.get("SCANNER_IP", "")
    port = int(os.environ.get("SCANSNAP_BUTTON_PORT", "55265"))
    debounce_seconds = float(os.environ.get("SCANSNAP_BUTTON_DEBOUNCE_SECONDS", "3"))
    cooldown_seconds = float(os.environ.get("SCANSNAP_BUTTON_COOLDOWN_SECONDS", "10"))
    arm_interval = float(
        os.environ.get(
            "SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS",
            os.environ.get("SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS", "60"),
        )
    )
    reachability_interval = float(os.environ.get("SCANSNAP_BUTTON_REACHABILITY_INTERVAL_SECONDS", "3"))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(1.0)
    log_event("button.listener.start", port=port, scanner_ip=scanner_ip)

    armed = scanner_reachable(scanner_ip) and arm_button_client()
    next_arm_at = time.monotonic() + arm_interval if armed else float("inf")
    next_reachability_at = time.monotonic() + reachability_interval
    log_event("button.listener.state", armed=armed)

    while True:
        now = time.monotonic()
        if not job_lock.locked():
            should_arm = False
            if button_rearm_requested.is_set():
                button_rearm_requested.clear()
                should_arm = scanner_reachable(scanner_ip)
                log_event("button.rearm.check", reachable=should_arm)
            elif armed and now >= next_arm_at:
                should_arm = True
                log_event("button.arm.refresh.due")
            elif not armed and now >= next_reachability_at:
                should_arm = scanner_reachable(scanner_ip)
                next_reachability_at = time.monotonic() + reachability_interval
                log_event("button.arm.waiting", reachable=should_arm)

            if should_arm:
                armed = arm_button_client()
                next_arm_at = time.monotonic() + arm_interval if armed else float("inf")
                if not armed:
                    next_reachability_at = time.monotonic() + reachability_interval
                log_event("button.listener.state", armed=armed)

        try:
            data, address = sock.recvfrom(2048)
        except socket.timeout:
            continue

        source_ip = address[0]
        if scanner_ip and source_ip != scanner_ip:
            log_event("button.notice.ignored", reason="unexpected-source", source_ip=source_ip, bytes=len(data))
            continue
        if not is_button_notice(data):
            log_event("button.notice.ignored", reason="not-vens", source_ip=source_ip, bytes=len(data))
            continue

        now = time.monotonic()
        log_event("button.notice.received", source_ip=source_ip, bytes=len(data), armed=armed)
        if now - last_button_started_at < debounce_seconds:
            log_event(
                "button.notice.ignored",
                reason="debounce",
                elapsed_seconds=f"{now - last_button_started_at:.3f}",
                threshold_seconds=debounce_seconds,
            )
            continue
        if now - last_scan_completed_at < cooldown_seconds:
            log_event(
                "button.notice.ignored",
                reason="cooldown",
                elapsed_seconds=f"{now - last_scan_completed_at:.3f}",
                threshold_seconds=cooldown_seconds,
            )
            continue
        if job_lock.locked():
            log_event("button.notice.ignored", reason="scan-running")
            continue

        scan_settings = load_scan_settings()
        mode = default_mode(scan_settings)
        last_button_started_at = now
        if start_scan_thread(mode_env(mode, "button")):
            armed = False
            log_event("button.scan.started", source_ip=source_ip, profile=mode["name"])
        else:
            log_event("button.notice.ignored", reason="scan-start-rejected")


def maybe_start_button_listener():
    if os.environ.get("SCAN_BACKEND") != "wifi":
        return
    if os.environ.get("SCANSNAP_BUTTON_SCAN_ENABLED", "true").lower() not in {"1", "true", "yes", "on"}:
        return
    thread = threading.Thread(target=button_listener, daemon=True)
    thread.start()


def output_file(name):
    if Path(name).name != name:
        return None
    path = OUTPUT_DIR / name
    if not scan_output_file(path):
        return None
    return path


def scan_day(path):
    try:
        return datetime.strptime(path.name[:10], "%Y-%m-%d").strftime("%A, %Y-%m-%d")
    except ValueError:
        return datetime.fromtimestamp(path.stat().st_mtime).strftime("%A, %Y-%m-%d")


def scan_sort_key(path):
    return path.name


def scan_base_name(path):
    if path.name.endswith(".ocr.pdf"):
        return f"{path.name[:-8]}.pdf"
    if path.suffix.lower() == ".png":
        return re.sub(r"-page-\d+\.png$", ".png", path.name)
    return path.name


def scan_variant(path):
    if path.name.endswith(".ocr.pdf"):
        return "ocr"
    if path.suffix.lower() == ".png":
        return "png"
    return "source"


def scan_variant_rank(path):
    return {"source": 0, "ocr": 1, "png": 2}.get(scan_variant(path), 9)


def scan_file_kind(path):
    variant = scan_variant(path)
    if variant == "ocr":
        return "OCR PDF"
    if variant == "png":
        match = re.search(r"-page-(\d+)\.png$", path.name)
        return f"PNG page {int(match.group(1))}" if match else "PNG image"
    return "source scan"


def scan_file_entry(path):
    return {
        "name": path.name,
        "kind": scan_file_kind(path),
        "variant": scan_variant(path),
    }


def scan_document_entry(base_name, paths):
    sorted_paths = sorted(paths, key=lambda path: (scan_variant_rank(path), path.name))
    source_path = next((path for path in sorted_paths if scan_variant(path) == "source"), None)
    ocr_path = next((path for path in sorted_paths if scan_variant(path) == "ocr"), None)
    png_path = next((path for path in sorted_paths if scan_variant(path) == "png"), None)
    view_path = ocr_path or source_path or png_path or sorted_paths[0]
    preview_path = view_path
    day_path = source_path or png_path or view_path
    return {
        "title": base_name,
        "day": scan_day(day_path),
        "files": [scan_file_entry(path) for path in sorted_paths],
        "preview_name": preview_path.name,
        "view_name": view_path.name,
        "view_kind": scan_file_kind(view_path),
        "sort_key": max(scan_sort_key(path) for path in sorted_paths),
    }


def grouped_scan_entries(paths):
    document_paths = {}
    for path in paths:
        document_paths.setdefault(scan_base_name(path), []).append(path)

    entries = sorted(
        (scan_document_entry(base_name, grouped_paths) for base_name, grouped_paths in document_paths.items()),
        key=lambda entry: entry["sort_key"],
        reverse=True,
    )
    return [
        {"day": day, "files": list(files)}
        for day, files in groupby(entries, key=lambda entry: entry["day"])
    ]


def preview_path_for(path):
    preview_dir = OUTPUT_DIR / PREVIEW_DIR_NAME
    preview_dir.mkdir(parents=True, exist_ok=True)
    return preview_dir / f"{path.name}.jpg"


def create_pdf_preview(path, preview_path):
    with pikepdf.open(path) as pdf:
        if not pdf.pages:
            return False
        page = pdf.pages[0]
        images = list(page.images.values())
        if not images:
            return False
        image = PdfImage(images[0]).as_pil_image()
        rotation = int(page.get("/Rotate", 0)) % 360

    if image.mode not in {"RGB", "L"}:
        image = image.convert("RGB")
    elif image.mode == "L":
        image = image.convert("RGB")
    if rotation:
        image = image.rotate(-rotation, expand=True)
    image.thumbnail((320, 420), Image.Resampling.LANCZOS)
    image.save(preview_path, "JPEG", quality=82, optimize=True)
    return True


def create_image_preview(path, preview_path):
    image = Image.open(path)
    if image.mode not in {"RGB", "L"}:
        image = image.convert("RGB")
    elif image.mode == "L":
        image = image.convert("RGB")
    image.thumbnail((320, 420), Image.Resampling.LANCZOS)
    image.save(preview_path, "JPEG", quality=82, optimize=True)
    return True


def placeholder_preview():
    image = Image.new("RGB", (320, 420), "#f1f3f4")
    return image


def ensure_preview(path):
    preview_path = preview_path_for(path)
    if preview_path.exists() and preview_path.stat().st_mtime >= path.stat().st_mtime:
        return preview_path

    try:
        if path.suffix.lower() == ".pdf" and create_pdf_preview(path, preview_path):
            return preview_path
        if path.suffix.lower() == ".png" and create_image_preview(path, preview_path):
            return preview_path
    except Exception as exc:
        print(f"Could not create preview for {path.name}: {exc}", flush=True)

    placeholder_preview().save(preview_path, "JPEG", quality=75)
    return preview_path


def delete_preview(path):
    preview_path = OUTPUT_DIR / PREVIEW_DIR_NAME / f"{path.name}.jpg"
    if preview_path.is_file():
        preview_path.unlink()


def scan_output_file(path):
    return path.is_file() and path.suffix.lower() in {".pdf", ".png"}


def editable_mode_from_request(scan_settings):
    edit_mode_id = request.args.get("edit_mode", scan_settings["default_mode_id"])
    if edit_mode_id == "new":
        base = default_mode(scan_settings)
        return {"id": "", "name": "", "settings": dict(base["settings"])}
    return find_mode(scan_settings, edit_mode_id) or default_mode(scan_settings)


@app.get("/")
def index():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    scan_settings = load_scan_settings()
    edit_mode = editable_mode_from_request(scan_settings)
    files = sorted(
        [path for path in OUTPUT_DIR.iterdir() if scan_output_file(path)],
        key=lambda path: path.name,
    )
    return render_template_string(
        PAGE,
        scan_settings=scan_settings,
        edit_mode=edit_mode,
        mode_summaries={mode["id"]: mode_summary(mode) for mode in scan_settings["modes"]},
        last_job=last_job,
        last_ocr_job={**last_ocr_job, "queued": ocr_queue_length()},
        file_groups=grouped_scan_entries(files),
        devices=list_devices(),
    )


@app.post("/scan")
def scan():
    if job_lock.locked():
        log_event("web.scan.ignored", reason="scan-running")
        return redirect(url_for("index"))

    scan_settings = load_scan_settings()
    mode = find_mode(scan_settings, request.form.get("mode_id", "")) or default_mode(scan_settings)
    env_overrides = mode_env(mode, "web")
    log_event("web.scan.requested", profile=mode["name"])
    start_scan_thread(env_overrides)
    return redirect(url_for("index"))


@app.post("/modes/default")
def set_default_mode():
    scan_settings = load_scan_settings()
    mode_id = request.form.get("mode_id", "")
    if find_mode(scan_settings, mode_id):
        scan_settings["default_mode_id"] = mode_id
        save_scan_settings(scan_settings)
        log_event("settings.default.updated", mode_id=mode_id)
    return redirect(url_for("index"))


@app.post("/modes/save")
def save_mode():
    scan_settings = load_scan_settings()
    name = request.form.get("name", "").strip() or "Scan mode"
    existing_id = request.form.get("mode_id", "").strip()
    existing = find_mode(scan_settings, existing_id)
    if existing:
        mode_id = existing_id
        existing["name"] = name
        existing["settings"] = mode_from_form(request.form)
    else:
        mode_id = unique_mode_id(name, scan_settings["modes"])
        scan_settings["modes"].append({"id": mode_id, "name": name, "settings": mode_from_form(request.form)})

    if request.form.get("set_default"):
        scan_settings["default_mode_id"] = mode_id

    save_scan_settings(scan_settings)
    log_event("settings.mode.saved", mode_id=mode_id, name=name)
    return redirect(url_for("index", edit_mode=mode_id))


@app.post("/modes/delete")
def delete_mode():
    scan_settings = load_scan_settings()
    mode_id = request.form.get("mode_id", "").strip()
    remaining = [mode for mode in scan_settings["modes"] if mode["id"] != mode_id]
    if mode_id and remaining and len(remaining) != len(scan_settings["modes"]):
        scan_settings["modes"] = remaining
        if scan_settings["default_mode_id"] == mode_id:
            scan_settings["default_mode_id"] = remaining[0]["id"]
        save_scan_settings(scan_settings)
        log_event("settings.mode.deleted", mode_id=mode_id)
    return redirect(url_for("index"))


@app.get("/files/<path:name>")
def download(name):
    path = output_file(name)
    if not path:
        return Response("Not found", status=404)
    mimetype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return Response(
        path.read_bytes(),
        mimetype=mimetype,
        headers={"Content-Disposition": f"attachment; filename={path.name}"},
    )


@app.get("/view/<path:name>")
def view_file(name):
    path = output_file(name)
    if not path:
        return Response("Not found", status=404)
    mimetype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return Response(
        path.read_bytes(),
        mimetype=mimetype,
        headers={"Content-Disposition": f"inline; filename={path.name}"},
    )


@app.get("/files/<path:name>/preview")
def preview(name):
    path = output_file(name)
    if not path or path.suffix.lower() not in {".pdf", ".png"}:
        return Response("Not found", status=404)
    preview_file = ensure_preview(path)
    return Response(preview_file.read_bytes(), mimetype="image/jpeg")


@app.post("/files/<path:name>/delete")
def delete_file(name):
    path = output_file(name)
    if path:
        delete_preview(path)
        path.unlink()
    return redirect(url_for("index"))


@app.post("/files/delete-selected")
def delete_selected_files():
    for name in request.form.getlist("files"):
        path = output_file(name)
        if path:
            delete_preview(path)
            path.unlink()
    return redirect(url_for("index"))


if __name__ == "__main__":
    maybe_start_button_listener()
    app.run(host="0.0.0.0", port=int(os.environ.get("WEB_PORT", "8080")))
