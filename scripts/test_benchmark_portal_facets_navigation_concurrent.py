#!/usr/bin/env python3
"""Offline safety/identity tests; no Docker or database calls."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch
import benchmark_portal_facets_navigation_concurrent as b
from test_benchmark_portal_facets_navigation import native_snapshot, native_plan_groups


class ConcurrentCollectorTests(unittest.TestCase):
    def dense_reference(self,native=False):
        candidate = 'create or replace function private.display_test() returns integer language sql as $$select 1$$;'
        definitions = b.serial.reader_definitions(candidate)
        variants = {name:b.serial.definitions_sql(definitions) for name in ('baseline','candidate')}
        selected = list(b.serial.NATIVE_RARE_CASES) if native else ['facets_flow_cas_rare','navigation_all_cas_absent']
        sql, cases = b.serial.build_sql(variants,20,40,0,2,b.SCOPES,selected_cases=selected,plan_min_ms=1,fixture_profile='cas-dense',native_cas_fact=native)
        rows=[]
        def row(variant,label,ordinal,payload):
            canonical=json.dumps(payload)
            return {'variant':variant,'label':label,'ordinal':ordinal,'payload':payload,'canonicalJson':canonical,
                    'sha256':b.serial.sha(canonical),'error':None,'sessionRole':'anon','workMem':'4MB','statementTimeout':'8s'}
        for scope in b.SCOPES:
            for name in ('navigation_world','navigation_page2','navigation_geography'):
                rows.append(row('baseline',scope+':'+name,-2,{'nextCursor':'actual'}))
            for variant in variants:
                for ordinal in (-1,0,1):
                    for name in selected: rows.append(row(variant,scope+':'+name,ordinal,{'ok':True}))
        report={'schemaVersion':'portal.facets-navigation-serial.v1','passed':True,'baselineOnly':False,
                'candidateLocalP95TargetPassed':True,'cleanup':{'emptyRowsAndLocalIdentityVerified':True},
                'baseCommit':'exact','candidateSha256':b.serial.sha(candidate),'collectorSha256':b.serial.file_sha(Path(b.serial.__file__)),
                'collectorArtifact':b.serial.__file__,'baselineSourceSha256':b.serial.sha(variants['baseline']),
                'candidateReaderSha256':b.serial.sha(variants['candidate']),'fixture':b.serial.fixture_metadata(20,40,0,'cas-dense',native),
                'samples':rows,'selectedCases':selected,'nestedPlanMinDurationMs':1,'sqlSha256':b.serial.sha(sql),
                'fixtureActual':{'processVersions':40,'flowVersions':80,'publicSourceRows':0,'casCounts':b.serial.expected_dense_cas_counts(40)},
                'equivalence':[{'equal':True}]}
        if native:
            snapshot=native_snapshot()
            report.update(nativeSchemaBefore=snapshot,nativeSchema=copy.deepcopy(snapshot),nativeSchemaFingerprint=b.serial.schema_fingerprint(snapshot),
                          nestedPlanCoverage={'groups':native_plan_groups(b.SCOPES)})
            expected=b.serial.expected_dense_cas_counts(40)
            report['fixtureActual']['nativeCasFact']={k:expected[k] for k in ('nonNull','rare','common')}|{'mismatches':0}
        return report,candidate,definitions

    def test_native_reference_binds_schema_population_and_bounded_plan_proof(self):
        report,candidate,definitions=self.dense_reference(True)
        with patch.object(b.serial,'baseline',return_value=definitions):
            b.validate_reference(report,candidate,'exact')
            for mutation in ('schema','fact','plan','flag'):
                bad=copy.deepcopy(report)
                if mutation=='schema':bad['nativeSchema']['index']['ready']=False
                if mutation=='fact':bad['fixtureActual']['nativeCasFact']['mismatches']=1
                if mutation=='plan':bad['nestedPlanCoverage']['groups']=[]
                if mutation=='flag':bad['fixture']['nativeCasFact']=False
                with self.assertRaises(ValueError):b.validate_reference(bad,candidate,'exact')

    def test_dense_reference_binds_profile_cases_sql_and_actual_distribution(self):
        report,candidate,definitions=self.dense_reference()
        with patch.object(b.serial,'baseline',return_value=definitions):
            variants,cases,indexed=b.validate_reference(report,candidate,'exact')
            self.assertEqual(len(b.request_cases(cases,indexed,tuple(report['selectedCases']))),4)
            for mutate in ('profile','width','distribution','sql'):
                bad=copy.deepcopy(report)
                if mutate=='profile':bad['fixture']['profile']='legacy'
                if mutate=='width':bad['fixture']['documentWidthCohorts']['shortBytes']=1
                if mutate=='distribution':bad['fixtureActual']['casCounts']['rare']=3
                if mutate=='sql':bad['sqlSha256']='wrong'
                with self.assertRaises(ValueError):b.validate_reference(bad,candidate,'exact')

    def test_concurrent_summary_is_shared_and_help_is_bounded(self):
        self.assertEqual(b.fixture_summary_sql(),b.serial.fixture_summary_sql())
        result=subprocess.run([sys.executable,b.__file__,'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertLess(len(result.stdout),10000)
        self.assertIn('1..10',result.stdout)

    def sample(self, variant, client):
        return {'variant':variant,'label':'scope:case','ordinal':0,'client':client,
                'matchesSerial':True,'wallMs':100,'error':None,'pid':100+client,
                'startedEpoch':1,'finishedEpoch':2}

    def test_exact_cursor_is_substituted_without_temp_session_dependency(self):
        cases = {scope:{'navigation_page2':"select rpc(pg_temp.predecessor_cursor('"+scope+":navigation_world'))"} for scope in b.SCOPES}
        indexed = {('baseline',scope+':navigation_world',-2):{'payload':{'nextCursor':"actual'cursor"}} for scope in b.SCOPES}
        result = b.request_cases(cases, indexed, ('navigation_page2',))
        self.assertTrue(all("'actual''cursor'" in value and 'pg_temp.' not in value for value in result.values()))
        with self.assertRaises(ValueError):
            b.request_cases(cases, {}, ('navigation_page2',))

    def test_reference_rejects_wrong_candidate_before_any_source_or_db_access(self):
        report = {'schemaVersion':'portal.facets-navigation-serial.v1','passed':True,
                  'baselineOnly':False,'candidateLocalP95TargetPassed':True,
                  'cleanup':{'emptyRowsAndLocalIdentityVerified':True},
                  'baseCommit':'exact','candidateSha256':'wrong'}
        with patch.object(b.serial, 'baseline', side_effect=AssertionError('must not be reached')):
            with self.assertRaisesRegex(ValueError, 'exact baseline/candidate'):
                b.validate_reference(report, 'candidate', 'exact')

    def test_four_clients_and_wall_target_are_required(self):
        rows=[self.sample(v,c) for v in ('baseline','candidate') for c in range(4)]
        summary, failures=b.summarize(rows, {'scope:case':'sql'}, 1, {'baseline':4,'candidate':4})
        self.assertEqual(failures, [])
        self.assertTrue(summary['candidateLocalP95TargetPassed'])
        slow=copy.deepcopy(rows);slow[-1]['wallMs']=2001
        summary,failures=b.summarize(slow, {'scope:case':'sql'}, 1, {'baseline':4,'candidate':4})
        self.assertFalse(summary['candidateLocalP95TargetPassed'])
        self.assertTrue(any('2000ms' in failure for failure in failures))
        _,failures=b.summarize(rows[:-1], {'scope:case':'sql'}, 1, {'baseline':4,'candidate':1})
        self.assertTrue(any('matrix' in failure for failure in failures))
        self.assertTrue(any('overlap' in failure for failure in failures))

    def test_every_successful_response_must_match_serial(self):
        rows=[self.sample(v,c) for v in ('baseline','candidate') for c in range(4)]
        rows[0]['matchesSerial']=False
        _,failures=b.summarize(rows, {'scope:case':'sql'}, 1, {'baseline':4,'candidate':4})
        self.assertTrue(any('response differs' in failure for failure in failures))
        rows[0]['error']='P0001'
        summary,failures=b.summarize(rows, {'scope:case':'sql'}, 1, {'baseline':4,'candidate':4})
        self.assertEqual(failures, [])
        self.assertEqual(len(summary['baselineErrors']), 1)

    def test_backend_intervals_do_not_count_touching_endpoints_as_overlap(self):
        self.assertEqual(b.maximum_overlap([{'startedEpoch':1,'finishedEpoch':2},{'startedEpoch':2,'finishedEpoch':3}]),1)

    def test_client_materializes_one_call_under_public_role_and_budgets(self):
        source=b.client_sql('owned','select api.rpc()')
        self.assertEqual(source.count("execute 'select api.rpc()'"),1)
        self.assertIn("set local statement_timeout='8s';set local work_mem='4MB'",source)
        self.assertIn('set local role anon;',source)
        self.assertTrue(source.endswith('rollback;\n'))
        self.assertNotIn('grant create on schema private',source)

    def test_serial_reference_matrix_and_digests_are_independently_checked(self):
        cases={scope:{'facets_all_empty':'sql'} for scope in b.SCOPES}
        rows=[]
        def row(variant,label,ordinal,payload):
            canonical=json.dumps(payload)
            return {'variant':variant,'label':label,'ordinal':ordinal,'payload':payload,
                    'canonicalJson':canonical,'sha256':b.serial.sha(canonical),'error':None,
                    'sessionRole':'anon','workMem':'4MB','statementTimeout':'8s'}
        for scope in b.SCOPES:
            for name in ('navigation_world','navigation_page2','navigation_geography'):
                rows.append(row('baseline',scope+':'+name,-2,{'nextCursor':'actual'}))
            for variant in ('baseline','candidate'):
                for ordinal in (-1,0,1):
                    rows.append(row(variant,scope+':facets_all_empty',ordinal,{'ok':True}))
        self.assertEqual(len(b.serial_rows({'samples':rows},cases,2)),18)
        bad=copy.deepcopy(rows);bad[-1]['sha256']='wrong'
        with self.assertRaisesRegex(ValueError,'digest'):
            b.serial_rows({'samples':bad},cases,2)
        with self.assertRaisesRegex(ValueError,'incomplete'):
            b.serial_rows({'samples':rows[:-1]},cases,2)

    def test_bounded_json_refuses_oversized_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'report'
            path.write_text(json.dumps({'long':'x'*30}))
            with self.assertRaises(ValueError):b.bounded_json(path,16)


if __name__=='__main__':unittest.main()
