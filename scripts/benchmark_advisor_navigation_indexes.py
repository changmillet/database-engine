#!/usr/bin/env python3
"""#785 natural Navigation node-only reads and index write/storage comparison.

Explicitly reused local synthetic projections; every DDL/fixture/write rolls back.
Real source-writer and authorization suites remain separate qualification.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import benchmark_portal_catalog_bounded as fixture_source

CONTAINER = 'supabase_db_database-engine-777-pg1711'
INDEXES = {
    'portal_navigation_membership_node_v1_idx': 'create index portal_navigation_membership_node_v1_idx on private.portal_navigation_membership_v1(node_id);',
    'portal_navigation_node_parent_only_v1_idx': 'create index portal_navigation_node_parent_only_v1_idx on private.portal_navigation_node_v1(parent_node_id) where parent_node_id is not null;',
}


def run(sql: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-h','/var/run/postgresql',
        '-U','supabase_admin','-d','postgres','-Atq','-v','ON_ERROR_STOP=1'],
        input=sql,text=True,capture_output=True,timeout=1200)


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--container',required=True,choices=(CONTAINER,))
    p.add_argument('--reuse-campaign',required=True,choices=('workspace-1701',))
    p.add_argument('--samples',type=int,default=20)
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    if not 2<=a.samples<=20: p.error('Require 2..20 balanced samples')
    if any(x.exists() for x in (a.report,a.report.with_suffix('.sql'),a.report.with_suffix('.log'))):
        p.error('Evidence paths must be new')
    context=json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    if not context['Endpoints']['docker']['Host'].startswith('unix://'):p.error('Only local Unix Docker admitted')
    guard="select inet_server_addr() is null; select current_setting('server_version');"+';'.join(
        'select count(*) from private.'+t for t in ('portal_catalog_search_rows_v1','portal_catalog_search_rows_v2',
        'portal_catalog_facet_rows_v1','portal_navigation_versions_v1','portal_navigation_membership_v1','portal_navigation_node_v1'))+';'+\
        ';'.join("select to_regclass('private."+name+"') is null" for name in INDEXES)+''';
select not exists (
 select 1 from (values
  ('portal_navigation_membership_node_v1_idx','portal_navigation_membership_v1','node_id',false),
  ('portal_navigation_node_parent_only_v1_idx','portal_navigation_node_v1','parent_node_id',true)
 ) s(name,table_name,column_name,partial)
 where to_regclass('private.'||s.name) is not null and not exists(
  select 1 from pg_index i join pg_class c on c.oid=i.indexrelid join pg_am am on am.oid=c.relam
  join pg_class t on t.oid=i.indrelid join pg_attribute a on a.attrelid=t.oid and a.attname=s.column_name
  where i.indexrelid=to_regclass('private.'||s.name) and i.indrelid=to_regclass('private.'||s.table_name)
   and i.indisvalid and i.indisready and i.indislive and not i.indisunique and not i.indisprimary
   and i.indnkeyatts=1 and i.indnatts=1 and i.indkey[0]=a.attnum and i.indoption[0]=0
   and i.indcollation[0]=a.attcollation and am.amname='btree' and c.relowner=t.relowner
   and i.indclass[0]=(select oid from pg_opclass where opcname='text_ops' and opcmethod=c.relam and opcnamespace='pg_catalog'::regnamespace)
   and ((not s.partial and i.indpred is null) or (s.partial and pg_get_expr(i.indpred,i.indrelid)='(parent_node_id IS NOT NULL)'))
 ));'''
    check=run(guard);expected=check.stdout.strip().splitlines()
    if check.returncode or len(expected)!=11 or expected[:7]!=['t','17.11']+['0']*5 or expected[-1]!='t':
        p.error('Refusing unknown, non-local, wrong-version, noncanonical indexes or populated target')
    sql=fixture_source.fixture(20000,30000,0)
    sql+="""
reset role;
drop index if exists private.portal_navigation_membership_node_v1_idx;
drop index if exists private.portal_navigation_node_parent_only_v1_idx;
insert into private.portal_navigation_node_v1(node_id,parent_node_id,code,taxonomy,dimension,labels,label_strategy)
values('geo:785-tombstone','geo:unmapped','785-tombstone','unmapped','geography',
 '{"en":"synthetic","zh-CN":"synthetic","de":"synthetic","fr":"synthetic"}',
 '{"en":"synthetic","zh-CN":"synthetic","de":"synthetic","fr":"synthetic"}');
analyze private.portal_navigation_node_v1;
create temp table issue785_member_write_input as select * from private.portal_navigation_membership_v1
order by dataset_kind,id,version,node_id limit 1000;
create temp table issue785_index_sizes(name text,bytes bigint);
create function pg_temp.issue785_write(v text,i integer) returns void language plpgsql security definer as $$
declare started timestamptz:=clock_timestamp(); count_rows integer;
begin
 begin
  delete from private.portal_navigation_membership_v1 m using issue785_member_write_input w
   where (m.dataset_kind,m.id,m.version,m.node_id)=(w.dataset_kind,w.id,w.version,w.node_id);
  insert into private.portal_navigation_membership_v1 select * from issue785_member_write_input;
  get diagnostics count_rows=row_count;
  raise exception using errcode='P7850',message='rollback write-cost sample';
 exception when sqlstate 'P7850' then null; end;
 insert into measurements values(v,'member_delete_insert1000',i,
   extract(epoch from clock_timestamp()-started)*1000,to_jsonb(count_rows),null);
