"""Checks that the alerting rules, their tests and the dashboards of
monitoring/ name only metric families and labels that docs/reference/metrics.md
lists: a family the exporter does not write would only ever be "no data".

usage: monitoring-refs.py [FILE...]   (default: every file of monitoring/)

Run by devenv/scripts/monitoring-check.sh, in the docs' mkdocs image, which has
Python and PyYAML. It reads PromQL as far as names go: the metric names, the
labels of each selector's matchers, those of by/without/on/ignoring/
group_left/group_right, those label_replace and label_join read and make, and
those a legend names. A selector's matchers must be its family's labels; the
other labels must be some family's of the expression, or one it makes.
"""

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
REFERENCE = ROOT / 'docs' / 'reference' / 'metrics.md'

# What the scraper adds: the target's labels on every series, and the series
# it writes of each scrape, Prometheus's and vmagent's.
TARGET_LABELS = {'job', 'instance'}
SCRAPE_SERIES = {
    'up', 'scrape_duration_seconds', 'scrape_timeout_seconds', 'scrape_samples_scraped',
    'scrape_samples_post_metric_relabeling', 'scrape_series_added', 'scrape_sample_limit',
}

KEYWORDS = {
    'by', 'without', 'on', 'ignoring', 'group_left', 'group_right', 'bool',
    'and', 'or', 'unless', 'offset', 'atan2', 'inf', 'nan', 'start', 'end',
}
GROUPING = {'by', 'without', 'on', 'ignoring', 'group_left', 'group_right'}
AGGREGATIONS = {
    'sum', 'min', 'max', 'avg', 'group', 'stddev', 'stdvar', 'count', 'count_values',
    'bottomk', 'topk', 'quantile', 'limitk', 'limit_ratio',
}

# Grafana's and Perses's variables, as a query has them before it is run.
DURATION_VARS = re.compile(r'\$\{?__(rate_interval|interval|range)\}?')
OTHER_VARS = re.compile(r'\$\{?\w+(:\w+)?\}?')
LEGEND_LABEL = re.compile(r'\{\{\s*\.?(\w+)\s*\}\}')

TOKEN = re.compile(r'''
    (?P<space>\s+|\#[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`[^`]*`)
  | (?P<duration>\[[^\]]*\])
  | (?P<number>0x[0-9a-fA-F]+|\d+(\.\d*)?([eE][-+]?\d+)?|\.\d+)
  | (?P<ident>[a-zA-Z_:][a-zA-Z0-9_:]*)
  | (?P<op>=~|!~|!=|==|<=|>=|[-+*/%^<>=(){},@])
''', re.VERBOSE)


class Reference:
    """The families of metrics.md: exact names and patterns, with their labels."""

    def __init__(self, path):
        self.exact = {}
        self.patterns = []
        for line in path.read_text().splitlines():
            cells = [c.strip() for c in line.split('|')]
            if len(cells) < 5 or not cells[1].startswith('`'):
                continue
            family = cells[1].strip('`')
            labels = set(re.findall(r'`(\w+)`', cells[3]))
            if family.startswith('<'):
                continue  # textfile's: the files' own families, anything
            if '<' in family:
                pattern = re.escape(family)
                pattern = re.sub(r'\\\[(.*?)\\\]', r'(?:\1)?', pattern)
                pattern = re.sub(r'<[^>]*>', r'[A-Za-z0-9_]+', pattern)
                self.patterns.append((re.compile('^' + pattern + '$'), labels))
                continue
            self.exact.setdefault(family, set()).update(labels)
            if cells[2] == 'histogram':
                for suffix in ('_bucket', '_sum', '_count'):
                    self.exact.setdefault(family + suffix, set()).update(labels - {'le'} if suffix != '_bucket' else labels)

    def labels(self, name):
        """The labels of family `name`, or None where it is not one."""
        if name in SCRAPE_SERIES:
            return set()
        if name in self.exact:
            return self.exact[name]
        for pattern, labels in self.patterns:
            if pattern.match(name):
                return labels
        return None


def tokens(expr):
    out = []
    for m in TOKEN.finditer(expr):
        kind = m.lastgroup
        if kind == 'space':
            continue
        out.append((kind, m.group(kind)))
    rest = TOKEN.sub('', expr).strip()
    if rest:
        raise ValueError(f'cannot read {rest!r}')
    return out


