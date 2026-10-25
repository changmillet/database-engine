#!/usr/bin/env python3
"""Offline committed volume collector admission, instrumentation and proof tests."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

import collect_portal_flow_cas_volume_upgrade as c


class VolumeUpgradeTests(unittest.TestCase):
    def test_postgres_trimmed_fractional_timestamps_preserve_microseconds(self):
        for digits in ('1', '12', '123', '1234', '12345', '123456'):
            self.assertEqual(c.parse_timestamp('2026-10-25T12:07:57.' + digits + '+00:00').microsecond,
                             int(digits.ljust(6, '0')))
        with self.assertRaises(ValueError):
            c.parse_timestamp('not a timestamp')

    def test_actual_migrations_remain_intact_and_ordered_without_artificial_holds(self):
        for phase,path in (('A',c.PREPARE),('B',c.ACTIVATE)):
            source=path.read_text()
            instrumented=c.instrument_phase(source,phase)
            position=0
            for statement in c.upgrade.split_statements(source):
                position=instrumented.index(statement,position)+len(statement)
            self.assertIn("'event','start'",instrumented)
            self.assertLess(instrumented.index("'event','precommit'"),instrumented.rindex('commit;'))
            self.assertGreater(instrumented.index("'event','commit'"),instrumented.rindex('commit;'))
            self.assertNotIn('pg_sleep',instrumented.lower())
            self.assertNotIn('insert into supabase_migrations',instrumented.lower())
            self.assertIn("set local statement_timeout='60s'",instrumented)
        self.assertNotIn('pg_relation_size',c.marker('B','start'))
        self.assertIn('pg_relation_size',c.marker('B','precommit'))

    def test_admission_rejects_wrong_ledger_native_objects_sources_or_nonempty_state(self):
        definition="create or replace function private.display_test() returns integer language sql as $$select 1$$;"
        definitions={('function','display_test'):definition}
        state={'migrationCount':439,'migrationHead':'20261025052607','columnExists':False,'indexExists':False,
               'routines':{'display_test':c.bench.sha('select 1')},'activeClients':0,'processVersions':0,'flowVersions':0}
        c.validate_initial_state(state,definitions)
        for field,value in (('migrationCount',440),('migrationHead','wrong'),('columnExists',True),('indexExists',True),
                            ('routines',{}),('activeClients',1),('flowVersions',1)):
            bad=copy.deepcopy(state);bad[field]=value
            with self.assertRaises(ValueError):c.validate_initial_state(bad,definitions)
        with self.assertRaises(ValueError):c.instrument_phase('begin; select 1;','A')

    def lock_records(self):
        records=[]
        def row(phase,event,modes):
            records.append({'record':'migration-marker','phase':phase,'event':event,
                            'at':f'2026-10-25T00:00:{len(records):02d}+00:00',
                            'locks':[{'relation':relation,'mode':mode,'granted':True} for relation,mode in modes]})
        ax=[(c.RELATIONS[2],'AccessExclusiveLock')]
        sre=[(relation,'ShareRowExclusiveLock') for relation in c.RELATIONS]
        row('A','start',[]);row('A','acquired:alter',ax);row('A','precommit',ax);row('A','commit',[])
        row('B','start',[]);row('B','acquired:lock',sre)
        row('B','acquired:index',sre+[(c.RELATIONS[2],'ShareLock')])
        row('B','precommit',sre+[(c.RELATIONS[2],'ShareLock')]);row('B','commit',[])
        return records

    def test_actual_lock_evidence_requires_commit_boundary_and_read_compatible_b(self):
        records=self.lock_records()
        evidence=c.lock_evidence(records)
        self.assertTrue(evidence['aAccessExclusiveReleasedBeforeB'])
        self.assertTrue(evidence['bObservedModesAdmitAccessShare'])
        self.assertEqual(evidence['A']['elapsedToCommitMs'],3000)
        for mutation in ('a-unreleased','b-ax','missing-share','missing-nav-fence','missing-commit'):
            bad=copy.deepcopy(records)
            if mutation=='a-unreleased':bad[3]['locks']=bad[2]['locks']
            if mutation=='b-ax':bad[6]['locks'].append({'relation':c.RELATIONS[2],'mode':'AccessExclusiveLock','granted':True})
            if mutation=='missing-share':bad[6]['locks']=bad[5]['locks']
            if mutation=='missing-nav-fence':bad[7]['locks']=[x for x in bad[7]['locks'] if x['mode']!='ShareRowExclusiveLock']
            if mutation=='missing-commit':bad.pop()
            with self.assertRaises(ValueError):c.lock_evidence(bad)

    def responses(self):
        rows=[]
        for phase in ('before','after-A','after-B'):
            for label in range(10):
                payload={'label':label,'full':{'groups':[{'value':'retained'}]}}
                canonical=json.dumps(payload)
                rows.append({'record':'response','phase':phase,'label':str(label),'payload':payload,'canonicalJson':canonical,
                             'sha256':c.bench.sha(canonical),'role':'anon','workMem':'4MB','statementTimeout':'8s'})
        return rows

    def test_every_complete_dto_and_unchanged_role_budget_must_match(self):
        rows=self.responses()
        self.assertEqual(len(c.compare_controls(rows)),20)
        for mutation in ('missing','duplicate','drift','digest','role','budget'):
            bad=copy.deepcopy(rows)
            if mutation=='missing':bad.pop()
            if mutation=='duplicate':bad.append(bad[-1])
            if mutation=='drift':
                bad[-1]['payload']['full']['groups'][0]['value']='changed'
                bad[-1]['canonicalJson']=json.dumps(bad[-1]['payload']);bad[-1]['sha256']=c.bench.sha(bad[-1]['canonicalJson'])
            if mutation=='digest':bad[-1]['sha256']='wrong'
            if mutation=='role':bad[-1]['role']='postgres'
            if mutation=='budget':bad[-1]['statementTimeout']='60s'
            with self.assertRaises(ValueError):c.compare_controls(bad)
        sql=c.control_sql('before')
        self.assertEqual(sql.count('with result as materialized'),10)
        self.assertEqual(sql.count("set local statement_timeout='8s'"),10)
        self.assertNotIn('set statement_timeout',sql)

    def test_fixed_volume_safe_cli_and_no_resource_cleanup_entrypoint(self):
        self.assertEqual((c.PROCESS_DATASETS,c.FLOW_DATASETS,c.PADDING),(10000,69000,3072))
        result=subprocess.run([sys.executable,str(Path(c.__file__)),'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertLess(len(result.stdout),5000)
        self.assertNotIn('--dsn',result.stdout)
        self.assertNotIn('--candidate',result.stdout)
        self.assertNotIn('--reset',result.stdout)


if __name__=='__main__':unittest.main()
