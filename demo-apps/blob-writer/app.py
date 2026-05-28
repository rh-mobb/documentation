"""Blob Storage Writer — Flask app for ARO SP-to-MI migration demo.

This app already uses DefaultAzureCredential (best practice). During
migration from SP to MI cluster, NO code change is needed — only K8s
manifest changes (ServiceAccount annotation + pod label).

The app writes entries to Azure Blob Storage and keeps a local log on a
PVC to demonstrate stateful migration (PVC data backup/restore).
"""

import json
import os
from datetime import datetime, timezone

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from flask import Flask, jsonify, request

app = Flask(__name__)

STORAGE_ACCOUNT_URL = os.environ["AZURE_STORAGE_ACCOUNT_URL"]
CONTAINER_NAME = os.environ.get("AZURE_STORAGE_CONTAINER", "demo-data")
LOCAL_LOG_PATH = os.environ.get("LOCAL_LOG_PATH", "/data/entries.json")

credential = DefaultAzureCredential()
blob_service = BlobServiceClient(account_url=STORAGE_ACCOUNT_URL, credential=credential)


def _ensure_container():
    try:
        blob_service.create_container(CONTAINER_NAME)
    except Exception:
        pass


def _load_local_log() -> list:
    try:
        with open(LOCAL_LOG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save_local_log(entries: list):
    os.makedirs(os.path.dirname(LOCAL_LOG_PATH), exist_ok=True)
    with open(LOCAL_LOG_PATH, "w") as f:
        json.dump(entries, f, indent=2)


@app.route("/")
def index():
    entries = _load_local_log()
    return jsonify({
        "status": "ok",
        "app": "blob-writer",
        "local_entries": len(entries),
        "auth_method": _detect_auth_method(),
    })


@app.route("/write", methods=["POST"])
def write_entry():
    data = request.get_json() or {}
    message = data.get("message", "Hello from blob-writer")

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "message": message,
        "cluster": os.environ.get("CLUSTER_NAME", "unknown"),
    }

    _ensure_container()
    blob_name = f"entry-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.json"
    container_client = blob_service.get_container_client(CONTAINER_NAME)
    container_client.upload_blob(blob_name, json.dumps(entry), overwrite=True)

    entries = _load_local_log()
    entries.append(entry)
    _save_local_log(entries)

    return jsonify({
        "status": "written",
        "blob": blob_name,
        "local_count": len(entries),
    })


@app.route("/entries")
def list_entries():
    entries = _load_local_log()
    return jsonify({"source": "local-pvc", "entries": entries})


@app.route("/blobs")
def list_blobs():
    try:
        _ensure_container()
        container_client = blob_service.get_container_client(CONTAINER_NAME)
        blobs = [b.name for b in container_client.list_blobs()]
        return jsonify({"source": "azure-blob-storage", "blobs": blobs})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def _detect_auth_method() -> str:
    if os.environ.get("AZURE_CLIENT_SECRET"):
        return "service-principal (ClientSecretCredential)"
    if os.environ.get("AZURE_FEDERATED_TOKEN_FILE"):
        return "workload-identity (DefaultAzureCredential)"
    return "default-credential (auto-detect)"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
