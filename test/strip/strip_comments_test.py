#!/usr/bin/env python3
"""Tests of devenv/scripts/strip-comments.py; devenv/scripts/strip-check.sh runs them."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, '..', '..', 'devenv', 'scripts', 'strip-comments.py')

spec = importlib.util.spec_from_file_location('strip_comments', SCRIPT)
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)


class Comments(unittest.TestCase):
    def test_a_line_comment_and_the_spaces_before_it(self):
        self.assertEqual(sc.strip('let a = 1;   // one\nlet b;\n'), 'let a = 1;\nlet b;\n')

    def test_a_comment_line_becomes_an_empty_line(self):
        self.assertEqual(sc.strip('\t// a\n\t// b\nx;\n'), '\n\nx;\n')

    def test_a_block_comment_keeps_its_newlines(self):
        self.assertEqual(sc.strip('/**\n * Doc.\n *\n * @param {int} a\n */\nexport function f(a) {};\n'),
                         '\n\n\n\n\nexport function f(a) {};\n')

    def test_an_indented_block_comment_leaves_no_spaces(self):
        self.assertEqual(sc.strip('{\n\t/* a\n\t   b */\n\tx;\n}\n'), '{\n\n\n\tx;\n}\n')

    def test_a_block_comment_between_tokens_parts_them(self):
        self.assertEqual(sc.strip('a/**/b'), 'a b')
        self.assertEqual(sc.strip('a /* x */ b'), 'a b')
        self.assertEqual(sc.strip('a /* x */b'), 'a b')
        self.assertEqual(sc.strip('\t/* x */ b'), '\tb')

    def test_a_block_comment_whose_code_follows_on_its_last_line(self):
        self.assertEqual(sc.strip('/* a\n */ x;\n'), '\n x;\n')

    def test_a_comment_at_the_end_without_a_newline(self):
        self.assertEqual(sc.strip('x; // end'), 'x;')

    def test_an_empty_block_comment_is_not_closed_by_its_opening_star(self):
        self.assertEqual(sc.strip('a /**/ b /*/ still */ c'), 'a b c')

    def test_no_comment_is_unchanged(self):
        text = "'use strict';\n\nexport const A = 1;\n"
        self.assertEqual(sc.strip(text), text)


class Strings(unittest.TestCase):
    def test_comment_markers_in_strings_stay(self):
        text = "let a = '// no', b = \"/* no */\", c = 'it\\'s // no';\n"
        self.assertEqual(sc.strip(text), text)

    def test_a_string_over_lines(self):
        text = "let a = 'one\n// two';\n"
        self.assertEqual(sc.strip(text), text)

    def test_a_template_literal(self):
        text = 'let a = `// ${b /* c */} /* d */ ${ `x${ {e: 1}["e"] // f\n}` }`;\n'
        self.assertEqual(sc.strip(text), 'let a = `// ${b } /* d */ ${ `x${ {e: 1}["e"]\n}` }`;\n')

    def test_an_escaped_backtick_and_dollar(self):
        text = 'let a = `\\` \\${ // }`; // c\n'
        self.assertEqual(sc.strip(text), 'let a = `\\` \\${ // }`;\n')

    def test_a_string_that_does_not_end(self):
        self.assertRaises(sc.StripError, sc.strip, "let a = 'x;\n")


class Regexps(unittest.TestCase):
    def test_comment_markers_in_a_regexp_stay(self):
        text = "let a = /\\/\\/ x/g, b = /[/*]/, c = /a\\/*b/;\n"
        self.assertEqual(sc.strip(text), text)

    def test_a_regexp_after_words_and_punctuators(self):
        for before in ('return', '(', ',', '=', ':', '[', '!', '&&', '?', ';', '{', 'typeof', 'case'):
            text = '%s /[/]// x/ // c\n' % before
            self.assertEqual(sc.strip(text), '%s /[/]// x/\n' % before)

    def test_a_division_is_no_regexp(self):
        for before in ('a', '1', ')', ']', 'a++', "'s'"):
            text = '%s / 2 / 3; // c\n' % before
            self.assertEqual(sc.strip(text), '%s / 2 / 3;\n' % before)
        self.assertEqual(sc.strip('a /= 2; // c\n'), 'a /= 2;\n')

    def test_a_bracket_expression_with_a_bracket_first_or_a_class(self):
        text = 'let a = /[]/]x/, b = /[^]/]/, c = /[[:alpha:]/]/; // c\n'
        self.assertEqual(sc.strip(text), 'let a = /[]/]x/, b = /[^]/]/, c = /[[:alpha:]/]/;\n')

    def test_a_regexp_that_does_not_end(self):
        self.assertRaises(sc.StripError, sc.strip, 'let a = /x\n/;\n')


class Files(unittest.TestCase):
    def test_a_shebang_stays(self):
        self.assertEqual(sc.strip('#!/usr/bin/ucode\n// c\nx;\n'), '#!/usr/bin/ucode\n\nx;\n')

    def test_ucode_template_mode(self):
        text = "{%\n'use strict';\n// c\nlet a = 1; /* d */\n-%}\ntext // not a comment\n{{ a /* e */ }}\n"
        self.assertEqual(sc.strip(text), "{%\n'use strict';\n\nlet a = 1;\n-%}\ntext // not a comment\n{{ a }}\n")

    def test_a_block_that_does_not_end(self):
        self.assertRaises(sc.StripError, sc.strip, '{% x;\n')

    def test_a_comment_that_does_not_end(self):
        self.assertRaises(sc.StripError, sc.strip, 'x; /* y\n')

    def test_in_place_and_to_standard_output(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'a.uc')
            with open(path, 'w') as f:
                f.write('x; // c\n')
            out = subprocess.run([sys.executable, SCRIPT, path], stdout=subprocess.PIPE, check=True).stdout
            self.assertEqual(out, b'x;\n')
            subprocess.run([sys.executable, SCRIPT, '-i', path], check=True)
            with open(path) as f:
                self.assertEqual(f.read(), 'x;\n')

    def test_a_file_it_cannot_strip_fails_the_run(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'a.uc')
            with open(path, 'w') as f:
                f.write("x = 'y;\n")
            run = subprocess.run([sys.executable, SCRIPT, '-i', path], stderr=subprocess.PIPE)
            self.assertEqual(run.returncode, 1)
            self.assertIn(b'a string that does not end', run.stderr)
            with open(path) as f:
                self.assertEqual(f.read(), "x = 'y;\n")


if __name__ == '__main__':
    unittest.main()
