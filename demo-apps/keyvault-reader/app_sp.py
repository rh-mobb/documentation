"""Key Vault Secret Reader — SP version (BEFORE migration).

This version uses ClientSecretCredential explicitly, which requires
AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, and AZURE_TENANT_ID as environment
variables injected from a Kubernetes Secret.

During migration to an MI cluster, replace ClientSecretCredential with
DefaultAzureCredential (see app.py for the migrated version).
"""

import os

from azure.identity import ClientSecretCredential
from azure.keyvault.secrets import SecretClient
from flask import Flask, jsonify

app = Flask(__name__)

VAULT_URL = os.environ["AZURE_KEYVAULT_URL"]

credential = ClientSecretCredential(
    tenant_id=os.environ["AZURE_TENANT_ID"],
    client_id=os.environ["AZURE_CLIENT_ID"],
    client_secret=os.environ["AZURE_CLIENT_SECRET"],
)
client = SecretClient(vault_url=VAULT_URL, credential=credential)


@app.route("/")
def index():
    return jsonify({"status": "ok", "app": "keyvault-reader", "auth": "service-principal"})


@app.route("/secret/<name>")
def read_secret(name: str):
    try:
        secret = client.get_secret(name)
        return jsonify({
            "name": secret.name,
            "value": secret.value,
            "auth_method": "service-principal (ClientSecretCredential)",
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
