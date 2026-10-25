#!/usr/bin/env python3
"""Offline scope/order checks for the independent native CAS DDL collector."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
SOURCE=Path(__file__).with_name('collect_portal_flow_cas_ddl_fence.py')
SPEC=importlib.util.spec_from_file_location('portal_cas_ddl_collector',SOURCE)
assert SPEC and SPEC.loader
collector=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
u=collector.u


class DdlFenceCollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _,_,cls.phases=u.load_candidate(u.CAS_BASE,None)

    def test_actual_lock_order_and_boundary_preserve_product_b(self):
        source,nav,preflight=collector.lock_positions(self.phases.activate)
        self.assertLess(source,nav)
        self.assertLess(nav,preflight)
        sql=collector.fenced_b_sql(self.phases.activate,123456)
        self.assertLess(sql.index('DDL_B_NAV_FENCED:'),sql.index('$display_flow_cas_preflight$'))
        self.assertEqual(sql.count("set local lock_timeout='5s'"),1)
        self.assertEqual(sql.count("set local statement_timeout='60s'"),1)
        statements=[u.statement_code(s) for s in u.split_statements(sql)]
        self.assertEqual(statements[0],'begin;')
        self.assertEqual(statements[-2],'commit;')
        for statement in self.phases.activate:
            self.assertIn(statement,sql)

    def test_missing_or_reversed_source_navigation_fence_is_rejected(self):
        source,nav,_=collector.lock_positions(self.phases.activate)
        missing=[s for i,s in enumerate(self.phases.activate) if i!=nav]
        reversed_locks=list(self.phases.activate)
        reversed_locks[source],reversed_locks[nav]=reversed_locks[nav],reversed_locks[source]
        reversed_sources=list(self.phases.activate)
        reversed_sources[source]=reversed_sources[source].replace('search_rows_v1','search_rows_SWAP').replace('search_rows_v2','search_rows_v1').replace('search_rows_SWAP','search_rows_v2')
        for invalid in (missing,reversed_locks,reversed_sources):
            with self.assertRaises(ValueError):
                collector.lock_positions(invalid)

    def test_only_actual_exact_index_statement_and_cic_variant_are_used(self):
        regular=collector.exact_index_statement(self.phases.activate)
        cic=collector.exact_index_statement(self.phases.activate,True)
        self.assertIn('d807_portal_navigation_versions_flow_cas_v1_idx',regular)
        self.assertEqual(cic,regular.replace('create index','create index concurrently',1))
        with self.assertRaises(ValueError):
            collector.exact_index_statement([])
        with self.assertRaises(ValueError):
            collector.exact_index_statement([regular,regular])

    def test_cic_runs_outside_explicit_transaction_with_bounded_lock_wait(self):
        sql=collector.external_ddl_sql(self.phases.activate,True)
        self.assertTrue(sql.startswith('\\set VERBOSITY sqlstate\n'))
        parsed=[u.statement_code(s) for s in u.split_statements(sql.split('\n',1)[1])]
        self.assertNotIn('begin;',parsed)
        self.assertNotIn('commit;',parsed)
        self.assertIn("set lock_timeout='5s';",parsed)
        self.assertTrue(any(s.lower().startswith('create index concurrently if not exists') for s in parsed))

    def test_observation_binds_exact_nonce_pid_nav_lock_and_blocker(self):
        c=Mock()
        c.pids={'regular-index':111,'ddl-phase-b':222}
        c.prefix='portal869-cutover-example-'
        c.call.return_value=[{'blockingNavLock':[{'mode':'ShareRowExclusiveLock','granted':True}]}]
        collector.observe_nav_wait(c,'regular-index','ddl-phase-b','ShareLock')
        sql=c.call.call_args[0][1]
        self.assertIn('s.pid=111',sql)
        self.assertIn("s.application_name='portal869-cutover-example-regular-index'",sql)
        self.assertIn('222=any(pg_blocking_pids(s.pid))',sql)
        self.assertIn("l.relation='private.display_navigation_versions_v1'::regclass",sql)
        self.assertIn("l.mode='ShareLock' and not l.granted",sql)


if __name__=='__main__':
    unittest.main()
