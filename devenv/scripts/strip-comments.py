#!/usr/bin/env python3
"""Removes the comments of ucode and JavaScript sources, keeping every line.

The package build runs it on the .uc and .js files it installs
(openwrt/ucode-prometheus-exporter/Makefile), so a device gets no comments,
and an error's line number on a device is the line in the repository.

    strip-comments.py -i FILE...    rewrite each FILE in place
    strip-comments.py FILE          write FILE stripped to standard output

It lexes as ucode does: strings, template literals and their ${}, regular
expression literals, and ucode's template mode ({% %} and {{ }} blocks, for
a file that starts with one). Every newline of a comment is kept; spaces left
at the end of a line by a comment go with it. A source that ends inside a
string, a comment, a regular expression or a block is refused (exit 1).
test/strip/strip_comments_test.py tests it; make test also checks that every
installed file, stripped, compiles to the same bytecode as its source.
Python 3.6 and later, standard library only: OpenWrt's build host has it.
"""

import sys

# After these words an expression starts, so a '/' begins a regular expression.
BEFORE_EXPRESSION = frozenset((
    'return', 'typeof', 'instanceof', 'in', 'of', 'case', 'delete', 'void', 'throw', 'else', 'do', 'new',
    'yield', 'await', 'export', 'default',
))

# After these a '/' divides.
BEFORE_DIVISION = frozenset((')', ']', '}', '++', '--'))


class StripError(Exception):
    pass


def _word_char(c):
    return c.isalnum() or c in '_$'


