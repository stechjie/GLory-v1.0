#!/usr/bin/env python3
"""Install the static invitation page and reload Caddy, leaving game services untouched."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urlsplit

FILES = ('index.html', 'style.css', 'app.js', 'routing.mjs', 'config.json', 'invite-qr.png')
MARKER = '\t# GLory beta invitation page\n\timport /etc/caddy/glory-beta.caddy\n'
SNIPPET = '''redir /beta /beta/ 302
handle_path /beta/* {
    root * /opt/glory/public/beta
    header {
        Cache-Control "no-store"
        Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    }
    file_server
}
'''

def check_url(value, host, pattern):
    u = urlsplit(value)
    assert u.scheme == 'https' and u.netloc == host and not u.query and not u.fragment
    assert re.fullmatch(pattern, u.path), 'Invalid invitation URL'

def validate_config(config):
    ios, android = config['ios'], config['android']
    assert ios['ready'] is True and android['ready'] is True, 'Both platforms must be verified before publishing'
    check_url(ios['url'], 'testflight.apple.com', r'/join/[A-Za-z0-9]+/?')
    check_url(android['url'], 'play.google.com', r'/apps/(internaltest/\d+|testing/com\.glory\.game\.google)/?')
    assert android['mode'] in ('group', 'open')
    if android['mode'] == 'group':
        check_url(android['group_url'], 'groups.google.com', r'/g/[A-Za-z0-9_-]+/?')

def patch_config(text, domain):
    # Only the identified API site is modified; all other sites/directives remain intact.
    start = re.search(r'^' + re.escape(domain) + r'\s*\{\s*$', text, re.M)
    assert start, 'Expected standalone API site not found; inspect live Caddyfile'
    fallback = text.find('\n\thandle {', start.end())
    next_site = text.find('\n}', start.end())
    assert fallback >= 0 and next_site > fallback, 'Expected API fallback not found'
    if MARKER.strip() in text[start.start():next_site]:
        return text
    return text[:fallback] + '\n' + MARKER + text[fallback:]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--domain', required=True)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    assert re.fullmatch(r'[a-zA-Z0-9.-]+', args.domain)
    source = Path(__file__).resolve().parent
    validate_config(json.loads((source / 'config.json').read_text()))
    for name in FILES:
        assert (source / name).is_file(), 'Missing ' + name
    if args.check_only:
        print('Configuration and assets ready; no server changes made')
        return
    assert os.geteuid() == 0, 'Run as root on the server'
    config = Path('/etc/caddy/Caddyfile')
    before = config.read_text()
    candidate = patch_config(before, args.domain)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = Path('/var/backups/glory/beta-site') / stamp
    backup.mkdir(parents=True, exist_ok=False)
    shutil.copy2(config, backup / 'Caddyfile')
    target = Path('/opt/glory/public/beta')
    snippet = Path('/etc/caddy/glory-beta.caddy')
    had_target, had_snippet = target.exists(), snippet.exists()
    if had_target:
        shutil.copytree(target, backup / 'beta')
    if had_snippet:
        shutil.copy2(snippet, backup / 'glory-beta.caddy')
    try:
        target.mkdir(parents=True, exist_ok=True)
        target.chmod(0o755)
        for name in FILES:
            shutil.copyfile(source / name, target / name)
            (target / name).chmod(0o644)
        snippet.write_text(SNIPPET)
        snippet.chmod(0o644)
        config.write_text(candidate)
        subprocess.run(['caddy','validate','--config',str(config),'--adapter','caddyfile'],check=True)
        subprocess.run(['systemctl','reload','caddy'],check=True,timeout=30)
        subprocess.run(['curl','--fail','--silent','--show-error','--max-time','15',
                        '--resolve',args.domain+':443:127.0.0.1',
                        'https://'+args.domain+'/beta/config.json'],stdout=subprocess.DEVNULL,check=True)
        print('PUBLISHED https://' + args.domain + '/beta/ backup=' + str(backup))
    except BaseException:
        config.write_text(before)
        if had_snippet:
            shutil.copy2(backup / 'glory-beta.caddy',snippet)
        else:
            snippet.unlink(missing_ok=True)
        if had_target:
            shutil.rmtree(target)
            shutil.copytree(backup / 'beta',target)
        elif target.exists():
            shutil.rmtree(target)
        subprocess.run(['systemctl','reload','caddy'],timeout=30)
        raise

if __name__ == '__main__':
    main()