end $$;
create function pg_temp.issue785_cursor(v text,i integer) returns text language plpgsql stable as $$
declare c text;
begin select payload->>'nextCursor' into c from measurements where variant=v and label='navigation_world' and ordinal=i;
 if c is null then raise exception using errcode='P7851',message='Expected real continuation cursor';end if;return c;end $$;
set local role portal_public_executor;
"""
    cases={
      'node_only_absent': "select to_jsonb(exists(select 1 from private.portal_navigation_membership_v1 where node_id='geo:785-tombstone'))",
      'parent_only_children': "select to_jsonb(exists(select 1 from private.portal_navigation_node_v1 where parent_node_id='geo:unmapped'))",
      'navigation_world': "select api.portal_navigation_v1('all','','{}','geography',null,null,100)",
      'navigation_process': "select api.portal_navigation_v1('process','','{}','classification','class:isic',null,100)",
      'navigation_filtered': "select api.portal_navigation_v1('process','','{\"geographyNodeId\":\"geo:cn-ah\"}','classification','class:isic',null,100)",
    }
    for ordinal in range(-1,a.samples):
        for variant in (('baseline','candidate') if ordinal%2==0 else ('candidate','baseline')):
            sql+='\nreset role;\n'
            if variant=='candidate':
                sql+='\n'.join(INDEXES.values())+'\n'
                if ordinal==-1:
                    sql+='\n'.join("insert into issue785_index_sizes select '"+n+"',pg_relation_size('private."+n+"');" for n in INDEXES)+'\n'
            else:
                sql+='\n'.join('drop index if exists private.'+n+';' for n in INDEXES)+'\n'
            sql+='set local role portal_public_executor;\n'
            for label,statement in cases.items():
                sql+=f"select pg_temp.measure('{variant}','{label}',{ordinal},{fixture_source.sql_literal(statement)});\n"
            statement=f"select api.portal_navigation_v1('all','','{{}}','geography',null,pg_temp.issue785_cursor('{variant}',{ordinal}),100)"
            sql+=f"select pg_temp.measure('{variant}','navigation_page2',{ordinal},{fixture_source.sql_literal(statement)});\n"
            sql+=f"select pg_temp.issue785_write('{variant}',{ordinal});\n"
            if ordinal==-1:
                sql+='reset role; load \'auto_explain\'; set local auto_explain.log_min_duration=0; set local auto_explain.log_analyze=on; set local auto_explain.log_buffers=on; set local auto_explain.log_timing=off; set local auto_explain.log_nested_statements=on; set local auto_explain.log_format=json; set local auto_explain.log_level=notice; set local role portal_public_executor;\n'
                for label,statement in cases.items():
                    sql+=f"select pg_temp.capture_plan('{variant}','{label}',{fixture_source.sql_literal(statement)});\n"
                sql+='reset role; set local auto_explain.log_min_duration=-1; set local role portal_public_executor;\n'
            if variant=='candidate':sql+='reset role;\n'+'\n'.join('drop index private.'+n+';' for n in INDEXES)+'\nset local role portal_public_executor;\n'
    sql+="""
reset role;
select jsonb_build_object(
 'memberships',(select count(*) from private.portal_navigation_membership_v1),
 'samples',(select jsonb_agg(to_jsonb(m)-'payload') from measurements m where ordinal>=0),
 'equivalence',(select jsonb_agg(jsonb_build_object('label',b.label,'ordinal',b.ordinal,'equal',b.payload=c.payload,'baselineError',b.error,'candidateError',c.error))
 from measurements b join measurements c using(label,ordinal) where b.variant='baseline' and c.variant='candidate'),
 'plans',(select jsonb_agg(to_jsonb(p)) from plans p),
 'indexBytes',(select jsonb_object_agg(name,bytes) from issue785_index_sizes));
rollback;
"""
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.with_suffix('.sql').write_text(sql)
    try:
        result=run(sql);a.report.with_suffix('.log').write_text(result.stdout+'\n'+result.stderr)
    finally:
        cleanup=run(guard)
        if cleanup.returncode or cleanup.stdout.strip().splitlines()!=expected:raise RuntimeError('Rollback/index residue guard failed')
    if result.returncode:
        print(f'Profile failed; see {a.report.with_suffix(".log")}');return result.returncode
    records=[json.loads(x) for x in result.stdout.splitlines() if x.startswith('{')];report=records[-1]
    report.update({'fixtureVersions':100000,'samplesPerVariant':a.samples,'container':CONTAINER,
      'sqlSha256':hashlib.sha256(sql.encode()).hexdigest(),'scope':'local warm synthetic direct projections; writer/RLS and hosted qualification separate','cleanupRows':0})
    report['medians']={label:{v:statistics.median(x['elapsed_ms'] for x in report['samples'] if x['variant']==v and x['label']==label)
        for v in ('baseline','candidate')} for label in cases.keys()|{'navigation_page2','member_delete_insert1000'}}
    a.report.write_text(json.dumps(report,indent=2)+'\n')
    failures=[x for x in report['equivalence'] if x['equal'] is not True or x['baselineError'] or x['candidateError']]
    print(json.dumps({'report':str(a.report),'memberships':report['memberships'],'medians':report['medians'],'indexBytes':report['indexBytes'],'failures':failures},indent=2))
    return int(bool(failures or any(x['error'] for x in report['plans'])))


if __name__=='__main__':raise SystemExit(main())
