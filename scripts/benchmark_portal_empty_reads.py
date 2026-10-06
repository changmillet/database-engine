#!/usr/bin/env python3
"""Database #783: order-balanced, rollback-only Portal empty-read comparison.

Reuse the campaign-owned #1701/#777 PostgreSQL17.11 stack explicitly; never
invoke or relax the imported #723 command guard. Synthetic direct projections
measure readers only. Real writer/RLS tests remain separate qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess

import benchmark_portal_catalog_bounded as fixture_source

ROOT = Path(__file__).resolve().parents[1]
REUSED_CONTAINER = 'supabase_db_database-engine-777-pg1711'
FUNCTIONS = ('portal_navigation_impl_v1', 'catalog_portal_facets_empty_v2_impl')
CANDIDATE = ROOT / 'supabase/migrations/20261006074505_portal_empty_navigation_facets_reads.sql'


def run(container: str, sql: str) -> subprocess.CompletedProcess[str]:
    # Local admin loads auto_explain; measured calls explicitly use the real
    # NOBYPASSRLS Portal executor. No runtime role privilege is modified.
    return subprocess.run(
        ['docker', 'exec', '-i', container, 'psql', '-h', '/var/run/postgresql',
         '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'],
        input=sql, text=True, capture_output=True, timeout=1200,
    )


def baseline_definitions(ref: str) -> str:
    return '\n'.join(subprocess.check_output(
        ['git', 'show', f'{ref}:supabase/workspace/schemas/private/functions/{name}/definition.sql'],
        cwd=ROOT, text=True,
    ) for name in FUNCTIONS)


def statements() -> dict[str, str]:
    cases = {k: v for k, v in fixture_source.cases().items()
             if k.startswith(('facets_', 'navigation_'))}
    cases.update({
        'navigation_process_class': "select api.portal_navigation_v1('process','','{}','classification','class:isic',null,100)",
        'navigation_process_geo': "select api.portal_navigation_v1('process','','{}','geography','geo:cn',null,100)",
        'navigation_flow_class': "select api.portal_navigation_v1('flow','','{}','classification','class:cpc',null,100)",
        'navigation_zero': "select api.portal_navigation_v1('all','missing-783','{}','geography','geo:cn',null,100)",
        'navigation_lexical': "select api.portal_navigation_v1('process','benchprocess 00000001','{}','geography','geo:cn',null,100)",
        'facets_lexical': "select api.portal_facets_v3('process','benchprocess 00000001','{}')",
        'facets_v2_empty': "select api.portal_facets_v2('all','','{}')",
    })
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True)
    parser.add_argument('--reuse-campaign', choices=('workspace-1701',), required=True)
    parser.add_argument('--base-ref', required=True)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--process-datasets', type=int, default=20000)
    parser.add_argument('--flow-datasets', type=int, default=30000)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.container != REUSED_CONTAINER:
        parser.error('Only the explicitly reused campaign PostgreSQL17.11 container is admitted')
    if not (2 <= args.samples <= 20 and 1 <= args.process_datasets <= 50000
            and 1 <= args.flow_datasets <= 100000):
        parser.error('Fixture/sample bounds exceeded')
    artifacts = [args.report, args.report.with_suffix('.sql'), args.report.with_suffix('.log')]
    if any(p.exists() for p in artifacts):
        parser.error('Evidence paths must all be new files')
    context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):
        parser.error('Only a local Docker Unix socket is admitted')
    guard_sql = "select inet_server_addr() is null; select current_setting('server_version'); " + '; '.join(
        f'select count(*) from private.{table}' for table in (
            'portal_catalog_search_rows_v1', 'portal_catalog_search_rows_v2',
            'portal_catalog_facet_rows_v1', 'portal_navigation_versions_v1',
            'portal_navigation_membership_v1')) + ';'
    check = run(args.container, guard_sql)
    expected = ['t', '17.11', '0', '0', '0', '0', '0']
    if check.returncode or check.stdout.strip().splitlines() != expected:
        parser.error('Refusing an unknown, non-local, wrong-version or nonempty fixture target')
    base = subprocess.check_output(['git', 'rev-parse', f'{args.base_ref}^{{commit}}'], cwd=ROOT, text=True).strip()
    candidate_text = CANDIDATE.read_text()
    # Replay reader definitions only. Migration BEGIN/COMMIT and transient DDL
    # permissions must never escape this benchmark's outer rollback transaction.
    candidate_definitions = []
    for name in FUNCTIONS:
        pattern = rf'CREATE OR REPLACE FUNCTION "private"\."{name}"\(.*?AS \$\$.*?\$\$;'
        found = re.search(pattern, candidate_text, re.S)
        if not found:
            raise ValueError(f'Missing exact candidate definition: {name}')
        candidate_definitions.append(found.group())
    definitions = {'baseline': baseline_definitions(base), 'candidate': '\n'.join(candidate_definitions)}
    cases = statements()
    sql = fixture_source.fixture(args.process_datasets, args.flow_datasets, 0)
    # Unmeasured warm-up, then alternate predecessor/candidate order per sample.
    for ordinal in range(-1, args.samples):
        order = ('baseline', 'candidate') if ordinal % 2 == 0 else ('candidate', 'baseline')
        for variant in order:
            sql += '\n' + definitions[variant] + '\n'
            for label, statement in cases.items():
                sql += f'select pg_temp.measure({fixture_source.sql_literal(variant)},{fixture_source.sql_literal(label)},{ordinal},{fixture_source.sql_literal(statement)});\n'
            # Feed each variant its own cursor, so continuation differences are observable.
            cursor_statement = "select api.portal_navigation_v1('all','','{}','geography',null,(select payload->>'nextCursor' from measurements where variant=" + fixture_source.sql_literal(variant) + " and label='navigation_world' and ordinal=" + str(ordinal) + "),100)"
            sql += f"select pg_temp.measure('{variant}','navigation_page2',{ordinal},{fixture_source.sql_literal(cursor_statement)});\n"
    for variant in ('baseline', 'candidate'):
        sql += '\nset local role portal_public_executor;\n' + definitions[variant] + '\nreset role;\n'
        sql += "load 'auto_explain'; set local auto_explain.log_min_duration=0; set local auto_explain.log_analyze=on; set local auto_explain.log_buffers=on; set local auto_explain.log_timing=off; set local auto_explain.log_nested_statements=on; set local auto_explain.log_format=json; set local auto_explain.log_level=notice;\nset local role portal_public_executor;\n"
        for label in ('facets_all', 'facets_process', 'facets_flow', 'navigation_world', 'navigation_process_class', 'navigation_filtered'):
            sql += f"select pg_temp.capture_plan('{variant}',{fixture_source.sql_literal(label)},{fixture_source.sql_literal(cases[label])});\n"
        sql += 'reset role; set local auto_explain.log_min_duration=-1;\n'
    sql += """
