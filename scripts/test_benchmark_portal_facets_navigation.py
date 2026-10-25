#!/usr/bin/env python3
"""Offline safety/collector regression tests; never contacts Docker or a database."""
import copy
import unittest
from unittest.mock import patch
import benchmark_portal_facets_navigation as b


class QualificationTests(unittest.TestCase):
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
