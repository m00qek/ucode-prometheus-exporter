"""make monitoring-lab's check of the dashboards and rules on the lab's data:
each Grafana panel's queries run through Grafana's query API, as its panel
runs them, each Perses panel's through Perses's proxy to its data source, and
the rules as Prometheus loaded them. A query that errs fails; one without data
fails unless its panel is one of MAY_BE_EMPTY, whose collectors have nothing to
observe in the lab, or which show only what went wrong.

usage: monitoring-verify.py   (GRAFANA_URL, PERSES_URL, PROMETHEUS_URL, REPORT)

Run by devenv/scripts/monitoring-lab.sh, in the docs' mkdocs image, which has
Python and PyYAML.
"""

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
GRAFANA = os.environ['GRAFANA_URL']
PERSES = os.environ['PERSES_URL']
PROMETHEUS = os.environ['PROMETHEUS_URL']
REPORT = os.environ.get('REPORT')

# The lab has no radio, no WireGuard interface, no firewall (so no tracked
# connections), and nothing going wrong.
MAY_BE_EMPTY = {
    'Clients', 'Signal of the clients', 'Channel busy', 'Traffic per host',
    'Since each peer\'s handshake', 'WireGuard traffic',
    'Left out at the deadline', 'Failures by error code', 'Quarantined', 'Breaker trips and program timeouts',
}
WINDOW = 300


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def post(url, body):
    req = urllib.request.Request(url, json.dumps(body).encode(), {'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def label_values(label, match):
    q = urllib.parse.urlencode({'match[]': match})
    return get(f'{PROMETHEUS}/api/v1/label/{label}/values?{q}')['data']


def substitute(expr, values, rate_interval):
    expr = re.sub(r'\$\{?__rate_interval\}?', rate_interval, expr)
    for k, v in values.items():
        expr = re.sub(r'\$\{?' + k + r'\}?', v, expr)
    return expr


def grafana_panels(doc):
    for p in doc['panels']:
        if p.get('type') != 'row':
            yield p['title'], [t['expr'] for t in p.get('targets', [])]


def perses_panels(doc):
    for key, p in doc['spec']['panels'].items():
        yield p['spec']['display']['name'], [q['spec']['plugin']['spec']['query'] for q in p['spec'].get('queries', [])]


def run_grafana(expr):
    now = int(time.time() * 1000)
    r = post(f'{GRAFANA}/api/ds/query', {
        'from': str(now - WINDOW * 1000), 'to': str(now),
        'queries': [{'refId': 'A', 'datasource': {'type': 'prometheus', 'uid': 'prometheus'}, 'expr': expr,
                     'range': True, 'instant': False, 'intervalMs': 5000, 'maxDataPoints': 300}]})
    res = (r.get('results') or {}).get('A') or {}
    if res.get('error') or 'results' not in r:
        return 'error', res.get('error') or r.get('message')
    points = sum(len(f['data']['values'][1]) if len(f['data']['values']) > 1 else 0 for f in res.get('frames', []))
    return ('data', points) if points else ('empty', None)


def run_perses(expr):
    now = int(time.time())
    q = urllib.parse.urlencode({'query': expr, 'start': now - WINDOW, 'end': now, 'step': 5})
    try:
        r = get(f'{PERSES}/proxy/projects/openwrt/datasources/prometheus/api/v1/query_range?{q}')
    except urllib.error.HTTPError as e:
        return 'error', e.read().decode()[:200]
    if r.get('status') != 'success':
        return 'error', r.get('error')
    return ('data', len(r['data']['result'])) if r['data']['result'] else ('empty', None)


def check(tool, title, panels, run, values, rate_interval, lines):
    failures = 0
    for name, exprs in panels:
        outcomes = [run(substitute(e, values, rate_interval)) for e in exprs]
        errors = [o[1] for o in outcomes if o[0] == 'error']
        data = any(o[0] == 'data' for o in outcomes)
        if errors:
            verdict, failures = f'ERROR {errors[0]}', failures + 1
        elif data:
            verdict = 'data'
        elif name in MAY_BE_EMPTY:
            verdict = 'no data (nothing to observe in the lab)'
        else:
            verdict, failures = 'NO DATA', failures + 1
        lines.append(f'{tool:8} {title:24} {name:36} {verdict}')
    return failures


def main():
    lines, failures = [], 0
    # The job and instance as the dashboards' variables find them, whatever
    # the lab's job is called.
    job = label_values('job', 'ucode_prometheus_exporter_build_info')[0]
    values = {'job': job, 'instance': label_values('instance', f'ucode_prometheus_exporter_build_info{{job="{job}"}}')[0]}

    for path in sorted((ROOT / 'monitoring' / 'grafana').glob('*.json')):
        doc = json.loads(path.read_text())
        loaded = get(f'{GRAFANA}/api/dashboards/uid/{doc["uid"]}')['dashboard']
        if loaded.get('title') != doc['title']:
            lines.append(f'grafana  {doc["title"]}: not provisioned')
            failures += 1
        failures += check('grafana', doc['title'], grafana_panels(doc), run_grafana, values, '$__rate_interval', lines)

    for path in sorted((ROOT / 'monitoring' / 'perses').glob('*.yaml')):
        doc = yaml.safe_load(path.read_text())
        name = doc['metadata']['name']
        loaded = get(f'{PERSES}/api/v1/projects/openwrt/dashboards/{name}')
        if loaded['metadata']['name'] != name:
            lines.append(f'perses   {name}: not applied')
            failures += 1
        failures += check('perses', doc['spec']['display']['name'], perses_panels(doc), run_perses, values, '20s', lines)

    groups = get(f'{PROMETHEUS}/api/v1/rules')['data']['groups']
    rules = [r for g in groups for r in g['rules']]
    bad = [r['name'] for r in rules if r.get('health') != 'ok']
    firing = sorted({r['name'] for r in rules for a in r.get('alerts', []) if a['state'] == 'firing'})
    lines.append(f'rules    {len(rules)} loaded, {len(bad)} unhealthy{": " + ", ".join(bad) if bad else ""}; '
                 f'firing: {", ".join(firing) or "none"}')
    failures += len(bad)

    text = '\n'.join(lines) + '\n'
    print(text, end='')
    if REPORT:
        Path(REPORT).write_text(text)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
