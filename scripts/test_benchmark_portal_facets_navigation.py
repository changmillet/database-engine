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


class QualificationTests(unittest.TestCase):
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
