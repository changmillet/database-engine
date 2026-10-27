#!/usr/bin/env python3
"""Database #864: guarded rollback-only scoped Facets/Navigation qualification.

Synthetic projection fixtures measure readers, not source writers or hosted p95.
No remote DSN, credentials, planner hints, policy changes or budget increases are
accepted. Public RPCs run as anon and retain their portal_display_executor path.
The session has 4MB work_mem; existing routine overrides are recorded unchanged.
The legacy fixture is preserved; cas-dense adds independent CAS populations and
document widths. Nested plan collection retains its explicit duration threshold.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_portal-facets-864'
PROJECT = 'portal-facets-864'
OWNER = Path('/tmp/portal-facets-navigation-20261025-6I1gDw/OWNER.md')
TABLES = tuple('public.' + name for name in ('processes', 'flows', 'contacts', 'sources', 'unitgroups', 'flowproperties', 'lciamethods', 'lifecyclemodels')) + tuple('private.' + name for name in (
    'display_catalog_search_rows_v1', 'display_catalog_search_rows_v2',
    'display_catalog_facet_rows_v1', 'display_navigation_versions_v1',
    'display_navigation_membership_v1', 'display_catalog_character_rows_v1',
    'dataset_display_settings'))
BASELINE_READERS = ('display_catalog_facets_empty_v2_impl', 'display_catalog_facets_v3_impl',
                    'display_navigation_impl_v1', 'display_navigation_matched_versions_v1',
                    'portal_display_brand_facets_v1')
MAX_LOG_BYTES = 128 * 1024 * 1024
MAX_STDOUT_BYTES = 64 * 1024 * 1024
MAX_PLAN_BYTES = 2 * 1024 * 1024
MAX_GROUP_BYTES = 16 * 1024 * 1024
FIXTURE_PROFILES = ('legacy', 'cas-dense')
CAS_QUERIES = {'rare': '50-00-0', 'absent': '75-07-0', 'common': '64-17-5'}
NATIVE_CAS_INDEX = 'd807_portal_navigation_versions_flow_cas_v1_idx'
NATIVE_RARE_CASES = ('facets_flow_cas_rare', 'navigation_flow_cas_rare')

REFRESH = '\nupdate private.portal_display_contract_manifest set identity=private.portal_display_contract_identity_v1() where singleton;\nselect private.portal_display_assert_contract_v1();\n'


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def sha(value: bytes | str) -> str:
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while block := source.read(1024*1024):
            digest.update(block)
    return digest.hexdigest()


def run(sql: str, timeout: int = 3600) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-h',
                           '/var/run/postgresql', '-U', 'supabase_admin', '-d', 'postgres',
                           '-Atq', '-v', 'ON_ERROR_STOP=1'], input=sql, text=True,
                          capture_output=True, timeout=timeout)


def private_output(path: Path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb')


def run_logged(sql_path: Path, stdout_path: Path, log_path: Path, timeout: int = 3600):
    """Stream process output to bounded private files, never PIPE/capture_output."""
    command = ['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-h',
               '/var/run/postgresql', '-U', 'supabase_admin', '-d', 'postgres',
               '-Atq', '-v', 'ON_ERROR_STOP=1']
    process = None
    try:
        with sql_path.open('rb') as source, private_output(stdout_path) as output, private_output(log_path) as log:
            process = subprocess.Popen(command, stdin=source, stdout=output, stderr=log)
            started = time.monotonic()
            while process.poll() is None:
                if log_path.stat().st_size > MAX_LOG_BYTES or stdout_path.stat().st_size > MAX_STDOUT_BYTES:
                    raise RuntimeError('Collector output exceeded bounded artifact limit')
                if time.monotonic() - started > timeout:
                    raise RuntimeError('Collector process deadline exceeded')
                try:
                    process.wait(timeout=.1)
                except subprocess.TimeoutExpired:
                    pass
            code = process.returncode
        if log_path.stat().st_size > MAX_LOG_BYTES or stdout_path.stat().st_size > MAX_STDOUT_BYTES:
            raise RuntimeError('Collector output exceeded bounded artifact limit')
        return subprocess.CompletedProcess(command, code, stdout_path.read_text(), '')
    except BaseException:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        # Cancel only this explicitly named owned fixture session. PostgreSQL
        # transaction rollback follows the closed Docker/psql client connection.
        run("select pg_cancel_backend(pid) from pg_stat_activity where application_name='portal864-serial' and pid<>pg_backend_pid();", 30)
        raise


def reader_definitions(source: str) -> dict[tuple[str, str], str]:
    """Extract named existing readers only; never execute arbitrary migration DDL.

    Dollar quoting is required for functions. New helpers/overloads are outside
    this reader comparison interface and require an explicit harness extension.
    """
    result = {}
    header = re.compile(r'\bcreate\s+or\s+replace\s+(function|view)\s+"?private"?\."?([a-z_][a-z_0-9]*)"?', re.I)
    position = 0
    while match := header.search(source, position):
        kind, name = match.group(1).lower(), match.group(2).lower()
        if not name.startswith(('display_', 'portal_display_')):
            raise ValueError('Reader outside display namespace: ' + name)
        if kind == 'function':
            opening = re.search(r'\bas\s+(\$[a-zA-Z_0-9]*\$)', source[match.end():], re.I)
            if not opening:
                raise ValueError('Dollar-quoted function required: ' + name)
            body = match.end() + opening.end()
            closing = source.find(opening.group(1), body)
            if closing < 0:
                raise ValueError('Unterminated function: ' + name)
            end = closing + len(opening.group(1))
            terminator = re.match(r'\s*;', source[end:])
            if not terminator:
                raise ValueError('Missing function terminator: ' + name)
            end += terminator.end()
        else:
            end = source.find(';', match.end()) + 1
            if end == 0:
                raise ValueError('Unterminated view: ' + name)
        key = (kind, name)
        if key in result:
            raise ValueError('Duplicate/overloaded reader requires explicit support: ' + name)
        result[key] = source[match.start():end]
        position = end
    if not result:
        raise ValueError('No CREATE OR REPLACE display readers found')
    return result


def baseline(ref: str, keys: list[tuple[str, str]]) -> dict[tuple[str, str], str]:
    result = {}
    for kind, name in keys:
        path = f'supabase/workspace/schemas/private/{kind}s/{name}/definition.sql'
        source = subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT, text=True)
        parsed = reader_definitions(source)
        if set(parsed) != {(kind, name)}:
            raise ValueError('Ambiguous predecessor definition: ' + path)
        result.update(parsed)
    return result


def definitions_sql(definitions: dict) -> str:
    return '\n'.join(definitions.values()) + REFRESH


def fixture(processes: int, flows: int, padding: int, profile: str = 'legacy', native_cas_fact: bool = False) -> str:
    """Direct, consistent reader projections; all DDL/data rolls back.

    No raw source rows are fabricated. All public source tables remain empty;
    real source-trigger/upgrade proof is an explicitly separate qualification.
    """
    if profile not in FIXTURE_PROFILES:
        raise ValueError('Unsupported fixture profile')
    if native_cas_fact and profile != 'cas-dense':
        raise ValueError('Native CAS fact requires cas-dense profile')
    tables = ','.join(literal(t) + '::regclass' for t in TABLES)
    sql = f"""
set application_name='portal864-serial';
begin;
set local statement_timeout='10min';
set local work_mem='4MB';
do $$begin if not pg_try_advisory_xact_lock(864,1) then raise exception 'Another #864 fixture owns this database';end if;end$$;
create temp table original_triggers as
 select tgrelid::regclass::text relation,tgname,tgenabled from pg_trigger
 where not tgisinternal and tgrelid in ({tables});
do $$declare r record;begin for r in select distinct relation from original_triggers loop
 execute format('alter table %s disable trigger user',r.relation);end loop;end$$;
