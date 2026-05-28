"""Key Vault Secret Reader — MI version (uses DefaultAzureCredential).

Auto-detects workload identity via ServiceAccount — no secrets needed.
See app_sp.py for the SP version that uses ClientSecretCredential.
"""

import os

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from flask import Flask, jsonify

app = Flask(__name__)

VAULT_URL = os.environ["AZURE_KEYVAULT_URL"]

credential = DefaultAzureCredential()
client = SecretClient(vault_url=VAULT_URL, credential=credential)


@app.route("/")
def index():
    return jsonify({"status": "ok", "app": "keyvault-reader", "auth_method": _detect_auth_method()})


@app.route("/secret/<name>")
def read_secret(name: str):
    try:
        secret = client.get_secret(name)
        return jsonify({
            "name": secret.name,
            "value": secret.value,
            "auth_method": _detect_auth_method(),
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def _detect_auth_method() -> str:
    if os.environ.get("AZURE_CLIENT_SECRET"):
        return "service-principal (ClientSecretCredential)"
    if os.environ.get("AZURE_FEDERATED_TOKEN_FILE"):
        return "workload-identity (DefaultAzureCredential)"
    return "unknown"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
