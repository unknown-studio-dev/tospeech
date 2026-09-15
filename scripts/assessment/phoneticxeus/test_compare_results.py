import copy
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout

from compare_results import main

# Two fixtures shaped like a probe result JSON: one pair identical, one pair differing in a single
# phone. Only the fields the comparison reads are populated.
IDENTICAL = {
    "id": "11111111-1111-1111-1111-111111111111",
    "provenance": "PhoneticXeus · runtime aaaa",
    "result": {
        "words": [{
            "target": {"id": "caption-0-word-0"},
            "phones": [
                {"quality": "correct", "kind": "matched", "expected": "əʊ", "observed": "əʊ",
                 "unassessedReason": None},
                {"quality": "unassessed", "kind": "uncertain", "expected": "k", "observed": "g",
                 "unassessedReason": "referenceUnmapped"},
            ]}],
        "phoneticXeus": {
            "words": [{
                "id": "caption-0-word-0",
                "phones": [
                    {"expected": "əʊ", "status": "correct", "reason": None, "licence": "classD",
                     "contrast": {"decision": "uk", "pUK": 0.9, "name": "GOAT"}},
                    {"expected": "k", "status": "uncertain", "reason": "referenceUnmapped",
                     "licence": "unmapped"},
                ]}]},
    },
}


class CompareResultsTests(unittest.TestCase):
    def run_main(self, a, b):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name, document in (("a.json", a), ("b.json", b)):
                path = os.path.join(directory, name)
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump(document, handle)
                paths.append(path)
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = main(paths)
            return code, buffer.getvalue()

    def test_identical_results_report_the_count_table_and_exit_zero(self):
        other = copy.deepcopy(IDENTICAL)
        # Labels that legitimately move between runs must not count as a difference.
        other["id"] = "22222222-2222-2222-2222-222222222222"
        other["provenance"] = "PhoneticXeus · runtime bbbb"
        code, output = self.run_main(IDENTICAL, other)
        self.assertEqual(code, 0)
        self.assertIn("1 / 0 / 0 / 1 (correct/nearCorrect/incorrect/unassessed) over 2 phones", output)
        self.assertIn("display IDENTICAL (2 phones)", output)
        self.assertIn("xeus IDENTICAL (2 rows)", output)
        self.assertTrue(output.strip().endswith("IDENTICAL"))

    def test_one_differing_phone_is_named_and_exits_one(self):
        other = copy.deepcopy(IDENTICAL)
        other["result"]["words"][0]["phones"][1]["quality"] = "incorrect"
        other["result"]["words"][0]["phones"][1]["kind"] = "substitution"
        code, output = self.run_main(IDENTICAL, other)
        self.assertEqual(code, 1)
        self.assertIn("display DIFFERENT — word 0 (caption-0-word-0) phone 1", output)
        self.assertIn("xeus IDENTICAL", output)
        self.assertTrue(output.strip().endswith("DIFFERENT"))

    def test_two_empty_documents_are_not_reported_as_identical(self):
        # Zero phones on both sides compares equal; a renamed key or a truncated file must not read
        # as "nothing changed".
        code, output = self.run_main({}, {})
        self.assertEqual(code, 1)
        self.assertIn("NO PHONES FOUND", output)
        self.assertNotIn("IDENTICAL", output)
        self.assertTrue(output.strip().endswith("NO PHONES FOUND"))

    def test_one_empty_side_is_not_reported_as_identical(self):
        code, output = self.run_main(IDENTICAL, {"result": {"words": [], "phoneticXeus": {}}})
        self.assertEqual(code, 1)
        self.assertIn("NO PHONES FOUND", output)

    def test_a_raw_xeus_only_difference_is_caught(self):
        other = copy.deepcopy(IDENTICAL)
        other["result"]["phoneticXeus"]["words"][0]["phones"][0]["contrast"]["decision"] = "ambiguous"
        code, output = self.run_main(IDENTICAL, other)
        self.assertEqual(code, 1)
        self.assertIn("display IDENTICAL", output)
        self.assertIn("xeus DIFFERENT — word 0 (caption-0-word-0) phone 0", output)


if __name__ == "__main__":
    unittest.main()
