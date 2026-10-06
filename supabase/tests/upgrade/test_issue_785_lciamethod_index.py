#!/usr/bin/env python3
"""Rollback qualification for the one verified LCIA Method typo-index removal."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[3]
CONTAINER='supabase_db_database-engine-777-pg1711'
TYPO_INDEX_SQL="create index lciamethods_json_dataversion on public.lciamethods((json->'LCIAMethodDataSetDataSet'->'administrativeInformation'->'publicationAndOwnership'->>'common:dataSetVersion'));"


def run(sql: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-h','/var/run/postgresql',
        '-U','postgres','-d','postgres','-Atq','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate'],
        input=sql,text=True,capture_output=True,timeout=120)


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--container',required=True,choices=(CONTAINER,))
    p.add_argument('--reuse-campaign',required=True,choices=('workspace-1701',))
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    if a.report.exists():p.error('Report must be new')
    context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):p.error('Local Unix Docker required')
    guard="select inet_server_addr() is null; select current_setting('server_version'); select count(*) from public.lciamethods; select coalesce(pg_get_indexdef(to_regclass('public.lciamethods_json_dataversion')),'ABSENT');"
    before=run(guard);expected=before.stdout.strip().splitlines()
    if before.returncode or len(expected)!=4 or expected[:3]!=['t','17.11','0'] or (expected[3]!='ABSENT' and 'LCIAMethodDataSetDataSet' not in expected[3]):
        p.error('Require exact local17.11 empty known preimage or canonical postimage')
    prefix=TYPO_INDEX_SQL+'\n' if expected[3]=='ABSENT' else ''
    files=list((ROOT/'supabase/migrations').glob('*_advisor_lciamethod_version_typo_index.sql'))
    if len(files)!=1:raise ValueError('Expected one exact removal migration')
    text=files[0].read_text()
    if text.count('\nbegin;\n')!=1 or not text.endswith('commit;\n'):raise ValueError('Expected single transaction')
    body=text.replace('\nbegin;\n','\n',1).removesuffix('commit;\n')
    fixture="""
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select no_plan();
insert into public.lciamethods(id,version,state_code,json_ordered)
select id,version,100,jsonb_build_object('LCIAMethodDataSet',jsonb_build_object(
 'dataSetInformation',jsonb_build_object('common:UUID',id),
 'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion',version))))::json
from(values('78510000-0000-4000-8000-000000000001'::uuid,'01.00.000'),
 ('78510000-0000-4000-8000-000000000001'::uuid,'01.00.001'),
 ('78510000-0000-4000-8000-000000000002'::uuid,'02.00.000'))v(id,version);
create temp table issue785_method_data_before as select to_jsonb(m) value from public.lciamethods m;
create temp table issue785_method_reads(label text primary key,value jsonb);
grant insert,select on issue785_method_reads to authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"78510000-0000-4000-8000-000000000099"}',true);
set local role authenticated;
insert into issue785_method_reads select 'before',jsonb_agg(jsonb_build_array(id,version,
 json#>>'{LCIAMethodDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}',
 json#>>'{LCIAMethodDataSetDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}') order by id,version)
from public.lciamethods;
reset role;
"""
    checks="""
select ok(to_regclass('public.lciamethods_json_dataversion') is null,'only verified typo index is removed');
select ok(not exists((select to_jsonb(m) from public.lciamethods m except select value from issue785_method_data_before)
 union all(select value from issue785_method_data_before except select to_jsonb(m) from public.lciamethods m)),
 'all LCIA Method data and timestamps remain exact');
set local role authenticated;
insert into issue785_method_reads select 'after',jsonb_agg(jsonb_build_array(id,version,
 json#>>'{LCIAMethodDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}',
 json#>>'{LCIAMethodDataSetDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}') order by id,version)
from public.lciamethods;
reset role;
select is((select value from issue785_method_reads where label='after'),
 (select value from issue785_method_reads where label='before'),'authenticated version ordering/canonical and wrong-root reads remain exact');
select is((select count(*) from public.lciamethods where (id,version)=('78510000-0000-4000-8000-000000000001'::uuid,'01.00.001')),1::bigint,
 'exact typed id/version reference still uses the protected primary-key contract');
update public.lciamethods set json_ordered=jsonb_set(json_ordered::jsonb,
 '{LCIAMethodDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}','"01.00.002"')::json
where id='78510000-0000-4000-8000-000000000001' and version='01.00.001';
select is((select version::text from public.lciamethods where id='78510000-0000-4000-8000-000000000001'
 and json#>>'{LCIAMethodDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}'='01.00.002'),
 '01.00.002','real sync trigger retains canonical JSON and typed version maintenance');
select * from finish();
"""
    result=run('begin;\n'+prefix+fixture+body+checks+'rollback;\n')
    passed=result.returncode==0 and 'not ok' not in result.stdout
    cases=[{'case':'populated-data-auth-read-sync-and-index-graph','passed':passed}]
    for name,setup in (
        ('corrected-definition-refused', "drop index public.lciamethods_json_dataversion; create index lciamethods_json_dataversion on public.lciamethods((json#>>'{LCIAMethodDataSet,administrativeInformation,publicationAndOwnership,common:dataSetVersion}'));"),
        ('incoming-dependency-refused', "create temp view issue785_index_dependency as select 'public.lciamethods_json_dataversion'::regclass value;"),
        ('wrong-root-data-refused',fixture+"update public.lciamethods set json_ordered=(json_ordered::jsonb||'{\"LCIAMethodDataSetDataSet\":{}}')::json where id='78510000-0000-4000-8000-000000000001';"),
    ):
        r=run('begin;\n'+prefix+setup+body+'rollback;\n')
        cases.append({'case':name,'passed':r.returncode==3 and '55000' in r.stderr})
        if not cases[-1]['passed']:print(name+': '+r.stderr[-1000:])
    replay=run('begin;\n'+prefix+'drop index public.lciamethods_json_dataversion;\n'+body+'rollback;\n')
    cases.append({'case':'canonical-postimage-replay','passed':replay.returncode==0})
    cleanup=run(guard)
    if cleanup.returncode or cleanup.stdout.strip().splitlines()!=expected:raise RuntimeError('Rollback data/index residue guard failed')
    a.report.parent.mkdir(parents=True,exist_ok=True)
    a.report.write_text(json.dumps({'container':CONTAINER,'results':cases,'rollbackVerified':True,
      'tap':result.stdout,'scope':'local17.11 known-preimage proof, no hosted operation'},indent=2)+'\n')
    print(json.dumps({'report':str(a.report),'results':cases},indent=2))
    if not passed:print(result.stderr[-1200:])
    return int(any(not x['passed'] for x in cases))


if __name__=='__main__':raise SystemExit(main())