select jsonb_build_object(
 'samples',(select jsonb_agg(jsonb_build_object('variant',variant,'label',label,'ordinal',ordinal,'elapsedMs',elapsed_ms,'error',error) order by label,ordinal,variant) from measurements where ordinal>=0),
 'equivalence',(select jsonb_agg(jsonb_build_object('label',b.label,'ordinal',b.ordinal,'equal',b.payload=c.payload,'baselineError',b.error,'candidateError',c.error) order by b.label,b.ordinal) from measurements b join measurements c using(label,ordinal) where b.variant='baseline' and c.variant='candidate'),
 'plans',(select jsonb_agg(jsonb_build_object('variant',variant,'label',label,'plan',payload,'error',error) order by label,variant) from plans));
rollback;
"""
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.with_suffix('.sql').write_text(sql)
    try:
        result = run(args.container, sql)
        args.report.with_suffix('.log').write_text(result.stdout + '\n' + result.stderr)
    finally:
        # Even failed SQL/transport exits must check the target after rollback.
        cleanup = run(args.container, guard_sql)
        if cleanup.returncode or cleanup.stdout.strip().splitlines() != expected:
            raise RuntimeError('Rollback fixture residue/version guard failed')
    if result.returncode:
        print(result.stderr[-3000:])
        return result.returncode
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    if len(records) != 1:
        raise RuntimeError('Missing unique benchmark result')
    report = records[0]
    report.update({'baseCommit': base, 'candidateSha256': hashlib.sha256(candidate_text.encode()).hexdigest(),
                   'sqlSha256': hashlib.sha256(sql.encode()).hexdigest(), 'campaignReuse': args.reuse_campaign,
                   'container': args.container, 'fixtureVersions': 2 * (args.process_datasets + args.flow_datasets),
                   'scope': 'synthetic local order-balanced warm reader comparison; not hosted p95 or writer proof',
                   'nestedNaturalPlans': str(args.report.with_suffix('.log')), 'cleanupRows': 0})
    report['medians'] = {label: {variant: statistics.median(
        s['elapsedMs'] for s in report['samples'] if s['label'] == label and s['variant'] == variant)
        for variant in ('baseline', 'candidate')} for label in cases.keys() | {'navigation_page2'}}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    failures = [r for r in report['equivalence'] if not r['equal'] or r['baselineError'] or r['candidateError']]
    errors = [r for r in report['plans'] if r['error']]
    print(json.dumps({'report': str(args.report), 'comparisons': len(report['equivalence']),
                      'failures': failures, 'planErrors': errors, 'medians': report['medians'], 'cleanupRows': 0}, indent=2))
    return int(bool(failures or errors))


if __name__ == '__main__':
    raise SystemExit(main())
