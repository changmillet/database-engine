#!/usr/bin/env python3
"""Offline bounded nested WAL scope, attribution and rollback verification."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import collect_portal_flow_cas_writer_wal as c


class NestedWriterWalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _,source,cls.phases=c.upgrade.load_candidate(c.BASE,None)
        cls.predecessor=c.bench.baseline(c.BASE,list(c.bench.reader_definitions(source)))

    def event(self,bytes=100,removed=0):
        return {'durationMs':.1,'explain':{'Query Text':'insert into private.display_navigation_versions_v1 values (...) on conflict do update ...',
              'Plan':{'Node Type':'ModifyTable','Operation':'Insert','Schema':'private','Relation Name':c.RELATION,
                      'Conflict Resolution':'UPDATE','WAL Records':2,'WAL FPI':0,'WAL Bytes':bytes,
                      'Conflicting Tuples':1,'Tuples Inserted':0,'Rows Removed by Conflict Filter':removed,'Actual Loops':1,
                      'Plans':[{'WAL Bytes':999999,'WAL Records':99999}]}}}

    def test_scope_enables_logging_only_for_actual_update_and_preserves_rollback(self):
        sql=c.build_sql(self.predecessor,self.phases)
        statements=[c.upgrade.statement_code(statement) for statement in c.upgrade.split_statements(sql)]
        enabled=False;windows=0
        for statement in statements:
            if statement=='set local auto_explain.log_min_duration=0;':
                self.assertFalse(enabled);enabled=True;windows+=1
            elif statement=='set local auto_explain.log_min_duration=-1;':enabled=False
            elif enabled:
                self.assertTrue(statement.startswith('update public.flows set json='),statement)
                self.assertIn("returning jsonb_build_object('record','source-row'",statement)
                self.assertNotIn('upgrade_snapshot',statement)
        self.assertFalse(enabled)
        self.assertEqual(windows,16)
        self.assertEqual(sql.count('savepoint source_operation;'),48)  # SAVEPOINT, ROLLBACK TO, RELEASE.
        self.assertNotIn('measure_navigation_wal',sql)
        self.assertNotIn('explain (analyze',sql)
        self.assertIn('Nested writer WAL sample rollback leaked logical data',sql)
        self.assertIn('set local auto_explain.log_wal=on;',sql)
        self.assertIn('set local auto_explain.log_timing=off;',sql)
        self.assertIn('set local auto_explain.log_parameter_max_length=0;',sql)
        self.assertNotIn('pg_current_wal',sql);self.assertNotIn('pg_wal_lsn_diff',sql)
        self.assertEqual(c.upgrade.statement_code(c.upgrade.split_statements(sql)[-1]),'rollback;')
        self.assertNotIn('commit;',[c.upgrade.statement_code(s).lower() for s in c.upgrade.split_statements(sql)])
        for statement in self.phases.prepare+self.phases.activate:self.assertIn(statement,sql)

    def test_exact_navigation_root_only_and_identical_invocations_are_distinct(self):
        event=self.event()
        ancestor={'durationMs':1,'explain':{'Plan':{'Node Type':'Result','WAL Bytes':900000},'Query Text':'select navigation_helper()'}}
        group={'nestedPlans':[ancestor,event,copy.deepcopy(event)]}
        rows=c.navigation_invocations(group)
        self.assertEqual([row['eventOrdinal'] for row in rows],[1,2])
        self.assertEqual(sum(row['walBytes'] for row in rows),200)
        self.assertEqual(rows[0]['querySha256'],rows[1]['querySha256'])
        other=copy.deepcopy(event);other['explain']['Plan']['Schema']='public'
        self.assertEqual(c.navigation_invocations({'nestedPlans':[other]}),[])
        missing=copy.deepcopy(event);del missing['explain']['Plan']['WAL Bytes']
        with self.assertRaises(ValueError):c.navigation_invocations({'nestedPlans':[missing]})

    def test_streaming_groups_reject_unbounded_unassigned_or_truncated_evidence(self):
        identity={'variant':'baseline','label':'cas_one:0'}
        begin='NOTICE:  portal864_plan_begin:'+json.dumps(identity)+'\n'
        end='NOTICE:  portal864_plan_end:'+json.dumps(identity)+'\n'
        event='NOTICE:  duration: 0.1 ms  plan:\n'+json.dumps(self.event()['explain'])+'\n'
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'log';log.write_text(begin+event+end)
            rows=c.parse_groups(log,Path(directory)/'complete')
            self.assertEqual(len(rows[0]['navigationInvocations']),1)
            with patch.object(c.bench,'MAX_GROUP_BYTES',16):
                with self.assertRaises(ValueError):c.parse_groups(log,Path(directory)/'oversize')
            log.write_text(event)
            with self.assertRaises(ValueError):c.parse_groups(log,Path(directory)/'unassigned')
            log.write_text(begin+event)
            with self.assertRaises(ValueError):c.parse_groups(log,Path(directory)/'truncated')

    def matrix(self):
        groups=[];measurements=[]
        for variant in ('baseline','candidate'):
            for operation,(_,count) in c.operations().items():
                for ordinal in range(-1,c.SAMPLES):
                    event=self.event(10 if variant=='baseline' else 100,1 if variant=='baseline' else 0)
                    invocations=c.navigation_invocations({'nestedPlans':[copy.deepcopy(event) for _ in range(count)]})
                    groups.append({'variant':variant,'label':operation+':'+str(ordinal),'navigationInvocations':invocations})
                    ids=[c.cost.TARGET_ONE] if operation=='cas_one' else [c.cost.TARGET_ONE,c.cost.TARGET_TWO,'86900000-0000-4000-8000-000000000109']
                    measurements.extend({'record':'source-row','variant':variant,'operation':operation,'ordinal':ordinal,'id':id} for id in ids)
        return groups,measurements

    def test_complete_warm_and_three_sample_matrix_is_required(self):
        groups,measurements=self.matrix()
        result=c.summarize(groups,measurements)
        self.assertEqual(result['distinctNavigationInvocations'],32)
        self.assertEqual(result['comparisons'][0]['incrementalMedianWalBytesPerSourceRow'],90)
        self.assertEqual(result['comparisons'][1]['incrementalMedianWalBytesPerSourceRow'],90)
        self.assertTrue(result['warmupExcludedFromComparisons'])
        for mutation in ('missing','duplicate','invocation-missing','wrong-conflict-filter','root-rows'):
            g,m=copy.deepcopy(groups),copy.deepcopy(measurements)
            if mutation=='missing':g.pop()
            if mutation=='duplicate':g.append(g[-1])
            if mutation=='invocation-missing':g[-1]['navigationInvocations'].pop()
            if mutation=='wrong-conflict-filter':g[-1]['navigationInvocations'][0]['rowsRemovedByConflictFilter']=1
            if mutation=='root-rows':m[-1]['id']='unexpected'
            with self.assertRaises(ValueError):c.summarize(g,m)

    def test_real_editable_source_writers_and_guards_are_reused(self):
        fixture=c.cost.writer_fixture()
        self.assertIn("'000000000102'",fixture.replace('86900000-0000-4000-8000-',''))
        self.assertNotIn('disable trigger',fixture.lower())
        self.assertIn('Canonical Main predecessor routine bodies differ',c.cost.canonical_guard(self.predecessor))
        self.assertEqual(c.operations()['cas_one'][1],1)
        self.assertEqual(c.operations()['cas_batch'][1],3)
        self.assertIn('update public.flows',c.operations()['cas_one'][0])

    def test_cli_is_fixed_owned_only_and_has_no_resource_or_dsn_options(self):
        result=subprocess.run([sys.executable,c.__file__,'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertLess(len(result.stdout),5000)
        self.assertNotIn('--dsn',result.stdout);self.assertNotIn('--reset',result.stdout)
        self.assertNotIn('--samples',result.stdout)
        self.assertIn('supabase_db_portal-facets-864',result.stdout)


if __name__=='__main__':unittest.main()
