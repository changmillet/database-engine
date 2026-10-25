#!/usr/bin/env python3
"""Offline safety/collector regression tests; never contacts Docker or a database."""
import copy
import argparse
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
import benchmark_portal_facets_navigation as b


def native_snapshot():
    return {'column':{'type':'text','nullable':True,'generated':'','hasDefault':False},
            'table':{'owner':'postgres','rls':True,'forceRls':True,'executorSelect':True,'anonSelect':False,'authenticatedSelect':False},
            'executor':{'login':False,'bypassRls':False,'superuser':False},
            'index':{'name':b.NATIVE_CAS_INDEX,'valid':True,'ready':True,'live':True,'unique':False,'method':'btree',
                     'keys':['dataset_kind','cas_number','id','version'],'keyCount':4,'expressions':None,
                     'predicate':"((dataset_kind = 'flow'::text) AND (cas_number IS NOT NULL))"},
            'policies':[{'name':'display_scope','command':'r','permissive':True,'roles':['portal_display_executor'],
                         'qual':'EXISTS (SELECT 1 FROM private.display_request_visible_settings_v1 s WHERE s.dataset_kind=display_navigation_versions_v1.dataset_kind AND s.dataset_id=display_navigation_versions_v1.id AND (s.dataset_version)::text=display_navigation_versions_v1.version)'}],
            'writerMd5':'a'*32,'indexBytes':8192}


def native_plan_groups(scopes):
    return [{'variant':'candidate','label':scope+':'+case,
             'casDiagnostics':{'casScans':[{'Index Cond':"(cas_number = '50-00-0'::text)",'Actual Rows':2,'Actual Loops':1,'Rows Removed by Filter':0,'eventIndex':0}],
                               'settingsScans':[{'Actual Rows':1,'Actual Loops':2,'eventIndex':0}]}}
            for scope in scopes for case in b.NATIVE_RARE_CASES]


