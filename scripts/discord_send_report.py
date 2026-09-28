#!/usr/bin/env python3
"""
discord_send_report.py:
Clean transport utility to deliver a report file to a Discord user DM or channel
with safe markdown chunking (<1800 characters per message).
"""

import sys
import os
import json
import urllib.request
import urllib.error

def get_bot_token():
    lodge_dir = os.environ.get("LODGE_DIR", "/home/wsl-ops/blue-lodge")
    keys_file = os.path.join(lodge_dir, ".george/keys.conf")
    if os.path.exists(keys_file):
        with open(keys_file, "r") as f:
            for line in f:
                if line.startswith("DISCORD_BOT_TOKEN="):
                    return line.split("=", 1)[1].strip()
    return os.environ.get("DISCORD_BOT_TOKEN", "")

def chunk_markdown(text, max_len=1800):
    chunks = []
    current = []
    current_len = 0
    for line in text.splitlines(keepends=True):
        if current_len + len(line) > max_len and current:
            chunks.append("".join(current))
            current = [line]
            current_len = len(line)
        else:
            current.append(line)
            current_len += len(line)
    if current:
        chunks.append("".join(current))
    return chunks

def send_dm(target, text):
    token = get_bot_token()
    if not token:
        print("[!] DISCORD_BOT_TOKEN not configured.", file=sys.stderr)
        return False

    api_url = "https://discord.com/api/v10"
    headers = {
        "Authorization": f"Bot {token}",
        "Content-Type": "application/json"
    }

    # Resolve target user id
    target_uid = target
    if target in ["@dabe", "dabe"]:
        target_uid = "190628469053325312"
    elif target.startswith("@"):
        target_uid = target[1:]

    # Create DM channel
    dm_payload = json.dumps({"recipient_id": target_uid}).encode("utf-8")
    req = urllib.request.Request(f"{api_url}/users/@me/channels", data=dm_payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            chan_data = json.loads(resp.read().decode("utf-8"))
            chan_id = chan_data.get("id")
    except Exception as e:
        print(f"[!] Failed to open DM channel: {e}", file=sys.stderr)
        return False

    if not chan_id:
        return False

    # Send chunks
    chunks = chunk_markdown(text)
    for idx, c in enumerate(chunks):
        msg_payload = json.dumps({"content": c}).encode("utf-8")
        msg_req = urllib.request.Request(f"{api_url}/channels/{chan_id}/messages", data=msg_payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(msg_req, timeout=10) as msg_resp:
                msg_data = json.loads(msg_resp.read().decode("utf-8"))
                print(f"  ✓ Dispatched chunk {idx+1}/{len(chunks)} (Discord Message ID: {msg_data.get('id')})")
        except Exception as e:
            print(f"[!] Failed to send chunk {idx+1}: {e}", file=sys.stderr)
            return False
    return True

def main():
    if len(sys.argv) < 3:
        print("Usage: discord_send_report.py <recipient> <report_file_or_text>")
        sys.exit(1)

    recipient = sys.argv[1]
    arg2 = sys.argv[2]
    if os.path.isfile(arg2):
        with open(arg2, "r") as f:
            content = f.read()
    else:
        content = arg2

    success = send_dm(recipient, content)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