create function pg_temp.payload(k text,g text,c text) returns jsonb language sql immutable as $$
 select jsonb_build_object(case when k='flow' then 'flowDataSet' else 'processDataSet' end,jsonb_build_object(
 case when k='flow' then 'flowInformation' else 'processInformation' end,jsonb_build_object(
 'dataSetInformation',jsonb_build_object('name',jsonb_build_object('baseName','Benchmark864'),
 'classificationInformation',jsonb_build_object('common:classification',jsonb_build_object('common:class',jsonb_build_object('@classId',c)))),
 'time',jsonb_build_object('common:referenceYear','2024'),
 'geography',jsonb_build_object(case when k='flow' then 'locationOfSupply' else 'locationOfOperationSupplyOrProduction' end,jsonb_build_object('@location',g))),
 'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:licenseType','Free of charge for all users and uses'))))
$$;
create temp table templates as select k,g,c,
 private.catalog_portal_projection_payload_v1(k,100,pg_temp.payload(k,g,c))->'card' old,
 case when k='process' then private.catalog_portal_projection_payload_cn1(k,100,pg_temp.payload(k,g,c))->'card' end current
 from unnest(array['process','flow']) k cross join unnest(array['CN','CN-AH-HFE','US']) g
 cross join unnest(array['0111','0112','17100']) c;
"""
    for kind, count, prefix in (('process', processes, '8640e000'), ('flow', flows, '8640f000')):
        for revision in ([1, 2] if kind == 'process' else [1]):
            base = 't.current' if revision == 2 else 't.old'
            cas = f"case when '{kind}'='flow' and i%17=0 then '50-00-0' else null end"
            document = f"cross join lateral (select 'bench{kind} '||lpad(i::text,8,'0')||case when v=0 then ' history864' else ' current864' end||case when i%19=0 then ' %_ literal864' else '' end document) d"
            if profile == 'cas-dense':
                cas = 'cas.cas_number'
                # Exactly two rare keys, in Tiangong history and BAFU current.
                # Other index-eligible values expose equality left as a Filter.
                document = f"""cross join lateral (select case when '{kind}'<>'flow' then null
 when (i=1 and v=0) or (i=5 and v=1) then '50-00-0'
 when i%100<10 then '64-17-5'
 when i%100<78 then (array['67-56-1','7732-18-5','124-38-9','74-82-8'])[1+i%4]
 else null end cas_number) cas
cross join lateral (select 'bench{kind} '||lpad(i::text,8,'0')||case when v=0 then ' history864' else ' current864' end||
 case when '{kind}'='process' and i%19=0 then ' 50-00-0' else '' end||
 coalesce(' '||cas.cas_number,'')||' '||substr((select string_agg(md5(i::text||':doc:'||s::text),'') from generate_series(1,70) s),1,
 (case when i%19=0 then 2237 else 610 end)-length('bench{kind} '||lpad(i::text,8,'0')||case when v=0 then ' history864' else ' current864' end||case when '{kind}'='process' and i%19=0 then ' 50-00-0' else '' end||coalesce(' '||cas.cas_number,'')||' ')) document) d"""
            sql += f"""