def unquote(s):
    return s[1:-1]


def scan(expr):
    """The selectors (name, [matcher labels]), the grouping labels, the labels
    read and the labels made of an expression."""
    toks = tokens(expr)
    selectors, grouping, read, made = [], set(), set(), set()
    i = 0
    while i < len(toks):
        kind, text = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else (None, None)
        if kind == 'ident' and text in GROUPING and nxt[1] == '(':
            j = i + 2
            while toks[j][1] != ')':
                if toks[j][0] == 'ident':
                    grouping.add(toks[j][1])
                j += 1
            i = j + 1
            continue
        if kind == 'ident' and text in ('label_replace', 'label_join') and nxt[1] == '(':
            # The string arguments: label_replace(v, dst, repl, src, regex),
            # label_join(v, dst, sep, src...).
            depth, j, strings = 0, i + 1, []
            while True:
                k, t = toks[j]
                if t == '(':
                    depth += 1
                elif t == ')':
                    depth -= 1
                    if depth == 0:
                        break
                elif k == 'string' and depth == 1:
                    strings.append(unquote(t))
                j += 1
            if strings:
                made.add(strings[0])
                src = strings[2:3] if text == 'label_replace' else strings[2:]
                read.update(s for s in src if s)
            i += 2  # the arguments are scanned as any expression
            continue
        if kind == 'ident' and (nxt[1] == '(' or text in AGGREGATIONS):
            i += 1  # a function or an aggregation
            continue
        if kind == 'ident' and text.lower() in KEYWORDS:
            i += 1
            continue
        if kind == 'ident' or (kind == 'op' and text == '{'):
            name = text if kind == 'ident' else None
            matchers = []
            j = i + 1 if kind == 'ident' else i
            if j < len(toks) and toks[j][1] == '{':
                j += 1
                while toks[j][1] != '}':
                    if toks[j][0] in ('ident', 'string') and toks[j + 1][1] in ('=', '!=', '=~', '!~'):
                        label = toks[j][1] if toks[j][0] == 'ident' else unquote(toks[j][1])
                        value = unquote(toks[j + 2][1])
                        if label == '__name__':
                            name = value
                        else:
                            matchers.append(label)
                        j += 3
                    elif toks[j][0] == 'string':
                        name = unquote(toks[j][1])  # {"name"}, the UTF-8 form
                        j += 1
                    else:
                        j += 1
                j += 1
            selectors.append((name, matchers))
            i = j
            continue
        i += 1
    return selectors, grouping, read, made


def check_expr(ref, expr, where, legend=None):
    errors = []
    expr = DURATION_VARS.sub('5m', expr)
    expr = OTHER_VARS.sub('x', expr)
    try:
        selectors, grouping, read, made = scan(expr)
    except (ValueError, IndexError) as e:
        return [f'{where}: cannot read the expression: {e}']
    known = set(TARGET_LABELS) | made
    for name, matchers in selectors:
        labels = ref.labels(name) if name else None
        if name is None:
            continue
        if labels is None:
            errors.append(f'{where}: {name} is not a family of docs/reference/metrics.md')
            continue
        known |= labels
        for label in matchers:
            if label not in labels | TARGET_LABELS:
                errors.append(f'{where}: {name} has no label {label}')
    if not any(ref.labels(n) is not None for n, _ in selectors if n):
        return errors  # nothing known to check the rest against
    for label in sorted(grouping | read | set(LEGEND_LABEL.findall(legend or ''))):
        if label not in known:
            errors.append(f'{where}: no family of the expression has label {label}')
    return errors


def series_selector(ref, series, where):
    """A test's input series, `name{label="value", ...}`."""
    return check_expr(ref, series, where)


def walk(node, path=''):
    if isinstance(node, dict):
        yield path, node
        for k, v in node.items():
            yield from walk(v, f'{path}.{k}' if path else str(k))
    elif isinstance(node, list):
        for n, v in enumerate(node):
            yield from walk(v, f'{path}[{n}]')


