#!/usr/bin/env python3
"""Tests of extract-forms.py: python3 tools/test_extract_forms.py"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "extract_forms", os.path.join(HERE, "extract-forms.py"))
ef = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ef)


def copy(text, mode="--except", wanted="-"):
    return ef.extract(text, "f.lisp", "abc1234", mode, wanted)[0]


class FormSpans(unittest.TestCase):
    def test_plain_forms(self):
        self.assertEqual(ef.form_spans("(a)\n\n(b\n c)\n"), [(1, 1), (3, 4)])

    def test_backslash_outside_a_string_escapes_the_next_char(self):
        text = "(defun a () '|x| 'foo\\( #\\( #\\) \\;)\n(defun b ())\n"
        self.assertEqual(ef.form_spans(text), [(1, 1), (2, 2)])

    def test_strings_and_block_comments_hide_parens(self):
        text = '(a "( \\" (")\n#| ( #| ) |# |#\n(b)\n'
        self.assertEqual(ef.form_spans(text), [(1, 1), (3, 3)])

    def test_feature_expression_starts_the_form(self):
        text = "#+(or sbcl ccl)\n(a)\n#-ecl #+sbcl\n(b)\n"
        self.assertEqual(ef.form_spans(text), [(1, 2), (3, 4)])

    def test_an_atom_after_a_feature_is_a_form(self):
        text = "#+sbcl foo\n(a)\n#+ccl \"doc\"\n(b)\n#+ecl #\\x\n(c)\n"
        self.assertEqual(ef.form_spans(text),
                         [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6)])

    def test_prefixes_belong_to_their_form(self):
        text = "'(a)\n#'(lambda ())\n#.(b)\n#x1F\n(c)\n"
        self.assertEqual(ef.form_spans(text),
                         [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5)])

    def test_two_forms_on_one_line_is_an_error(self):
        with self.assertRaisesRegex(ef.FormError, "two forms on one line"):
            ef.form_spans("(a)\n(b) (c)\n")

    def test_a_form_open_at_the_end_is_an_error(self):
        with self.assertRaisesRegex(ef.FormError, "line 2: form still open"):
            ef.form_spans("(a)\n(b\n (c)\n")
        with self.assertRaisesRegex(ef.FormError, "unmatched"):
            ef.form_spans("(a))\n")
        with self.assertRaisesRegex(ef.FormError, "without"):
            ef.form_spans('(a "b)\n')
        with self.assertRaisesRegex(ef.FormError, "without"):
            ef.form_spans("(a) #| b\n")


class Extract(unittest.TestCase):
    TEXT = ("(in-package :graph-db)\n\n"
            ";;;; Header line one.\n;;;; Header line two.\n\n"
            "(defvar *a* 1)\n\n"
            ";;; ---- section ----\n\n"
            ";; Above b.\n(defun b ())\n\n(defun c ())\n")

    def test_a_mode_other_than_only_and_except_is_an_error(self):
        with self.assertRaisesRegex(ef.FormError, "mode '--all'"):
            copy(self.TEXT, "--all", "-")

    def test_a_line_that_is_not_a_form_start_is_an_error(self):
        with self.assertRaisesRegex(ef.FormError, r"not form starts: \[7\]"):
            copy(self.TEXT, "--only", "7")

    def test_only_keeps_named_forms_with_their_comments(self):
        out = copy(self.TEXT, "--only", "11")
        self.assertIn(";; Above b.\n(defun b ())\n", out)
        self.assertNotIn("defvar", out)
        self.assertNotIn("defun c", out)
        self.assertNotIn("section", out)

    def test_except_drops_named_forms(self):
        out = copy(self.TEXT, "--except", "6,13")
        self.assertIn("(defun b ())", out)
        self.assertNotIn("defvar", out)
        self.assertNotIn("defun c", out)

    def test_in_package_is_replaced(self):
        out = copy(self.TEXT)
        self.assertNotIn("graph-db)", out)
        self.assertTrue(out.startswith(
            ";;;; Copied from vivace-graph f.lisp at abc1234 (--except -).\n"
            ";;;; See docs/provenance.md.\n\n(in-package #:vivace-cabinet)\n"))

    def test_the_header_comment_is_kept_in_every_mode(self):
        header = ";;;; Header line one.\n;;;; Header line two.\n"
        for mode, wanted in (("--except", "-"), ("--only", "13"),
                             ("--except", "6")):
            self.assertIn("\n\n" + header + "\n", copy(self.TEXT, mode, wanted))

    def test_a_whole_file_copy_keeps_free_standing_comments(self):
        out = copy(self.TEXT)
        self.assertIn("(defvar *a* 1)\n\n;;; ---- section ----\n\n"
                      ";; Above b.\n(defun b ())\n\n(defun c ())\n", out)
        self.assertNotIn(";;; ---- section", copy(self.TEXT, "--except", "6"))


if __name__ == "__main__":
    unittest.main()