insert into private.display_catalog_search_rows_v{revision}(dataset_kind,id,version,state_code,modified_at,card,document,projection_contract_version,brand)
select '{kind}',('{prefix}-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'01.00.00'||v,
 case when v=0 then 100 else 200 end,'2026-10-25'::timestamptz-i*interval '1 second'+v*interval '1 millisecond',
 {base} || jsonb_build_object('document',d.document,'accessLevel','public',
 'names',jsonb_build_array(jsonb_build_object('language','en','value',d.document)),
 'summary',jsonb_build_array(jsonb_build_object('language','en','value',substr((select string_agg(md5(i::text||':'||s::text),'') from generate_series(1,{max(1, (padding + 31) // 32)}) s),1,{padding}))),
 'referenceYear',case when i%11=0 then null else (2020+i%5)::text end,
 'source',case when i%13=0 then null else 'fixture864-source-'||(i%3)::text end,
 'processSubtype',case when '{kind}'='process' then 'unit process, single operation' else null end,
 'casNumber',{cas}),
 d.document,{revision},case when i%5=0 then case when v=0 then 'tiangong_lca' else 'bafu' end
 when i%10<7 then 'tiangong_lca' when i%10=7 then 'bafu' when i%10=8 then 'uslci' else 'worldsteel' end
from generate_series(1,{count}) i cross join generate_series(0,1) v
{document}
join templates t on t.k='{kind}' and t.g=case i%3 when 0 then 'US' when 1 then 'CN' else 'CN-AH-HFE' end
 and t.c=case when '{kind}'='process' then case when i%2=0 then '0111' else '0112' end else case when i%2=0 then '17100' else '0111' end end;
"""
    sql += """
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,brand)
select dataset_kind,id,version,true,brand from private.display_catalog_search_rows_v1;
insert into private.display_catalog_facet_rows_v1(dataset_kind,id,version,state_code,modified_at,facet_access_level,facet_geography,facet_reference_year,facet_process_subtype,facet_source,facet_contract_version)
select dataset_kind,id,version,state_code,modified_at,card->>'accessLevel',lower(btrim(card#>>'{geography,code}')),card->>'referenceYear',lower(btrim(card->>'processSubtype')),lower(btrim(card->>'source')),1
from private.display_catalog_search_rows_v1;
insert into private.display_navigation_versions_v1(dataset_kind,id,version,access_level,geography_code,classification_codes,reference_year,process_subtype,source)
select dataset_kind,id,version,card->>'accessLevel',lower(btrim(card#>>'{geography,code}')),
array(select distinct lower(btrim(c->>'code')) from jsonb_array_elements(card->'classifications') c),
(card->>'referenceYear')::integer,lower(btrim(card->>'processSubtype')),lower(btrim(card->>'source'))
from private.display_catalog_search_current_v2;
__NATIVE_FACT_SEED__
-- Resolve seven real direct placements once, then reuse their reviewed ancestors.
create temp table placement_map as with recursive p as (
 select n.node_id origin,n.node_id,n.parent_node_id,n.dimension,n.taxonomy,n.code,true direct
 from private.portal_navigation_node_v1 n where n.node_id in
 ('geo:cn','geo:cn-ah-hfe','geo:us','class:isic:0.0.0.0','class:isic:0.0.0.1','class:cpc:0.0.0.0','class:cpc:1.6.0.0.0')
 union all select p.origin,n.node_id,n.parent_node_id,n.dimension,p.taxonomy,p.code,false
 from p join private.portal_navigation_node_v1 n on n.node_id=p.parent_node_id
) select * from p;
do $$begin if (select count(distinct origin) from placement_map)<>7 then raise exception 'Pinned vocabulary placement missing';end if;end$$;
insert into private.display_navigation_membership_v1(dataset_kind,id,version,node_id,dimension,direct)
select v.dataset_kind,v.id,v.version,p.node_id,p.dimension,bool_or(p.direct)
from private.display_navigation_versions_v1 v join placement_map p on
 (p.dimension='geography' and p.origin='geo:'||v.geography_code)
 or (p.dimension='classification' and p.taxonomy=case v.dataset_kind when 'process' then 'isic' else 'cpc' end and lower(p.code)=any(v.classification_codes))
group by v.dataset_kind,v.id,v.version,p.node_id,p.dimension;
do $$declare r record;begin for r in select * from original_triggers loop
 execute format('alter table %s %s trigger %I',r.relation,case r.tgenabled when 'D' then 'disable' when 'A' then 'enable always' when 'R' then 'enable replica' else 'enable' end,r.tgname);end loop;
 if exists(select 1 from original_triggers saved join pg_trigger t on t.tgrelid=saved.relation::regclass and t.tgname=saved.tgname where t.tgenabled<>saved.tgenabled) then raise exception 'Trigger restoration drift';end if;
end$$;
set constraints all immediate;
update private.portal_display_rollout set mode='display';
"""
    sql += '\n'.join('analyze ' + table + ';' for table in TABLES)
    seed = """update private.display_navigation_versions_v1 v set cas_number=
 case when p.dataset_kind='flow' and jsonb_typeof(p.card->'casNumber')='string'
 and p.card->>'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
 and length(p.card->>'casNumber') between 7 and 12 then p.card->>'casNumber' else null end
 from private.display_catalog_search_rows_v1 p
 where (v.dataset_kind,v.id,v.version)=(p.dataset_kind,p.id,p.version);""" if native_cas_fact else ''
    # Keep the legacy fixture byte-identical, including the original newline.
    sql = sql.replace('__NATIVE_FACT_SEED__\n', seed+'\n' if seed else '')
    if native_cas_fact:
        sql = sql.replace("begin;\nset local statement_timeout", "begin;\nset local auto_explain.log_min_duration=-1;\nset local statement_timeout",1)
    return sql + "\nset local work_mem='4MB';set local statement_timeout='8s';\n"


def cases(scope: str, profile: str = 'legacy') -> dict[str, str]:
    brands = 'array[' + ','.join(literal(v) for v in scope.split(',')) + ']'
    result = {}
    shapes = [('empty', '', {}), ('geography', '', {'geographyNodeId': 'geo:cn-ah'}),
              ('direct', '', {'geographyNodeId': 'geo:cn', 'geographyScope': 'direct'}),
              ('year', '', {'referenceYearFrom': 2022, 'referenceYearTo': 2023}),
              ('zero', '', {'source': 'absent-864'}), ('lexical', 'benchprocess 00000001', {}),
              ('cas', '50-00-0', {}), ('uuid', '8640e000-0000-4000-8000-000000000001', {}),
              ('history', 'history864', {}), ('current', 'current864', {}), ('escaped', '%_', {}), ('one', 'b', {}),
              ('brand', '', {'brand': 'bafu'}), ('classification', '', {'classification': '0111'}),
              ('combined', '', {'classificationNodeId': 'class:isic', 'geographyNodeId': 'geo:cn', 'referenceYearFrom': 2021})]
    for kind in ('all', 'process', 'flow'):
        for label, query, filters in shapes:
            result[f'facets_{kind}_{label}'] = f"select api.portal_facets_v4({brands},{literal(kind)},{literal(query)},{literal(json.dumps(filters))}::jsonb)"
    for label, kind, dimension, parent, query, filters in (
        ('world', 'all', 'geography', None, '', {}),
        ('classification_root', 'all', 'classification', None, '', {}),
        ('process_root', 'process', 'classification', None, '', {}),
        ('flow_root', 'flow', 'classification', None, '', {}),
        ('process_class', 'process', 'classification', 'class:isic', '', {}),
        ('flow_class', 'flow', 'classification', 'class:cpc', '', {}),
        ('geography', 'all', 'geography', 'geo:cn', '', {}),
        ('us', 'all', 'geography', None, '', {'geographyNodeId': 'geo:us'}),
        ('filtered', 'process', 'classification', 'class:isic', '', {'geographyNodeId': 'geo:cn-ah'}),
        ('direct', 'all', 'geography', None, '', {'geographyNodeId': 'geo:cn', 'geographyScope': 'direct'}),
        ('year', 'all', 'geography', None, '', {'referenceYearFrom': 2022, 'referenceYearTo': 2023}),
        ('brand', 'all', 'geography', None, '', {'brand': 'bafu'}),
        ('lexical', 'process', 'classification', 'class:isic', 'benchprocess 00000001', {}),
        ('cas', 'flow', 'geography', None, '50-00-0', {}),
        ('uuid', 'process', 'geography', None, '8640e000-0000-4000-8000-000000000001', {}),
        ('history', 'all', 'geography', None, 'history864', {}),
        ('one', 'all', 'classification', None, 'b', {}),
        ('zero', 'all', 'geography', None, '', {'source': 'absent-864'})):
        result['navigation_' + label] = f"select api.portal_navigation_v2({brands},{literal(kind)},{literal(query)},{literal(json.dumps(filters))}::jsonb,{literal(dimension)},{'null' if parent is None else literal(parent)},null,20)"
    result['navigation_world'] = result['navigation_world'].replace(',null,20)', ',null,100)')
    result['navigation_geography'] = result['navigation_geography'].replace(',null,20)', ',null,1)')
    if profile == 'cas-dense':
        for label, query in CAS_QUERIES.items():
            for kind in ('all', 'process', 'flow'):
                result[f'facets_{kind}_cas_{label}'] = f"select api.portal_facets_v4({brands},{literal(kind)},{literal(query)},'{{}}'::jsonb)"
                result[f'navigation_{kind}_cas_{label}'] = f"select api.portal_navigation_v2({brands},{literal(kind)},{literal(query)},'{{}}'::jsonb,'geography',null,null,20)"
    elif profile != 'legacy':
        raise ValueError('Unsupported fixture profile')
    return result


COLLECTOR = """
create temp table measurements(variant text,label text,ordinal integer,elapsed_ms numeric,payload jsonb,error text,session_role text,work_mem text,statement_timeout text);
create temp table plans(variant text,label text,payload jsonb,error text);
create temp table variant_settings(variant text primary key,routines jsonb);
grant select,insert on measurements,plans to anon;
create function pg_temp.measure(v text,l text,i integer,s text) returns void language plpgsql as $$
declare started timestamptz:=clock_timestamp();result jsonb;failure text;begin
 begin execute s into result;
 exception when query_canceled then failure:=sqlstate;when others then failure:=sqlstate;end;
 insert into measurements values(v,l,i,extract(epoch from clock_timestamp()-started)*1000,result,failure,current_user,current_setting('work_mem'),current_setting('statement_timeout'));
end$$;
create function pg_temp.capture_plan(v text,l text,s text) returns void language plpgsql as $$
declare result jsonb;failure text;begin
 raise notice 'portal864_plan_begin:%',jsonb_build_object('variant',v,'label',l)::text;
 begin execute 'explain (analyze,buffers,timing off,format json) '||s into result;
 exception when query_canceled then failure:=sqlstate;when others then failure:=sqlstate;end;
 insert into plans values(v,l,result,failure);
 raise notice 'portal864_plan_end:%',jsonb_build_object('variant',v,'label',l)::text;
end$$;
create function pg_temp.predecessor_cursor(l text) returns text language plpgsql stable as $$
declare c text;begin select payload->>'nextCursor' into c from measurements where variant='baseline' and label=l and ordinal=-2;
 if c is null then raise exception 'Successful predecessor continuation cursor required';end if;return c;end$$;
grant execute on function pg_temp.measure(text,text,integer,text),pg_temp.capture_plan(text,text,text),pg_temp.predecessor_cursor(text) to anon;
"""


def native_schema_sql() -> str:
    """Read-only admission evidence; the collector never installs schema DDL."""
    return f"""select jsonb_build_object(
 'column',(select jsonb_build_object('type',format_type(a.atttypid,a.atttypmod),'nullable',not a.attnotnull,'generated',a.attgenerated,'hasDefault',a.atthasdef)
 from pg_attribute a where a.attrelid='private.display_navigation_versions_v1'::regclass and a.attname='cas_number' and not a.attisdropped),
 'table',(select jsonb_build_object('owner',c.relowner::regrole::text,'rls',c.relrowsecurity,'forceRls',c.relforcerowsecurity,
 'executorSelect',has_table_privilege('portal_display_executor',c.oid,'SELECT'),'anonSelect',has_table_privilege('anon',c.oid,'SELECT'),
 'authenticatedSelect',has_table_privilege('authenticated',c.oid,'SELECT')) from pg_class c where c.oid='private.display_navigation_versions_v1'::regclass),
 'executor',(select jsonb_build_object('login',rolcanlogin,'bypassRls',rolbypassrls,'superuser',rolsuper) from pg_roles where rolname='portal_display_executor'),
 'policies',(select jsonb_agg(jsonb_build_object('name',polname,'command',polcmd,'permissive',polpermissive,
 'roles',(select jsonb_agg(rolname order by rolname) from pg_roles where oid=any(polroles)),
 'qual',pg_get_expr(polqual,polrelid)) order by polname) from pg_policy where polrelid='private.display_navigation_versions_v1'::regclass),
 'index',(select jsonb_build_object('name',c.relname,'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,'unique',i.indisunique,
 'method',am.amname,'keys',(select jsonb_agg(pg_get_indexdef(i.indexrelid,s,true) order by s) from generate_series(1,i.indnatts) s),
 'keyCount',i.indnkeyatts,'predicate',pg_get_expr(i.indpred,i.indrelid),'expressions',pg_get_expr(i.indexprs,i.indrelid))
 from pg_index i join pg_class c on c.oid=i.indexrelid join pg_am am on am.oid=c.relam
 where i.indexrelid=to_regclass('private.{NATIVE_CAS_INDEX}') and i.indrelid='private.display_navigation_versions_v1'::regclass),
 'writerMd5',(select md5(pg_get_functiondef(to_regprocedure('private.display_sync_navigation_membership_v1(text,uuid,text,jsonb)')))),
 'indexBytes',coalesce(pg_relation_size(to_regclass('private.{NATIVE_CAS_INDEX}')),0));"""


def schema_fingerprint(snapshot: dict) -> str:
    return sha(json.dumps({k:v for k,v in snapshot.items() if k != 'indexBytes'}, sort_keys=True, separators=(',', ':')))


def validate_native_schema(snapshot: dict) -> str:
    if snapshot.get('column') != {'type':'text','nullable':True,'generated':'','hasDefault':False}:
        raise ValueError('Exact nullable native CAS text column required')
    if snapshot.get('table') != {'owner':'postgres','rls':True,'forceRls':True,'executorSelect':True,'anonSelect':False,'authenticatedSelect':False}:
        raise ValueError('Native CAS relation permissions/RLS differ')
    if snapshot.get('executor') != {'login':False,'bypassRls':False,'superuser':False}:
        raise ValueError('Native CAS executor permissions differ')
    index = snapshot.get('index') or {}
    expected = {'name':NATIVE_CAS_INDEX,'valid':True,'ready':True,'live':True,'unique':False,'method':'btree',
                'keys':['dataset_kind','cas_number','id','version'],'keyCount':4,'expressions':None}
    if any(index.get(key) != value for key,value in expected.items()) or re.sub(r'[\s()]','',index.get('predicate','')) != "dataset_kind='flow'::textANDcas_numberISNOTNULL":
        raise ValueError('Exact ready native CAS index definition required')
    policies = snapshot.get('policies') or []
    if len(policies) != 1 or any(policies[0].get(k) != v for k,v in {'name':'display_scope','command':'r','permissive':True,'roles':['portal_display_executor']}.items()):
        raise ValueError('Native CAS visibility policy differs')
    qual = re.sub(r'[\s()"]','',policies[0].get('qual',''))
    if not all(part in qual for part in ('private.display_request_visible_settings_v1','s.dataset_kind=display_navigation_versions_v1.dataset_kind','s.dataset_id=display_navigation_versions_v1.id','s.dataset_version::text=display_navigation_versions_v1.version')):
        raise ValueError('Native CAS exact-version visibility policy required')
    if not re.fullmatch('[0-9a-f]{32}',snapshot.get('writerMd5') or '') or type(snapshot.get('indexBytes')) is not int or snapshot['indexBytes'] <= 0:
        raise ValueError('Native CAS writer/index metadata incomplete')
    return schema_fingerprint(snapshot)


def fixture_summary_sql(native_cas_fact: bool = False) -> str:
    sql = """select jsonb_build_object(
 'processVersions',(select count(*) from private.display_navigation_versions_v1 where dataset_kind='process'),
 'flowVersions',(select count(*) from private.display_navigation_versions_v1 where dataset_kind='flow'),
 'memberships',(select count(*) from private.display_navigation_membership_v1),
 'publicSourceRows',(select count(*) from public.processes)+(select count(*) from public.flows),'averageCardBytes',(select avg(pg_column_size(card)) from private.display_catalog_search_rows_v1),
 'brands',(select jsonb_object_agg(brand,n) from (select brand,count(*) n from private.dataset_display_settings group by brand) b),
 'widths',(select jsonb_build_object('averageLogicalCardBytes',avg(octet_length(card::text)),'p95LogicalCardBytes',percentile_disc(.95) within group(order by octet_length(card::text)),
 'averageDocumentBytes',avg(octet_length(document)),'p95DocumentBytes',percentile_disc(.95) within group(order by octet_length(document)),
 'averageStoredCardBytes',avg(pg_column_size(card)),'p95StoredCardBytes',percentile_disc(.95) within group(order by pg_column_size(card))) from private.display_catalog_search_rows_v1),
 'casCounts',(select jsonb_build_object('flowVersions',count(*),'nonNull',count(*) filter(where card->>'casNumber' is not null),
 'rare',count(*) filter(where card->>'casNumber'='50-00-0'),'common',count(*) filter(where card->>'casNumber'='64-17-5'),
 'absent',count(*) filter(where card->>'casNumber'='75-07-0'),
 'documentInvariantViolations',count(*) filter(where card->>'casNumber' is not null and (position(card->>'casNumber' in document)=0 or position(card->>'casNumber' in (card->>'document'))=0))) from private.display_catalog_search_rows_v1 where dataset_kind='flow'));"""
    if native_cas_fact:
        sql = sql.removesuffix(';') + """ || jsonb_build_object('nativeCasFact',(
 select jsonb_build_object('nonNull',count(*) filter(where v.cas_number is not null),
 'rare',count(*) filter(where v.cas_number='50-00-0'),'common',count(*) filter(where v.cas_number='64-17-5'),
 'mismatches',count(*) filter(where v.cas_number is distinct from case when p.dataset_kind='flow'
 and jsonb_typeof(p.card->'casNumber')='string' and p.card->>'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
 and length(p.card->>'casNumber') between 7 and 12 then p.card->>'casNumber' else null end))
 from private.display_navigation_versions_v1 v join private.display_catalog_search_rows_v1 p using(dataset_kind,id,version)));"""
    return sql


def fixture_metadata(processes: int, flows: int, padding: int, profile: str, native_cas_fact: bool = False) -> dict:
    if profile not in FIXTURE_PROFILES:
        raise ValueError('Unsupported fixture profile')
    if type(native_cas_fact) is not bool or (native_cas_fact and profile != 'cas-dense'):
        raise ValueError('Native CAS fact requires cas-dense profile')
    return {'processVersions': 2*processes, 'flowVersions': 2*flows, 'nativeCasFact':native_cas_fact,
            'summaryPaddingBytes': padding, 'profile': profile,
            'documentWidthCohorts': {'shortBytes': 610, 'longBytes': 2237, 'longEvery': 19} if profile == 'cas-dense' else None}


def expected_dense_cas_counts(flows: int) -> dict:
    rare = lambda i, v: (i == 1 and v == 0) or (i == 5 and v == 1)
    return {'flowVersions': flows*2,
            'nonNull': sum(rare(i, v) or i % 100 < 78 for i in range(1, flows+1) for v in (0, 1)),
            'rare': 2, 'common': sum(not rare(i, v) and i % 100 < 10 for i in range(1, flows+1) for v in (0, 1)),
            'absent': 0, 'documentInvariantViolations': 0}


def build_sql(definitions: dict[str, str], processes: int, flows: int, padding: int,
              samples: int, scopes: tuple[str, ...], include_plans: bool = True, selected_cases: list[str] | None = None, plan_min_ms: int = 10, fixture_profile: str = 'legacy', native_cas_fact: bool = False) -> tuple[str, dict]:
    all_cases = {scope: cases(scope, fixture_profile) for scope in scopes}
    sql = fixture(processes, flows, padding, fixture_profile, native_cas_fact) + COLLECTOR
    if selected_cases and any(label not in next(iter(all_cases.values())) and label not in ('navigation_page2', 'navigation_page3', 'navigation_cn_page2') for label in selected_cases):
        raise ValueError('Selected case unavailable in fixture profile')
    # Capture predecessor-issued cursors before alternating order. The fixture's
    # vocabulary always contains >20 world children, even in smoke mode.
    sql += 'reset role;\n' + definitions['baseline'] + 'set local role anon;\n'
    for scope in scopes:
        label = scope + ':navigation_world'
        sql += f"select pg_temp.measure('baseline',{literal(label)},-2,{literal(all_cases[scope]['navigation_world'])});\n"
        cursor = f"pg_temp.predecessor_cursor({literal(label)})"
        all_cases[scope]['navigation_page2'] = all_cases[scope]['navigation_world'].replace(',null,100)', ',' + cursor + ',100)')
        page2 = scope + ':navigation_page2'
        sql += f"select pg_temp.measure('baseline',{literal(page2)},-2,{literal(all_cases[scope]['navigation_page2'])});\n"
        all_cases[scope]['navigation_page3'] = all_cases[scope]['navigation_world'].replace(',null,100)', ',pg_temp.predecessor_cursor(' + literal(page2) + '),100)')
        branch = scope + ':navigation_geography'
        sql += f"select pg_temp.measure('baseline',{literal(branch)},-2,{literal(all_cases[scope]['navigation_geography'])});\n"
        all_cases[scope]['navigation_cn_page2'] = all_cases[scope]['navigation_geography'].replace(',null,1)', ',pg_temp.predecessor_cursor(' + literal(branch) + '),1)')
    if selected_cases:
        all_cases = {scope: {label: statement for label, statement in statements.items() if label in selected_cases}
                     for scope, statements in all_cases.items()}
    for ordinal in range(-1, samples):
        variants = list(definitions)
        if ordinal % 2:
            variants.reverse()
        for variant in variants:
            sql += 'reset role;\n' + definitions[variant]
            if ordinal == -1:
                sql += f"insert into variant_settings select {literal(variant)},jsonb_agg(jsonb_build_object('routine',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,'config',p.proconfig) order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('api','private') and (p.proname like 'display_%facet%' or p.proname like 'display_%navigation%' or p.proname in('portal_facets_v4','portal_navigation_v2','portal_display_brand_facets_v1'));\n"
            sql += "set local work_mem='4MB';set local statement_timeout='8s';set local role anon;\n"
            for scope, statements in all_cases.items():
                for label, statement in statements.items():
                    sql += f'select pg_temp.measure({literal(variant)},{literal(scope+":"+label)},{ordinal},{literal(statement)});\n'
    if include_plans:
        sql += "reset role;load 'auto_explain';set local auto_explain.log_min_duration=-1;set local auto_explain.log_analyze=on;set local auto_explain.log_timing=off;set local auto_explain.log_buffers=on;set local auto_explain.log_nested_statements=on;set local auto_explain.log_format=json;set local auto_explain.log_level=notice;\n"
        for variant, ddl in definitions.items():
            sql += "reset role;set local auto_explain.log_min_duration=-1;\n" + ddl + f"set local auto_explain.log_min_duration={plan_min_ms};set local role anon;\n"
            for scope in scopes:
                plan_cases = ('facets_all_empty', 'facets_flow_empty', 'facets_all_geography', 'facets_all_history', 'facets_all_current', 'facets_all_one', 'facets_all_combined', 'facets_flow_cas', 'navigation_world', 'navigation_classification_root', 'navigation_process_root', 'navigation_flow_root', 'navigation_filtered', 'navigation_geography', 'navigation_us', 'navigation_history', 'navigation_one')
                for label in dict.fromkeys(plan_cases + tuple(label for label in all_cases[scope] if 'cas' in label)):
                    if label not in all_cases[scope]:
                        continue
                    threshold = 0 if native_cas_fact and variant == 'candidate' and label in NATIVE_RARE_CASES else plan_min_ms
                    sql += f'reset role;set local auto_explain.log_min_duration={threshold};set local role anon;\n'
                    sql += f'select pg_temp.capture_plan({literal(variant)},{literal(scope+":"+label)},{literal(all_cases[scope][label])});\n'
        sql += 'reset role;set local auto_explain.log_min_duration=-1;\n'
    sql += """
reset role;
select jsonb_build_object(
 'fixtureActual',(__FIXTURE_SUMMARY__),
 'nativeSchema',(__NATIVE_SCHEMA__),
 'variantRoutineSettings',(select jsonb_object_agg(variant,routines) from variant_settings),
 'routineSettings',(select jsonb_agg(jsonb_build_object('routine',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,'config',p.proconfig) order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('api','private') and (p.proname like 'display_%facet%' or p.proname like 'display_%navigation%' or p.proname in('portal_facets_v4','portal_navigation_v2','portal_display_brand_facets_v1'))),
 'samples',(select jsonb_agg(jsonb_build_object('variant',variant,'label',label,'ordinal',ordinal,'ms',elapsed_ms,'error',error,
 'payload',payload,'canonicalJson',payload::text,'sha256',encode(extensions.digest(convert_to(payload::text,'UTF8'),'sha256'),'hex'),
 'sessionRole',session_role,'workMem',work_mem,'statementTimeout',statement_timeout) order by label,ordinal,variant) from measurements),
 'plans',(select coalesce(jsonb_agg(jsonb_build_object('variant',variant,'label',label,'plan',payload,'error',error) order by label,variant),'[]'::jsonb) from plans));
rollback;
"""
    return sql.replace("__FIXTURE_SUMMARY__", fixture_summary_sql(native_cas_fact).removesuffix(";")).replace('__NATIVE_SCHEMA__', native_schema_sql().removesuffix(';') if native_cas_fact else 'select null::jsonb'), all_cases


def summarize(report: dict, samples: int, scopes: tuple[str, ...], all_cases: dict, variants: tuple[str, ...]) -> list[str]:
    failures = []
    rows = report['samples']
    expected = {(variant, scope + ':' + label, ordinal) for variant in variants for scope in scopes for label in all_cases[scope] for ordinal in range(-1, samples)}
    actual = [(r['variant'], r['label'], r['ordinal']) for r in rows if r['ordinal'] >= -1]
    if len(actual) != len(set(actual)) or set(actual) != expected:
        failures.append('Missing/duplicate expected samples')
    for r in rows:
        if r['error'] or r['payload'] is None:
            failures.append(f"{r['variant']} {r['label']} {r['ordinal']}: {r['error'] or 'null payload'}")
        if (r['sessionRole'], r['workMem'], r['statementTimeout']) != ('anon', '4MB', '8s'):
            failures.append('Unexpected collector role/session budget')
    predecessors = [r for r in rows if r['ordinal'] == -2]
    report['cursorProof'] = len(predecessors) == 3*len(scopes) and all(r['payload'] and r['payload'].get('nextCursor') for r in predecessors)
    if not report['cursorProof']:
        failures.append('Predecessor continuation cursor proof missing')
    indexed = {(r['variant'], r['label'], r['ordinal']): r for r in rows}
    comparisons = []
    if 'candidate' in variants:
        for _, label, ordinal in sorted(key for key in expected if key[0] == 'baseline'):
            b, c = indexed.get(('baseline', label, ordinal)), indexed.get(('candidate', label, ordinal))
            equal = bool(b and c and b['canonicalJson'] == c['canonicalJson'] and not b['error'] and not c['error'])
            comparisons.append({'label': label, 'ordinal': ordinal, 'equal': equal})
            if not equal:
                failures.append(f'Response drift: {label} {ordinal}')
    report['equivalence'] = comparisons if 'candidate' in variants else None
    report['timings'] = {}
    for variant in variants:
        for label in sorted({r['label'] for r in rows if r['ordinal'] >= 0}):
            values = sorted(r['ms'] for r in rows if r['variant'] == variant and r['label'] == label and r['ordinal'] >= 0 and not r['error'])
            report['timings'][variant + ':' + label] = {'samples': len(values), 'medianMs': statistics.median(values) if values else None,
                'p95Ms': values[math.ceil(len(values)*.95)-1] if values else None, 'maxMs': max(values) if values else None}
    for plan in report['plans']:
        if plan['error'] or plan['plan'] is None:
            failures.append(f"Plan failed: {plan['variant']} {plan['label']} {plan['error']}")
    return failures


def nested_plans(log: str) -> dict:
    """Group nested auto_explain events by their closing top-level probe event.

    PostgreSQL logs each nested statement before the enclosing capture_plan
    SELECT. That final event carries the exact variant/label, so this does not
    guess identity from query text or matching execution duration.
    """
    if len(log) > MAX_GROUP_BYTES:
        raise ValueError('Legacy in-memory parser is limited to 16MB; use stream_nested_plans')
    decoder = json.JSONDecoder()
    pending, groups = [], []
    for match in re.finditer(r'NOTICE:  duration: ([0-9.]+) ms  plan:\n', log):
        plan, _ = decoder.raw_decode(log, match.end())
        pending.append({'durationMs': float(match[1]), 'explain': plan})
        closed = re.match(r"select pg_temp.capture_plan\('([^']*)','([^']*)',", plan.get('Query Text', ''))
        if closed:
            groups.append({'variant': closed[1], 'label': closed[2], 'nestedPlans': pending})
            pending = []
    return {'groups': groups, 'unassigned': pending}


def has_relation_plan(group: dict) -> bool:
    def visits(node):
        yield node
        for child in node.get('Plans', []):
            yield from visits(child)
    return any(node.get('Relation Name', '').startswith(('display_', 'dataset_display_'))
               for event in group['nestedPlans'] for node in visits(event['explain'].get('Plan', {})))


def plan_diagnostics(group: dict) -> dict:
    """Observation only: retain alternatives to an expression-index scan."""
    scans, settings, relations = [], [], []
    def visit(node, event):
        relation = node.get('Relation Name', '')
        condition, predicate = node.get('Index Cond', ''), node.get('Filter', '')
        cas_expression = (condition + predicate).lower().replace('_','')
        if relation or 'casnumber' in cas_expression:
            item = {key: node[key] for key in ('Node Type', 'Relation Name', 'Index Name', 'Index Cond',
                    'Filter', 'Plan Rows', 'Actual Rows', 'Actual Loops', 'Rows Removed by Filter',
                    'Shared Hit Blocks', 'Shared Read Blocks', 'Temp Read Blocks', 'Temp Written Blocks') if key in node}
            item['eventIndex'] = event
            if relation.startswith('display_'):
                relations.append(item.copy())
            if 'casnumber' in cas_expression or 'cas' in node.get('Index Name', '').lower():
                item['equalityIndexCond'] = 'casnumber' in condition.lower().replace('_','') and '=' in condition
                scans.append(item)
            if relation == 'dataset_display_settings':
                settings.append(item)
        for child in node.get('Plans', []):
            visit(child, event)
    for ordinal, event in enumerate(group['nestedPlans']):
        visit(event['explain'].get('Plan', {}), ordinal)
    return {'casScans': scans, 'settingsScans': settings, 'relationScans': relations,
            'equalityIndexCondObserved': any(node['equalityIndexCond'] for node in scans)}


def native_plan_gate(groups: list[dict], scopes: tuple[str, ...]) -> tuple[list[dict], list[str]]:
    evidence, failures = [], []
    indexed = {(g['variant'],g['label']):g for g in groups}
    for scope in scopes:
        for case in NATIVE_RARE_CASES:
            label = scope+':'+case
            group = indexed.get(('candidate',label), {})
            diagnostics = group.get('casDiagnostics') or {}
            lookups = [node for node in diagnostics.get('casScans', [])
                       if re.search(r'\bcas_number\b',node.get('Index Cond','')) and '=' in node['Index Cond'] and "'50-00-0'" in node['Index Cond']]
            examined = [(node.get('Actual Rows',0)+node.get('Rows Removed by Filter',0))*node.get('Actual Loops',0) for node in lookups]
            passed = bool(lookups) and all(0 < rows <= 2 for rows in examined)
            event_ids = {node['eventIndex'] for node in lookups}
            settings = [node for node in diagnostics.get('settingsScans',[]) if node['eventIndex'] in event_ids]
            evidence.append({'label':label,'passed':passed,'nativeLookups':lookups,'examinedRowsPerLookup':examined,'visibilityScans':settings})
            if not passed: failures.append('Native rare Flow equality/bounded lookup proof missing: '+label)
    return evidence, failures


def relative_cas_evidence(timings: dict, labels: list[str], baseline_prefix: str = 'baseline:', candidate_prefix: str = 'candidate:', metric: str = 'p95Ms', enforce: bool = True) -> tuple[list[dict], list[str]]:
    evidence, failures = [], []
    for label in labels:
        match = re.search(r':(?:facets|navigation)_(flow|all|process)_cas_(rare|absent|common)$',label)
        if not match: continue
        kind, shape = match.groups()
        baseline = timings.get(baseline_prefix+label,{}).get(metric)
        candidate = timings.get(candidate_prefix+label,{}).get(metric)
        bound = (max(baseline*1.1,baseline+10) if shape == 'common' else baseline*.5) if baseline is not None else None
        gated = enforce and kind != 'process'
        passed = baseline is not None and baseline > 0 and candidate is not None and candidate <= bound
        evidence.append({'label':label,'baselineP95Ms':baseline,'candidateP95Ms':candidate,'candidateBaselineRatio':candidate/baseline if baseline and candidate is not None else None,'maximumCandidateP95Ms':bound,'enforced':gated,'passed':passed})
        if gated and not passed: failures.append('CAS relative performance requirement failed: '+label)
    return evidence, failures


def iter_log_events(path: Path):
    """Yield one bounded plan or explicit probe boundary at a time."""
    total = size = depth = 0
    parts = []
    duration = None
    in_string = escaped = False
    with path.open('rb') as source:
        while raw := source.readline(MAX_PLAN_BYTES + 1):
            total += len(raw)
            if total > MAX_LOG_BYTES or len(raw) > MAX_PLAN_BYTES:
                raise ValueError('Nested log/line limit exceeded')
            line = raw.decode('utf-8')
            marker = re.match(r'NOTICE:  portal864_plan_(begin|end):(.*)', line)
            if marker:
                if parts:
                    raise ValueError('Incomplete nested plan at probe boundary')
                yield marker[1], json.loads(marker[2]), len(raw)
                duration = None
                continue
            notice = re.match(r'NOTICE:  duration: ([0-9.]+) ms  plan:', line)
            if notice:
                if parts:
                    raise ValueError('Nested plan interrupted by another notice')
                duration = float(notice[1])
                continue
            if duration is None:
                continue
            if not parts and not line.lstrip().startswith('{'):
                continue
            parts.append(line)
            size += len(raw)
            if size > MAX_PLAN_BYTES:
                raise ValueError('Single nested plan limit exceeded')
            for char in line:
                if in_string:
                    if escaped:
                        escaped = False
                    elif char == chr(92):
                        escaped = True
                    elif char == '"':
                        in_string = False
                elif char == '"':
                    in_string = True
                elif char in '{[':
                    depth += 1
                elif char in '}]':
                    depth -= 1
            if depth == 0:
                yield 'plan', {'durationMs': duration, 'explain': json.loads(''.join(parts))}, size
                parts, size, duration = [], 0, None
        if parts:
            raise ValueError('Truncated final nested plan')


def stream_nested_plans(log_path: Path, artifact_path: Path) -> dict:
    """Keep at most one 16MB probe group in memory and stream the artifact."""
    summaries = []
    current = None
    group_bytes = 0
    with private_output(artifact_path) as binary:
        def write(value):
            binary.write(value.encode())
        write('{"groups":[')
        for kind, value, count in iter_log_events(log_path):
            if kind == 'begin':
                if current is not None:
                    raise ValueError('Overlapping nested plan groups')
                current = dict(value, nestedPlans=[])
                group_bytes = 0
            elif kind == 'end':
                if current is None or any(current[key] != value[key] for key in ('variant', 'label')):
                    raise ValueError('Nested plan boundary identity mismatch')
                if summaries:
                    write(',')
                write(json.dumps(current))
                summaries.append({'variant': current['variant'], 'label': current['label'],
                                  'eventCount': len(current['nestedPlans']),
                                  'nestedPlanBytes':group_bytes,
                                  'naturalRelationPlan': has_relation_plan(current),
                                  'casDiagnostics': plan_diagnostics(current) if 'cas' in current['label'] else None})
                current = None
            elif current is not None:
                group_bytes += count
                if group_bytes > MAX_GROUP_BYTES:
                    raise ValueError('Single nested probe group limit exceeded')
                current['nestedPlans'].append(value)
            elif not value['explain'].get('Query Text', '').startswith('select pg_temp.capture_plan('):
                raise ValueError('Unassigned nested plan outside explicit probe group')
        if current is not None:
            raise ValueError('Unclosed nested plan group')
        write('],"unassignedCount":0}\n')
    return {'groups': summaries, 'unassignedCount': 0}


def validate_target(context: dict, inspected: dict, owner: str) -> None:
    endpoint = context['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://') or os.environ.get('DOCKER_HOST') not in (None, '', endpoint):
        raise ValueError('Only the current local Unix Docker endpoint is admitted')
    if inspected['Name'].lstrip('/') != CONTAINER or (inspected['Config'].get('Labels') or {}).get('com.supabase.cli.project') != PROJECT:
        raise ValueError('Exact task CLI project/container required')
    if not re.search(r'(?:tiangong-lca/)?database\s*#864\b', owner, re.I) or PROJECT not in owner:
        raise ValueError('OWNER must explicitly bind database#864 and portal-facets-864')
    if not inspected['State']['Running']:
        raise ValueError('Task database container is not running')


def guard_sql() -> str:
    """Read-only socket/version/empty-source guard shared with upgrade tooling."""
    return "select inet_server_addr() is null;select current_setting('server_version');" + ''.join(f'select count(*) from {table};' for table in TABLES) + "select count(*) from pg_stat_activity where application_name='portal864-serial' and pid<>pg_backend_pid();"


def empty_guard_expected() -> list[str]:
    return ['t', '17.11'] + ['0'] * (len(TABLES)+1)


def bounded_int(minimum: int, maximum: int):
    def parse(value: str) -> int:
        try:
            number = int(value)
        except ValueError as exc:
            raise argparse.ArgumentTypeError('Expected an integer') from exc
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f'Expected {minimum}..{maximum}')
        return number
    return parse


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', required=True, choices=[CONTAINER])
    parser.add_argument('--base-ref', required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--candidate', type=Path)
    mode.add_argument('--baseline-only', action='store_true')
    parser.add_argument('--owner-file', type=Path, default=OWNER, choices=[OWNER])
    parser.add_argument('--samples', type=bounded_int(2, 20), default=10, metavar='2..20')
    parser.add_argument('--process-datasets', type=bounded_int(20, 20000), default=9500, metavar='20..20000')
    parser.add_argument('--flow-datasets', type=bounded_int(40, 100000), default=69000, metavar='40..100000')
    parser.add_argument('--card-padding', type=bounded_int(0, 4096), default=1024, metavar='0..4096')
    parser.add_argument('--fixture-profile', choices=FIXTURE_PROFILES, default='legacy')
    parser.add_argument('--native-cas-fact', action='store_true', help='Use already-installed native CAS fact/index; cas-dense only, reader SQL comparison on one physical schema')
    parser.add_argument('--plan-min-ms', type=bounded_int(1, 1000), metavar='1..1000', help='Nested plan threshold: smoke default 1ms, volume default 10ms')
    parser.add_argument('--case', dest='selected_cases', action='append', choices=sorted(set(cases('tiangong_lca', 'cas-dense')) | {'navigation_page2', 'navigation_page3', 'navigation_cn_page2'}), metavar='CASE', help='Repeat to select representative cases; default is full matrix')
    parser.add_argument('--smoke', action='store_true', help='20 Process/40 Flow datasets, two samples; never volume proof')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.native_cas_fact and (args.fixture_profile != 'cas-dense' or not args.candidate):
        parser.error('--native-cas-fact requires cas-dense and a candidate')
    available = set(cases('tiangong_lca', args.fixture_profile)) | {'navigation_page2', 'navigation_page3', 'navigation_cn_page2'}
    if args.selected_cases and (len(set(args.selected_cases)) != len(args.selected_cases) or not set(args.selected_cases).issubset(available)):
        parser.error('Duplicate or unavailable case for fixture profile')
    paths = (args.report, args.report.with_suffix('.sql'), args.report.with_suffix('.log'), args.report.with_suffix('.plans.json'), args.report.with_suffix('.stdout.jsonl'), args.report.with_suffix('.collector.py'))
    if len(set(paths)) != 6 or any(path.exists() for path in paths):
        parser.error('Report/.sql/.log/.plans.json evidence paths must be distinct and new')
    if args.smoke:
        args.process_datasets, args.flow_datasets, args.samples = 20, 40, 2
    try:
        context = json.loads(subprocess.check_output(['docker', 'context', 'inspect'], text=True))[0]
        inspect_format = '{"Id":{{json .Id}},"Name":{{json .Name}},"Config":{"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}}},"State":{"Running":{{json .State.Running}}},"HostConfig":{"NanoCpus":{{json .HostConfig.NanoCpus}},"CpuQuota":{{json .HostConfig.CpuQuota}},"CpuPeriod":{{json .HostConfig.CpuPeriod}},"CpusetCpus":{{json .HostConfig.CpusetCpus}},"Memory":{{json .HostConfig.Memory}},"MemorySwap":{{json .HostConfig.MemorySwap}}}}'
        inspected = json.loads(subprocess.check_output(['docker', 'inspect', '--format', inspect_format, CONTAINER], text=True))
        owner = args.owner_file.read_text()
        validate_target(context, inspected, owner)
        base = subprocess.check_output(['git', 'rev-parse', f'{args.base_ref}^{{commit}}'], cwd=ROOT, text=True).strip()
        candidate = args.candidate.read_text() if args.candidate else None
        candidate_defs = reader_definitions(candidate) if candidate is not None else None
        baseline_defs = baseline(base, list(candidate_defs) if candidate_defs else [('function', name) for name in BASELINE_READERS])
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    guard = guard_sql()
    expected = empty_guard_expected()
    checked = run(guard, 60)
    if checked.returncode or checked.stdout.strip().splitlines() != expected:
        parser.error('Refusing unknown/nonempty/nonlocal/wrong-version database')
    native_schema = None
    if args.native_cas_fact:
        try:
            checked_schema = run(native_schema_sql(),60)
            if checked_schema.returncode:
                raise ValueError('Native CAS metadata query failed')
            native_schema = json.loads(checked_schema.stdout)
            validate_native_schema(native_schema)
        except (ValueError,KeyError,TypeError) as exc:
            parser.error(str(exc))
    plan_min_ms = args.plan_min_ms or (1 if args.smoke else 10)
    variants = {'baseline': definitions_sql(baseline_defs)}
    if candidate_defs:
        variants['candidate'] = definitions_sql(candidate_defs)
    scopes = ('tiangong_lca', 'bafu,tiangong_lca,uslci,worldsteel')
    sql, all_cases = build_sql(variants, args.process_datasets, args.flow_datasets, args.card_padding, args.samples, scopes, selected_cases=args.selected_cases, plan_min_ms=plan_min_ms, fixture_profile=args.fixture_profile, native_cas_fact=args.native_cas_fact)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with private_output(args.report.with_suffix('.sql')) as output:
        output.write(sql.encode())
    collector_source = Path(__file__).read_bytes()
    with private_output(args.report.with_suffix('.collector.py')) as output:
        output.write(collector_source)
    report = {'schemaVersion': 'portal.facets-navigation-serial.v1', 'passed': False,
        'classification': 'local synthetic rollback-only warm reader samples; smoke' if args.smoke else 'local synthetic rollback-only warm reader samples; volume',
        'baseCommit': base, 'baselineSourceSha256': sha(variants['baseline']),
        'candidatePath': str(args.candidate) if args.candidate else None,
        'candidateSha256': sha(candidate) if candidate is not None else None,
        'candidateReaderSha256': sha(variants['candidate']) if 'candidate' in variants else None,
        'readerNames': [name for _, name in baseline_defs], 'collectorSha256': sha(collector_source), 'collectorArtifact': str(args.report.with_suffix('.collector.py')),
        'nestedPlanMinDurationMs': plan_min_ms, 'artifactLimits': {'logBytes': MAX_LOG_BYTES, 'stdoutBytes': MAX_STDOUT_BYTES, 'singlePlanBytes': MAX_PLAN_BYTES, 'singleGroupBytes': MAX_GROUP_BYTES},
        'scopedZeroMsPlanCapture': {'variant':'candidate','cases':list(NATIVE_RARE_CASES),'scopes':list(scopes)} if args.native_cas_fact else None,
        'relativeCasPolicy': {'rareAbsentMaximumP95Ratio':.5,'commonMaximumP95Ratio':1.1,'commonNoiseAllowanceMs':10,'kinds':['flow','all'],'enforced':not args.smoke} if args.native_cas_fact else None,
        'nativeSchemaBefore':native_schema,'nativeSchemaFingerprint':schema_fingerprint(native_schema) if native_schema else None,
        'physicalSchemaComparison':'same installed final schema/index/writer in both reader phases; upgrade proof is separate' if args.native_cas_fact else 'existing schema',
        'candidateLocalP95TargetMs': 2000,
        'sqlSha256': sha(sql), 'ownerSha256': sha(owner), 'containerId': inspected['Id'],
        'dockerContext': context['Name'], 'image': inspected['Config']['Image'],
        'resources': {key: inspected['HostConfig'].get(key) for key in ('NanoCpus', 'CpuQuota', 'CpuPeriod', 'CpusetCpus', 'Memory', 'MemorySwap')},
        'selectedCases': args.selected_cases or 'full matrix',
        'fixture': fixture_metadata(args.process_datasets, args.flow_datasets, args.card_padding, args.fixture_profile, args.native_cas_fact),
        'unresolvedProof': ['populated full migration upgrade/failure/repeat', 'real source writers', 'concurrent load', 'hosted production latency'],
        'sourceRowsFabricated': False, 'sessionWorkMem': '4MB', 'requestBudget': '8s',
        'baselineOnly': args.baseline_only, 'candidateRestored': 'transaction rollback', 'cleanup': None}
    try:
        result = run_logged(args.report.with_suffix('.sql'), args.report.with_suffix('.stdout.jsonl'), args.report.with_suffix('.log'))
        parsed_plans = stream_nested_plans(args.report.with_suffix('.log'), args.report.with_suffix('.plans.json'))
        report['nestedPlanArtifact'] = str(args.report.with_suffix('.plans.json'))
        report['nestedPlanArtifactSha256'] = file_sha(args.report.with_suffix('.plans.json'))
        report['artifactActualBytes'] = {suffix:args.report.with_suffix(suffix).stat().st_size for suffix in ('.log','.stdout.jsonl','.plans.json')}
        if result.returncode:
            report['failure'] = f'psql exited {result.returncode}; inspect local log'
        else:
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            if len(rows) != 1:
                raise ValueError('Unique complete benchmark result required')
            report.update(rows[0])
            failures = summarize(report, args.samples, scopes, all_cases, tuple(variants))
            plan_keys = {(group['variant'], group['label']) for group in parsed_plans['groups']}
            expected_plan_keys = {(plan['variant'], plan['label']) for plan in report['plans']}
            report['nestedPlanCoverage'] = parsed_plans
            if parsed_plans['unassignedCount'] or plan_keys != expected_plan_keys or len(plan_keys) != len(parsed_plans['groups']):
                failures.append('Missing/duplicate/unassigned nested auto_explain plan groups')
            if not args.smoke and any(not group['naturalRelationPlan'] for group in parsed_plans['groups']):
                failures.append('Nested natural relation plan missing')
            if report['fixtureActual']['processVersions'] != 2*args.process_datasets or report['fixtureActual']['flowVersions'] != 2*args.flow_datasets:
                failures.append('Actual fixture cardinality mismatch')
            if args.fixture_profile == 'cas-dense' and report['fixtureActual']['casCounts'] != expected_dense_cas_counts(args.flow_datasets):
                failures.append('Dense CAS distribution or document invariant mismatch')
            if args.native_cas_fact:
                expected_native = expected_dense_cas_counts(args.flow_datasets)
                if report['fixtureActual'].get('nativeCasFact') != {k:expected_native[k] for k in ('nonNull','rare','common')} | {'mismatches':0}:
                    failures.append('Native CAS fact differs from original V1 predicate')
                if validate_native_schema(report['nativeSchema']) != report['nativeSchemaFingerprint']:
                    failures.append('Native CAS physical schema changed during reader comparison')
                report['nativeRarePlanEvidence'], plan_failures = native_plan_gate(parsed_plans['groups'],scopes)
                failures.extend(plan_failures)
                labels = [scope+':'+label for scope in scopes for label in all_cases[scope]]
                report['relativeCasPerformance'], relative_failures = relative_cas_evidence(report['timings'],labels,enforce=not args.smoke)
                failures.extend(relative_failures)
                if not args.smoke:
                    required = {f'{api}_{kind}_cas_{shape}' for api in ('facets','navigation') for kind in ('flow','all') for shape in ('rare','absent','common')}
                    if any(not required.issubset(all_cases[scope]) for scope in scopes):
                        failures.append('Native volume proof requires Flow/all rare/absent/common Facets/Navigation cases')
            candidate_times = {key: value for key, value in report['timings'].items() if key.startswith('candidate:')}
            target = {key: value['p95Ms'] is not None and value['p95Ms'] <= 2000 for key, value in candidate_times.items()}
            report['candidateLocalP95TargetPassed'] = all(target.values()) if target else None
            report['candidateLocalP95ByCase'] = target or None
            failures.extend('Candidate local p95 exceeds 2000ms: ' + key for key, passed in target.items() if not passed)
            report['failures'] = failures
            report['passed'] = not failures
    except BaseException as exc:
        report['failure'] = type(exc).__name__ + ': ' + str(exc)
        report['passed'] = False
        if isinstance(exc, KeyboardInterrupt):
            raise
    finally:
        cleanup = run(guard, 60)
        report['cleanup'] = {'emptyRowsAndLocalIdentityVerified': cleanup.returncode == 0 and cleanup.stdout.strip().splitlines() == expected,
                             'physicalPagesAndPlannerStatisticsMayRemain': True, 'resetBeforeConcurrentOrOtherQualification': True}
        if not report['cleanup']['emptyRowsAndLocalIdentityVerified']:
            report['passed'] = False
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'report': str(args.report), 'passed': report['passed'], 'baselineOnly': args.baseline_only,
                      'comparisons': len(report.get('equivalence') or []), 'failures': report.get('failures', report.get('failure')),
                      'artifactActualBytes':report.get('artifactActualBytes'),
                      'cleanup': report['cleanup']}, indent=2))
    return int(not report['passed'])


if __name__ == '__main__':
    sys.exit(main())
