#!/usr/bin/env python3
"""Configure the public production n8n form URL. No API key belongs in the app."""
import argparse
import pathlib
import urllib.parse
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url', help='HTTPS Production Form URL; use an empty string to disable automatic email')
args = parser.parse_args()
url = args.url.strip()
if url:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or 'form-test' in parsed.path:
        parser.error('Use an HTTPS production form URL without credentials, fragments or /form-test/.')
root = pathlib.Path(__file__).resolve().parents[1]
resources = ET.Element('resources')
ET.SubElement(resources, 'string', name='bridge_download_email_form_url', translatable='false').text = url
ET.indent(resources)
ET.ElementTree(resources).write(root / 'android/app/src/main/res/values/downloads.xml', encoding='utf-8', xml_declaration=True)
print('Download email form configured. Rebuild Android to include it.' if url else 'Automatic email disabled; Android uses an explicit email draft.')
