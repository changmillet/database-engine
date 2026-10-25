#!/usr/bin/env python3
"""Offline admission, ordering and cleanup boundaries for the CAS collector."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
SOURCE = Path(__file__).with_name('collect_portal_flow_cas_cutover.py')
SPEC = importlib.util.spec_from_file_location('portal_cas_cutover_collector', SOURCE)
assert SPEC and SPEC.loader
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
u = collector.upgrade


class CutoverCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, source, cls.phases = u.load_candidate(u.CAS_BASE, None)
        cls.predecessor = collector.bench.baseline(u.CAS_BASE, list(collector.bench.reader_definitions(source)))

    def test_canonical_admission_requires_ledger_bodies_empty_local_schema(self):
        sql = collector.canonical_guard(self.predecessor)
        self.assertEqual(len(u.split_statements(sql)), 1)
        self.assertIn("is distinct from '20261025052607'", sql)
        self.assertIn("inet_server_addr() is not null", sql)
        self.assertIn("current_setting('server_version')<>'17.11'", sql)
        self.assertIn('Canonical Main predecessor routine bodies differ', sql)
        self.assertIn("attname='cas_number'", sql)
        for table in collector.bench.TABLES:
            self.assertIn('exists(select 1 from ' + table + ')', sql)

    def test_phase_gates_follow_unchanged_product_ddl_and_precede_commit(self):
        c = object.__new__(collector.Collector)
        for phase, statements in (('A', self.phases.prepare), ('B', self.phases.activate)):
            sql = c.phase_sql(phase, statements, 123456)
            parsed = [u.statement_code(s) for s in u.split_statements(sql)]
            self.assertEqual(parsed[0], 'begin;')
            self.assertEqual(parsed[-2], 'commit;')
            self.assertIn(phase + '_COMMITTED:', parsed[-1])
            self.assertIn('pg_advisory_xact_lock(869,123456)', parsed[-3])
            self.assertEqual(sql.count("set local lock_timeout='5s'"), 1)
            self.assertEqual(sql.count("set local statement_timeout='60s'"), 1)
            for statement in statements:
                self.assertIn(statement, sql)

    def test_source_writer_marker_works_before_native_column_exists(self):
        c = object.__new__(collector.Collector)
        c.transcript = []
        session = Mock()
        c.source_writer(session, 'SOURCE', collector.TARGET_ONE, '64-17-5', 123456)
        sql = session.send.call_args[0][0]
        self.assertIn("to_jsonb(n)->>'cas_number'", sql)
        self.assertIn('SOURCE_MUTATED:', sql)
        self.assertIn("set local lock_timeout='5s'", sql)
        self.assertEqual(len(u.split_statements(sql)), 8)

    def test_cost_is_rollback_only_and_uses_statement_wal(self):
        sql = collector.cost_sql(self.predecessor, self.phases, 3)
        parsed = [u.statement_code(s) for s in u.split_statements(sql)]
        self.assertEqual(parsed[0], 'begin;')
        self.assertEqual(parsed[-1], 'rollback;')
        self.assertNotIn('commit;', parsed)
        self.assertIn('explain (analyze,buffers,wal,format json)', sql)
        self.assertNotIn('pg_current_wal', sql)
        self.assertNotIn('pg_wal_lsn_diff', sql)
        self.assertEqual(sql.count('select pg_temp.measure_writer('), 24)
        self.assertIn('Real writer operation affected unexpected rows', sql)
        self.assertIn('Real writer cost operation rollback leaked logical data', sql)

    def test_cleanup_targets_only_exact_owned_application_and_pid(self):
        c = object.__new__(collector.Collector)
        c.prefix = 'portal869-cutover-example-'
        c.pids = {'worker': 123}
        c.report = {}
        c.util_original = None
        c.brand_original = None
        session = Mock()
        session.application = c.prefix + 'worker'
        session.process.poll.return_value = None
        c.sessions = [session]
        c.call = Mock(return_value=[{'terminated': True}])
        c.cleanup_sessions()
        sql = c.call.call_args[0][1]
        self.assertIn("application_name='portal869-cutover-example-worker' and pid=123", sql)
        self.assertNotIn(' like ', sql.lower())
        session.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
