"""Correctness-comparison and validation-only ordering behavior."""

import importlib
import sys
import unittest
from decimal import Decimal
from pathlib import Path

import duckdb


class BaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parent
        sys.path.insert(0, str(root))
        cls.baseline = importlib.import_module("baseline")
        sys.path.pop(0)

    def test_multiset_preserves_duplicates_and_numeric_values(self):
        compare = self.baseline.same_rows
        self.assertTrue(
            compare([(1, 2.0), (1, 2.0)], [(Decimal(1), 2.00000000001)] * 2)
        )
        self.assertFalse(compare([(1,), (1,)], [(1,), (2,)]))
        self.assertFalse(compare([(9007199254740993,)], [(9007199254740992,)]))

    def test_validation_order_resolves_limit_ties_without_changing_primary_order(self):
        sql = "select a, count(*) as c from (values (3), (2), (1), (3)) t(a) group by a order by c desc limit 2;"
        query = self.baseline.ordered_validation_sql(sql, 2)
        with duckdb.connect() as connection:
            self.assertEqual(connection.execute(query).fetchall(), [(3, 2), (1, 1)])
            query = self.baseline.ordered_validation_sql(
                "select a from (values (3), (2), (1)) t(a) limit 1 offset 1;", 1
            )
            self.assertEqual(connection.execute(query).fetchall(), [(2,)])

    def test_nonlimit_difference_requires_investigation(self):
        with self.assertRaises(ValueError):
            self.baseline.ordered_validation_sql("select count(*) from hits;", 1)


if __name__ == "__main__":
    unittest.main()