class _Stripper:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.out = []
        # The token before: None at the start, ('word', w), ('value',) or ('punct', p).
        self.prev = None

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < len(self.s) else ''

    def emit(self, text):
        self.out.append(text)

    def last_out(self):
        for chunk in reversed(self.out):
            if chunk:
                return chunk[-1]
        return ''

    def rstrip_out(self):
        """Drops the spaces and tabs at the end of the output."""
        while self.out:
            chunk = self.out[-1].rstrip(' \t')
            if chunk:
                self.out[-1] = chunk
                return
            self.out.pop()

    def regex_allowed(self):
        p = self.prev
        if p is None:
            return True
        if p[0] == 'value':
            return False
        if p[0] == 'word':
            return p[1] in BEFORE_EXPRESSION
        return p[1] not in BEFORE_DIVISION

    # ---- comments ----

    def line_comment(self):
        end = self.s.find('\n', self.i)
        self.i = len(self.s) if end < 0 else end
        self.rstrip_out()

    def block_comment(self):
        end = self.s.find('*/', self.i + 2)
        if end < 0:
            raise StripError('a comment that does not end, from offset %d' % self.i)
        newlines = self.s.count('\n', self.i, end)
        self.i = end + 2
        rest = self.i
        while rest < len(self.s) and self.s[rest] in ' \t':
            rest += 1
        at_eol = rest >= len(self.s) or self.s[rest] in '\r\n'
        if newlines or at_eol:
            # What is left of the lines it was on: their code, without the spaces it leaves.
            self.rstrip_out()
            self.emit('\n' * newlines)
            if at_eol:
                self.i = rest
        elif self.last_out() in (' ', '\t'):
            self.i = rest
        elif self.peek() not in (' ', '\t'):
            # A comment between two tokens parts them.
            self.emit(' ')

    # ---- literals ----

    def quoted(self, quote):
        start = self.i
        self.i += 1
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == '\\':
                self.i += 2
                continue
            self.i += 1
            if c == quote:
                self.emit(self.s[start:self.i])
                self.prev = ('value',)
                return
        raise StripError('a string that does not end, from offset %d' % start)

    def regex(self):
        """A regular expression literal: as ucode's lexer reads one, a ']' first
        in a bracket expression and a [:class:] in one are no end of it."""
        s = self.s
        start = self.i
        self.i += 1
        while self.i < len(s):
            c = s[self.i]
            if c == '\\':
                self.i += 2
                continue
            if c == '\n':
                break
            self.i += 1
            if c == '[':
                self._bracket()
            elif c == '/':
                while self.i < len(s) and _word_char(s[self.i]):
                    self.i += 1
                self.emit(s[start:self.i])
                self.prev = ('value',)
                return
        raise StripError('a regular expression that does not end, from offset %d' % start)

    def _bracket(self):
        s = self.s
        if self.peek() == '^':
            self.i += 1
        if self.peek() == ']':
            self.i += 1
        while self.i < len(s):
            c = s[self.i]
            if c == '\\':
                self.i += 2
                continue
            self.i += 1
            if c == ']':
                return
            if c == '[' and self.peek() in (':', '.', '='):
                end = s.find(self.peek() + ']', self.i + 1)
                if end < 0:
                    break
                self.i = end + 2
        raise StripError('a bracket expression that does not end, before offset %d' % self.i)

    def template_literal(self):
        """From a ` to its closing `, each ${...} in it lexed as code."""
        start = self.i
        chunk = self.i
        self.i += 1
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == '\\':
                self.i += 2
                continue
            if c == '`':
                self.i += 1
                self.emit(self.s[chunk:self.i])
                self.prev = ('value',)
                return
            if c == '$' and self.peek(1) == '{':
                self.i += 2
                self.emit(self.s[chunk:self.i])
                self.prev = ('punct', '{')
                self.code(close='}')
                chunk = self.i
                self.i += 1
                continue
            self.i += 1
        raise StripError('a template literal that does not end, from offset %d' % start)

    # ---- code ----

    def code(self, close=None, block_end=None):
        """Code up to `close` at depth 0 (not consumed), or to `block_end`
        (ucode's %} or }}, not consumed), or to the end of the text."""
        depth = 0
        s = self.s
        while self.i < len(s):
            c = s[self.i]

            if block_end and depth == 0 and s.startswith(block_end, self.i):
                return
            if block_end == '%}' and c == '-' and s.startswith('-%}', self.i):
                return

            if c in ' \t\r\n\f\v':
                self.emit(c)
                self.i += 1
                continue

            if c == '/':
                n = self.peek(1)
                if n == '/':
                    self.line_comment()
                    continue
                if n == '*':
                    self.block_comment()
                    continue
                if self.regex_allowed():
                    self.regex()
                    continue
                if n == '=':
                    self.emit('/=')
                    self.i += 2
                else:
                    self.emit('/')
                    self.i += 1
                self.prev = ('punct', '/')
                continue

            if c in '\'"':
                self.quoted(c)
                continue

            if c == '`':
                self.template_literal()
                continue

            if c.isdigit() or (c == '.' and self.peek(1).isdigit()):
                j = self.i + 1
                while j < len(s) and (_word_char(s[j]) or s[j] == '.'):
                    j += 1
                self.emit(s[self.i:j])
                self.i = j
                self.prev = ('value',)
                continue

            if _word_char(c):
                j = self.i + 1
                while j < len(s) and _word_char(s[j]):
                    j += 1
                w = s[self.i:j]
                self.emit(w)
                self.i = j
                self.prev = ('word', w) if w in BEFORE_EXPRESSION else ('value',)
                continue

            if c in '{([':
                if c == '{':
                    depth += 1
                self.emit(c)
                self.i += 1
                self.prev = ('punct', c)
                continue

            if c == '}':
                if depth == 0 and close == '}':
                    return
                depth -= 1
                self.emit(c)
                self.i += 1
                self.prev = ('punct', c)
                continue

            for p in ('++', '--'):
                if s.startswith(p, self.i):
                    break
            else:
                p = c
            self.emit(p)
            self.i += len(p)
            self.prev = ('punct', p)

        if close is not None:
            raise StripError('a ${...} that does not end')

    def template_mode(self):
        """ucode's template mode: text, and {% %} and {{ }} blocks of code."""
        s = self.s
        while self.i < len(s):
            j_stmt = s.find('{%', self.i)
            j_expr = s.find('{{', self.i)
            starts = [j for j in (j_stmt, j_expr) if j >= 0]
            if not starts:
                self.emit(s[self.i:])
                self.i = len(s)
                return
            j = min(starts)
            end = '%}' if j == j_stmt else '}}'
            k = j + 2
            if k < len(s) and s[k] in '-+':
                k += 1
            self.emit(s[self.i:k])
            self.i = k
            self.prev = None
            self.code(block_end=end)
            if self.i >= len(s):
                raise StripError('a %s block that does not end' % s[j:j + 2])
            if end == '%}' and s.startswith('-%}', self.i):
                end = '-%}'
            self.emit(end)
            self.i += len(end)

    def run(self):
        s = self.s
        if s.startswith('#!'):
            end = s.find('\n')
            end = len(s) if end < 0 else end
            self.emit(s[:end])
            self.i = end
        if s[self.i:].lstrip().startswith(('{%', '{{')):
            self.template_mode()
        else:
            self.code()
        return ''.join(self.out)


def strip(text):
    """`text` without its comments, with as many lines."""
    out = _Stripper(text).run()
    if out.count('\n') != text.count('\n'):
        raise StripError('the lines changed: %d, %d stripped' % (text.count('\n'), out.count('\n')))
    return out


def main(argv):
    in_place = False
    args = argv[1:]
    if args and args[0] == '-i':
        in_place = True
        args = args[1:]
    if not args or (not in_place and len(args) != 1):
        sys.stderr.write('usage: strip-comments.py -i FILE... | strip-comments.py FILE\n')
        return 2
    for path in args:
        with open(path, encoding='utf-8', newline='') as f:
            text = f.read()
        try:
            out = strip(text)
        except StripError as e:
            sys.stderr.write('strip-comments.py: %s: %s\n' % (path, e))
            return 1
        if in_place:
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.write(out)
        else:
            sys.stdout.write(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