class QualificationTests(unittest.TestCase):
    def test_native_metadata_admission_and_fingerprint_exclude_index_size_only(self):
        snapshot=native_snapshot()
        fingerprint=b.validate_native_schema(snapshot)
        snapshot['indexBytes']=16384
        self.assertEqual(b.validate_native_schema(snapshot),fingerprint)
        for field,value in (('ready',False),('valid',False),('live',False),('keys',['cas_number','dataset_kind','id','version']),('predicate',"cas_number IS NOT NULL")):
            bad=copy.deepcopy(snapshot);bad['index'][field]=value
            with self.assertRaises(ValueError): b.validate_native_schema(bad)
        for component,field,value in (('column','nullable',False),('column','type','varchar'),('table','forceRls',False),('executor','bypassRls',True)):
            bad=copy.deepcopy(snapshot);bad[component][field]=value
            with self.assertRaises(ValueError):b.validate_native_schema(bad)
        self.assertNotIn('alter table',b.native_schema_sql().lower())
        self.assertNotIn('create index',b.native_schema_sql().lower())

    def test_native_seed_and_zero_ms_capture_are_explicit_and_narrow(self):
        sql,_=b.build_sql({'baseline':'','candidate':''},20,40,0,2,('tiangong_lca','bafu,tiangong_lca,uslci,worldsteel'),
                          selected_cases=list(b.NATIVE_RARE_CASES)+['facets_all_cas_rare','facets_flow_cas_common'],
                          fixture_profile='cas-dense',native_cas_fact=True,plan_min_ms=1)
        self.assertIn('update private.display_navigation_versions_v1 v set cas_number=',sql)
        self.assertIn("length(p.card->>'casNumber') between 7 and 12",sql)
        self.assertIn("then p.card->>'casNumber' else null end",sql)
        self.assertIn("begin;\nset local auto_explain.log_min_duration=-1;",sql)
        import re
        captured=re.findall(r"set local auto_explain.log_min_duration=0;set local role anon;\nselect pg_temp.capture_plan\('([^']*)','([^']*)'",sql)
        self.assertEqual(len(captured),4)
        self.assertTrue(all(variant=='candidate' and label.split(':')[-1] in b.NATIVE_RARE_CASES for variant,label in captured))
        self.assertNotIn('create index',sql.lower())
        self.assertIn("'mismatches'",b.fixture_summary_sql(True))
        with self.assertRaises(ValueError):b.fixture(20,40,0,'legacy',True)

    def test_every_profiling_guc_is_set_before_anon_and_every_capture_runs_as_anon(self):
        import re
        for native,profile in ((False,'legacy'),(True,'cas-dense')):
            sql,_=b.build_sql({'baseline':'','candidate':''},20,40,0,2,('tiangong_lca',),
                              fixture_profile=profile,native_cas_fact=native,plan_min_ms=1,
                              selected_cases=list(b.NATIVE_RARE_CASES) if native else ['facets_flow_cas','navigation_cas'])
            role='admin'
            settings=captures=0
            for match in re.finditer(r"reset role;|set local role anon;|set local auto_explain\.[a-z_]+=[^;]*;|select pg_temp\.capture_plan\(",sql):
                token=match.group()
                if token=='reset role;':role='admin'
                elif token=='set local role anon;':role='anon'
                elif token.startswith('set local auto_explain.'):
                    self.assertEqual(role,'admin',token)
                    settings+=1
                else:
                    self.assertEqual(role,'anon',token)
                    captures+=1
            self.assertGreater(captures,0)
            self.assertGreater(settings,captures)
            self.assertNotIn('grant ',sql.lower().split('create temp table measurements')[0])
            self.assertIn("set local work_mem='4MB';set local statement_timeout='8s';set local role anon;",sql)

    def test_native_gate_requires_real_bounded_equality_not_index_name(self):
        groups=native_plan_groups(('scope',))
        evidence,failures=b.native_plan_gate(groups,('scope',))
        self.assertEqual(failures,[])
        self.assertEqual(evidence[0]['visibilityScans'][0]['Actual Loops'],2)
        for mutation in ('name-only','broad','repeated'):
            bad=copy.deepcopy(groups);node=bad[0]['casDiagnostics']['casScans'][0]
            if mutation=='name-only':node['Index Cond']='cas_number IS NOT NULL';node['Index Name']=b.NATIVE_CAS_INDEX
            if mutation=='broad':node['Rows Removed by Filter']=100000
            if mutation=='repeated':node['Actual Loops']=10
            self.assertTrue(b.native_plan_gate(bad,('scope',))[1])
        diagnostics=b.plan_diagnostics({'nestedPlans':[{'explain':{'Plan':{'Node Type':'Index Scan','Index Cond':"cas_number = '50-00-0'",'Actual Rows':2}}}]})
        self.assertTrue(diagnostics['equalityIndexCondObserved'])

    def test_relative_gates_reject_slow_cases_and_leave_process_and_smoke_observational(self):
        labels=[f'scope:{api}_{kind}_cas_{shape}' for api in ('facets','navigation') for kind in ('flow','all','process') for shape in ('rare','absent','common')]
        timings={}
        for label in labels:
            timings['baseline:'+label]={'p95Ms':1000}
            timings['candidate:'+label]={'p95Ms':1100 if label.endswith('common') else 500}
        self.assertEqual(b.relative_cas_evidence(timings,labels)[1],[])
        timings['candidate:scope:facets_flow_cas_rare']['p95Ms']=501
        timings['candidate:scope:facets_all_cas_common']['p95Ms']=1101
        timings['candidate:scope:facets_process_cas_rare']['p95Ms']=5000
        self.assertEqual(len(b.relative_cas_evidence(timings,labels)[1]),2)
        self.assertEqual(b.relative_cas_evidence(timings,labels,enforce=False)[1],[])

    def test_legacy_fixture_retains_exact_predecessor_sql(self):
        # Exact Main 6a880838 fixture(20,40,16), computed before this extension.
        self.assertEqual(b.sha(b.fixture(20,40,16)), '3569934b6aabc1f05db1020483cfdb625ae81360bb5d08a9438e93c39d74df70')
        self.assertEqual(b.fixture(20,40,16), b.fixture(20,40,16,'legacy'))

    def test_dense_fixture_has_background_rare_brands_and_document_invariant(self):
        sql = b.fixture(20,40,3072,'cas-dense')
        self.assertIn("(i=1 and v=0) or (i=5 and v=1)", sql)
        self.assertIn("i%100<78", sql)
        self.assertIn("array['67-56-1','7732-18-5','124-38-9','74-82-8']", sql)
        self.assertIn("coalesce(' '||cas.cas_number,'')", sql)
        self.assertIn("'document',d.document", sql)
        self.assertIn('d.document,1,', sql)
        self.assertIn("'process'='process' and i%19=0 then ' 50-00-0'", sql)
        self.assertEqual(b.expected_dense_cas_counts(69000), {'flowVersions':138000,'nonNull':107640,'rare':2,'common':13798,'absent':0,'documentInvariantViolations':0})
        self.assertEqual(b.fixture_metadata(20,40,3072,'cas-dense')['documentWidthCohorts'], {'shortBytes':610,'longBytes':2237,'longEvery':19})
        with self.assertRaises(ValueError): b.fixture(20,40,0,'untrusted')

    def test_dense_matrix_and_nested_capture_cover_every_cas_kind(self):
        selected = [f'{api}_{kind}_cas_{shape}' for api in ('facets','navigation') for kind in ('flow','all','process') for shape in ('rare','absent','common')]
        sql, cases = b.build_sql({'baseline':'','candidate':''},20,40,0,2,('tiangong_lca','bafu,tiangong_lca,uslci,worldsteel'), selected_cases=selected, fixture_profile='cas-dense')
        for scope, statements in cases.items():
            self.assertEqual(set(statements), set(selected))
            for label in selected:
                self.assertIn(f"pg_temp.capture_plan('candidate','{scope}:{label}'",sql)
        self.assertNotIn('__FIXTURE_SUMMARY__',sql)
        self.assertIn('documentInvariantViolations',sql)
        self.assertNotIn('set local auto_explain.log_min_duration=0;',sql)
        with self.assertRaisesRegex(ValueError,'unavailable'):
            b.build_sql({'baseline':''},20,40,0,2,('tiangong_lca',),selected_cases=selected)

    def test_plan_diagnostics_distinguish_index_name_from_equality(self):
        scan = {'Node Type':'Index Scan','Relation Name':'display_catalog_search_rows_v1','Index Name':'flow_cas_idx',
                'Filter':"card->>'casNumber' = '50-00-0'",'Actual Rows':2,'Rows Removed by Filter':999,'Actual Loops':1,
                'Plans':[{'Node Type':'Index Scan','Relation Name':'dataset_display_settings','Actual Loops':1001}]}
        group = {'nestedPlans':[{'explain':{'Plan':scan}}]}
        observed = b.plan_diagnostics(group)
        self.assertFalse(observed['equalityIndexCondObserved'])
        self.assertEqual(observed['casScans'][0]['Rows Removed by Filter'],999)
        self.assertEqual(observed['settingsScans'][0]['Actual Loops'],1001)
        scan['Index Cond'] = "card->>'casNumber' = '50-00-0'"
        self.assertTrue(b.plan_diagnostics(group)['equalityIndexCondObserved'])
        self.assertEqual(b.plan_diagnostics({'nestedPlans':[]})['casScans'],[])

    def test_concise_help_and_numeric_rejection_precede_docker(self):
        result = subprocess.run([sys.executable,str(Path(b.__file__)),'--help'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertLess(len(result.stdout),10000)
        self.assertIn('40..100000',result.stdout)
        for raw in ('39','100001','NaN'):
            with self.assertRaises(argparse.ArgumentTypeError): b.bounded_int(40,100000)(raw)
        self.assertEqual(b.bounded_int(40,100000)('40'),40)

    def test_reader_extraction_ignores_migration_envelope_and_body_keywords(self):
        source = "begin; create or replace function private.display_a() returns text language sql as $x$select 'create or replace view private.display_fake as select 1;'$x$; update private.secret set x=1;commit;"
        parsed = b.reader_definitions(source)
        self.assertEqual(list(parsed), [('function', 'display_a')])
        self.assertNotIn('update private.secret', b.definitions_sql(parsed))

    def test_unsupported_reader_fails_closed(self):
        for source in ("create or replace function private.other() returns int language sql as $$select 1$$;",
                       "create or replace function private.display_a() returns int language sql as $$select 1$$;" * 2,
                       "create or replace function private.display_a() returns int language sql as $$select 1"):
            with self.assertRaises(ValueError):
                b.reader_definitions(source)

    def test_target_rejects_remote_or_wrong_ownership(self):
        context = {'Endpoints': {'docker': {'Host': 'unix:///tmp/docker.sock'}}}
        inspected = {'Name': '/' + b.CONTAINER, 'Config': {'Labels': {'com.supabase.cli.project': b.PROJECT}}, 'State': {'Running': True}}
        owner = 'database#864 disposable-test portal-facets-864'
        with patch.dict(b.os.environ, {}, clear=True):
            b.validate_target(context, inspected, owner)
            for invalid in ('database#829 portal-facets-864', 'database#864 shared-dev'):
                with self.assertRaises(ValueError):
                    b.validate_target(context, inspected, invalid)
            wrong = copy.deepcopy(inspected)
            wrong['Config']['Labels']['com.supabase.cli.project'] = 'shared-dev'
            with self.assertRaises(ValueError):
                b.validate_target(context, wrong, owner)
            context['Endpoints']['docker']['Host'] = 'tcp://host:2375'
            with self.assertRaises(ValueError):
                b.validate_target(context, inspected, owner)

    def test_generated_comparison_uses_predecessor_cursor_and_budget(self):
        sql, cases = b.build_sql({'baseline': '-- baseline\n', 'candidate': '-- candidate\n'}, 20, 40, 16, 2, ('tiangong_lca',), False)
        self.assertIn("pg_temp.predecessor_cursor('tiangong_lca:navigation_world')", cases['tiangong_lca']['navigation_page2'])
        self.assertNotIn('12MB', sql)
        self.assertNotIn('32MB', sql)
        self.assertIn("set local statement_timeout='8s'", sql)
        self.assertTrue(sql.endswith('rollback;\n'))
        self.assertIn('history864', sql)
        self.assertIn('50-00-0', sql)
        self.assertIn('exception when query_canceled', sql)
        self.assertNotIn('grant create on schema', sql)
        self.assertNotIn('grant portal_public_executor', sql)

    def test_nested_auto_explain_is_grouped_by_enclosing_identity(self):
        import json
        inner = {'Query Text': 'select from facts', 'Plan': {'Node Type': 'Seq Scan', 'Relation Name': 'display_navigation_versions_v1'}}
        outer = {'Query Text': "select pg_temp.capture_plan('candidate','scope:case','sql');", 'Plan': {'Node Type': 'Result'}}
        log = ''.join('NOTICE:  duration: 1.2 ms  plan:\n' + json.dumps(value) + '\n' for value in (inner, outer))
        parsed = b.nested_plans(log)
        self.assertEqual(parsed['unassigned'], [])
        self.assertEqual((parsed['groups'][0]['variant'], parsed['groups'][0]['label']), ('candidate', 'scope:case'))
        self.assertTrue(b.has_relation_plan(parsed['groups'][0]))
        self.assertEqual(len(parsed['groups'][0]['nestedPlans']), 2)

    def test_streaming_plan_parser_limits_and_boundaries(self):
        import json
        import tempfile
        from pathlib import Path
        begin = 'NOTICE:  portal864_plan_begin:{"variant":"baseline","label":"x"}\n'
        end = 'NOTICE:  portal864_plan_end:{"variant":"baseline","label":"x"}\n'
        event = {'Query Text': 'select facts', 'Plan': {'Node Type': 'Seq Scan', 'Relation Name': 'display_navigation_versions_v1'}}
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory)/'log', Path(directory)/'plans'
            source.write_text(begin+'NOTICE:  duration: 12 ms  plan:\n'+json.dumps(event)+'\n'+end)
            summary = b.stream_nested_plans(source, target)
            self.assertTrue(summary['groups'][0]['naturalRelationPlan'])
            self.assertEqual(summary['groups'][0]['eventCount'], 1)
            self.assertGreater(summary['groups'][0]['nestedPlanBytes'],0)
            self.assertEqual(json.loads(target.read_text())['unassignedCount'], 0)
            with patch.object(b, 'MAX_PLAN_BYTES', 16):
                with self.assertRaises(ValueError):
                    list(b.iter_log_events(source))
            source.write_text(begin + end.replace('"x"', '"wrong"'))
            with self.assertRaises(ValueError):
                b.stream_nested_plans(source, Path(directory)/'bad')

    def test_missing_samples_and_null_responses_cannot_pass(self):
        _, cases = b.build_sql({'baseline': '', 'candidate': ''}, 20, 40, 0, 2, ('tiangong_lca',), False)
        report = {'samples': [], 'plans': []}
        failures = b.summarize(report, 2, ('tiangong_lca',), cases, ('baseline', 'candidate'))
        self.assertIn('Missing/duplicate expected samples', failures)
        self.assertFalse(report['cursorProof'])
        self.assertTrue(report['equivalence'])
        self.assertTrue(all(not comparison['equal'] for comparison in report['equivalence']))


if __name__ == '__main__':
    unittest.main()
