"""
Manages the Xray config.json on the Russia server.
Regenerates the clients list from the database on every add/delete.
"""

import json
import os
import subprocess

XRAY_CONFIG = os.getenv("XRAY_CONFIG", "/opt/vpnsmart/xray/config.json")
XRAY_CONTAINER = os.getenv("XRAY_CONTAINER", "vpnsmart-xray-russia")
VLESS_INBOUND_TAG = "vless-in"


def _find_vless_inbound_index(config: dict) -> int:
    """Find the VLESS inbound index by tag."""
    for i, inbound in enumerate(config.get("inbounds", [])):
        if inbound.get("tag") == VLESS_INBOUND_TAG:
            return i
    raise ValueError(f"Inbound with tag '{VLESS_INBOUND_TAG}' not found in config")


def reload_xray_users(clients: list[dict]):
    """Update Xray config with current client list and restart."""
    with open(XRAY_CONFIG, "r") as f:
        config = json.load(f)

    users = [
        {"email": c["name"], "id": c["uuid"], "flow": "xtls-rprx-vision"}
        for c in clients
    ]

    if not users:
        users = [
            {
                "email": "_placeholder",
                "id": "00000000-0000-0000-0000-000000000000",
                "flow": "xtls-rprx-vision",
            }
        ]

    idx = _find_vless_inbound_index(config)
    config["inbounds"][idx]["settings"]["clients"] = users

    with open(XRAY_CONFIG, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    subprocess.run(
        ["docker", "restart", XRAY_CONTAINER],
        capture_output=True,
        timeout=30,
    )


def generate_vless_link(
    uuid: str,
    name: str,
    server_ip: str,
    reality_public_key: str,
    short_id: str,
    server_name: str = "ya.ru",
    port: int = 443,
) -> str:
    """Generate a VLESS sharing link."""
    return (
        f"vless://{uuid}@{server_ip}:{port}"
        f"?encryption=none"
        f"&flow=xtls-rprx-vision"
        f"&security=reality"
        f"&sni={server_name}"
        f"&fp=chrome"
        f"&pbk={reality_public_key}"
        f"&sid={short_id}"
        f"&type=tcp"
        f"#{name}"
    )
