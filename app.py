import os
import subprocess
import threading
from datetime import datetime
from pathlib import Path

from flask import Flask, Response, redirect, render_template_string, request, url_for


app = Flask(__name__)
OUTPUT_DIR = Path(os.environ.get("SCAN_OUTPUT_DIR", "/scans"))
job_lock = threading.Lock()
last_job = {
    "started": None,
    "finished": None,
    "status": "idle",
    "output": "",
    "error": "",
}


PAGE = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ScanSnap Linux</title>
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
    pre { margin: 0; overflow: auto; white-space: pre-wrap; font-size: 13px; }
    ul { padding-left: 20px; }
    li { margin-bottom: 8px; }
    a { color: #0b57d0; }
    .file-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .delete-form { display: inline; }
    .delete-button { background: #b3261e; padding: 5px 9px; font-size: 13px; }
    .status { display: inline-block; padding: 3px 8px; border-radius: 999px; background: #e8f0fe; color: #174ea6; font-size: 13px; font-weight: 700; }
    @media (prefers-color-scheme: dark) {
      body { background: #171717; color: #f1f3f4; }
      section { background: #202124; border-color: #3c4043; }
      input, select { background: #171717; color: #f1f3f4; border-color: #5f6368; }
      a { color: #8ab4f8; }
    }
  </style>
</head>
<body>
  <main>
    <h1>ScanSnap Linux</h1>
    <section>
      <h2>Scan</h2>
      <form method="post" action="{{ url_for('scan') }}">
        <label>Resolution
          <select name="SCAN_RESOLUTION">
            {% for value in ["200", "300", "400", "600"] %}
            <option value="{{ value }}" {% if defaults.SCAN_RESOLUTION == value %}selected{% endif %}>{{ value }} dpi</option>
            {% endfor %}
          </select>
        </label>
        <label>Mode
          <select name="SCAN_MODE">
            {% for value in ["Color", "Gray", "Lineart"] %}
            <option value="{{ value }}" {% if defaults.SCAN_MODE == value %}selected{% endif %}>{{ value }}</option>
            {% endfor %}
          </select>
        </label>
        <label>Source
          <input name="SCAN_SOURCE" value="{{ defaults.SCAN_SOURCE }}">
        </label>
        <label>OCR language
          <input name="SCAN_LANGUAGE" value="{{ defaults.SCAN_LANGUAGE }}">
        </label>
        <label>Topic override
          <input name="SCAN_TOPIC" value="" placeholder="automatic">
        </label>
        <button {% if last_job.status == "running" %}disabled{% endif %}>Start scan</button>
      </form>
    </section>
    <section>
      <h2>Status</h2>
      <p><span class="status">{{ last_job.status }}</span></p>
      {% if last_job.started %}<p>Started: {{ last_job.started }}</p>{% endif %}
      {% if last_job.finished %}<p>Finished: {{ last_job.finished }}</p>{% endif %}
      {% if last_job.output %}<pre>{{ last_job.output }}</pre>{% endif %}
      {% if last_job.error %}<pre>{{ last_job.error }}</pre>{% endif %}
    </section>
    <section>
      <h2>Files</h2>
      {% if files %}
      <ul>
        {% for file in files %}
        <li class="file-row">
          <a href="{{ url_for('download', name=file.name) }}">{{ file.name }}</a>
          <form class="delete-form" method="post" action="{{ url_for('delete_file', name=file.name) }}">
            <button class="delete-button" onclick='return confirm({{ ("Delete " ~ file.name ~ "?")|tojson }})'>Delete</button>
          </form>
        </li>
        {% endfor %}
      </ul>
      {% else %}
      <p>No scans yet.</p>
      {% endif %}
    </section>
    <section>
      <h2>Scanner discovery</h2>
      <pre>{{ devices }}</pre>
    </section>
  </main>
</body>
</html>
"""


def defaults():
    return {
        "SCAN_LANGUAGE": os.environ.get("SCAN_LANGUAGE", "deu+eng"),
        "SCAN_RESOLUTION": os.environ.get("SCAN_RESOLUTION", "300"),
        "SCAN_MODE": os.environ.get("SCAN_MODE", "Color"),
        "SCAN_SOURCE": os.environ.get("SCAN_SOURCE", "ADF Duplex"),
    }


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


def run_scan(env_overrides):
    global last_job
    with job_lock:
        last_job = {
            "started": datetime.now().isoformat(timespec="seconds"),
            "finished": None,
            "status": "running",
            "output": "",
            "error": "",
        }
        env = os.environ.copy()
        env.update(env_overrides)
        result = subprocess.run(
            ["scan-once"],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        last_job = {
            "started": last_job["started"],
            "finished": datetime.now().isoformat(timespec="seconds"),
            "status": "done" if result.returncode == 0 else f"failed ({result.returncode})",
            "output": result.stdout.strip(),
            "error": result.stderr.strip(),
        }


@app.get("/")
def index():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(
        [path for path in OUTPUT_DIR.iterdir() if path.is_file()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return render_template_string(
        PAGE,
        defaults=defaults(),
        last_job=last_job,
        files=files,
        devices=list_devices(),
    )


@app.post("/scan")
def scan():
    if job_lock.locked():
        return redirect(url_for("index"))

    allowed = {"SCAN_LANGUAGE", "SCAN_RESOLUTION", "SCAN_MODE", "SCAN_SOURCE", "SCAN_TOPIC"}
    env_overrides = {
        key: request.form[key]
        for key in allowed
        if key in request.form and request.form[key].strip()
    }
    thread = threading.Thread(target=run_scan, args=(env_overrides,), daemon=True)
    thread.start()
    return redirect(url_for("index"))


@app.get("/files/<path:name>")
def download(name):
    path = OUTPUT_DIR / name
    if not path.is_file() or path.parent != OUTPUT_DIR:
        return Response("Not found", status=404)
    return Response(path.read_bytes(), headers={"Content-Disposition": f"attachment; filename={path.name}"})


@app.post("/files/<path:name>/delete")
def delete_file(name):
    path = OUTPUT_DIR / name
    if path.is_file() and path.parent == OUTPUT_DIR:
        path.unlink()
    return redirect(url_for("index"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("WEB_PORT", "8080")))