def check_rules(ref, doc, name):
    errors = []
    for group in doc.get('groups') or []:
        for rule in group.get('rules') or []:
            what = rule.get('alert') or rule.get('record')
            where = f'{name}: {what}'
            errors += check_expr(ref, rule['expr'], where)
            # A query an annotation runs: printf's `...`, its %s a value.
            for text in (rule.get('annotations') or {}).values():
                for q in re.findall(r'`([^`]*\{[^`]*)`', text):
                    if '%s' in q:
                        errors += check_expr(ref, q.replace('%s', 'x'), f'{where} (annotation)')
    return errors


def check_tests(ref, doc, name):
    errors = []
    for n, test in enumerate(doc.get('tests') or []):
        for s in test.get('input_series') or []:
            errors += series_selector(ref, s['series'], f'{name}: test {n + 1}')
        for t in test.get('promql_expr_test') or []:
            errors += check_expr(ref, t['expr'], f'{name}: test {n + 1}')
    return errors


def grafana_shape(doc, name):
    """What makes a Grafana dashboard importable anywhere: its datasource a
    variable, which every panel and query uses, and panels that fit the grid."""
    errors = []
    variables = {v.get('name'): v for v in (doc.get('templating') or {}).get('list') or []}
    if (variables.get('datasource') or {}).get('type') != 'datasource':
        errors.append(f'{name}: no datasource variable')
    if not isinstance(doc.get('schemaVersion'), int) or not doc.get('uid'):
        errors.append(f'{name}: no schemaVersion or uid')
    ids = set()
    for path, node in walk(doc.get('panels') or [], 'panels'):
        if 'gridPos' in node:
            g = node['gridPos']
            if node.get('id') in ids:
                errors.append(f'{name}: {path}: id {node.get("id")} again')
            ids.add(node.get('id'))
            if g['x'] + g['w'] > 24:
                errors.append(f'{name}: {path}: past the grid\'s 24 columns')
        ds = node.get('datasource')
        if isinstance(ds, dict) and ds.get('uid') != '${datasource}':
            errors.append(f'{name}: {path}: datasource {ds.get("uid")} is not the variable')
    return errors


def check_grafana(ref, doc, name):
    errors = grafana_shape(doc, name)
    for path, node in walk(doc):
        if 'expr' in node and isinstance(node['expr'], str):
            errors += check_expr(ref, node['expr'], f'{name}: {path}', node.get('legendFormat'))
        if node.get('type') == 'query' and 'query' in node:
            q = node['query']['query'] if isinstance(node['query'], dict) else node['query']
            m = re.match(r'^\s*label_values\((.*),\s*(\w+)\s*\)\s*$', q)
            if m:
                errors += check_expr(ref, f'count by ({m.group(2)}) ({m.group(1)})', f'{name}: variable {node.get("name")}')
            else:
                errors += check_expr(ref, q, f'{name}: variable {node.get("name")}')
    return errors


def check_perses(ref, doc, name):
    errors = []
    for path, node in walk(doc):
        if node.get('kind') == 'PrometheusTimeSeriesQuery':
            spec = node.get('spec') or {}
            errors += check_expr(ref, spec['query'], f'{name}: {path}', spec.get('seriesNameFormat'))
        elif node.get('kind') == 'PrometheusLabelValuesVariable':
            spec = node.get('spec') or {}
            for m in spec.get('matchers') or ['up']:
                errors += check_expr(ref, f'count by ({spec["labelName"]}) ({m})', f'{name}: {path}')
        elif node.get('kind') == 'PrometheusPromQLVariable':
            spec = node.get('spec') or {}
            errors += check_expr(ref, spec['expr'], f'{name}: {path}')
    return errors


def check_file(ref, path):
    name = str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)
    if path.suffix == '.json':
        return check_grafana(ref, json.loads(path.read_text()), name)
    doc = yaml.safe_load(path.read_text())
    if 'groups' in doc:
        return check_rules(ref, doc, name)
    if 'tests' in doc:
        return check_tests(ref, doc, name)
    return check_perses(ref, doc, name)


def main(argv):
    ref = Reference(REFERENCE)
    monitoring = ROOT / 'monitoring'
    files = [Path(a).resolve() for a in argv] or sorted(
        p for p in monitoring.rglob('*') if p.suffix in ('.yml', '.yaml', '.json'))
    errors = []
    for path in files:
        errors += check_file(ref, path)
    for e in errors:
        print(e, file=sys.stderr)
    if not errors:
        print(f'{len(files)} files name only metrics and labels of docs/reference/metrics.md')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
