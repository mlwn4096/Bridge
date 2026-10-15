#!/usr/bin/env python3
"""Import an inactive workflow into your own n8n instance using a local API key."""
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

base = os.environ.get('N8N_BASE_URL', '').rstrip('/')
key = os.environ.get('N8N_API_KEY', '')
parsed = urllib.parse.urlsplit(base)
if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or not key:
    sys.exit('Set N8N_BASE_URL to your HTTPS n8n instance and N8N_API_KEY locally. Do not put the key in source or chat.')
root = pathlib.Path(__file__).resolve().parents[1]
workflow = json.loads((root / 'automation/n8n/bridge-download-email.json').read_text())
payload = {name: workflow[name] for name in ('name', 'nodes', 'connections', 'settings')}
request = urllib.request.Request(base + '/api/v1/workflows', data=json.dumps(payload).encode(), headers={
    'X-N8N-API-KEY': key, 'Content-Type': 'application/json'}, method='POST')
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        created = json.load(response)
except urllib.error.HTTPError as error:
    sys.exit(f'n8n rejected the import (HTTP {error.code}). Check the instance URL, API access and key permissions.')
except urllib.error.URLError:
    sys.exit('Could not reach n8n. Check the instance URL and network connection.')
print(f'Imported inactive workflow: {created.get("name")} (ID {created.get("id")}). Connect Gmail and publish it in n8n.')
