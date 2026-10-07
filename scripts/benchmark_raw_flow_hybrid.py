#!/usr/bin/env python3
"""Database #793 exact-owned-local raw Flow Hybrid attribution; synthetic only.

Fixtures commit to permit VACUUM/visibility realism. Finally removes only this
run's synthetic rows, restoring captured triggers, indexes and function body.
No remote URL, reset, production transport, or planner forcing is supported.
"""
import argparse
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = 'supabase_db_database-engine-793'
PROJECT = 'database-engine-793'
SIGNATURE = 'private.hybrid_search_flows_v2_impl(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])'
LEXICAL_SIGNATURE = 'private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])'
OWNER = 'a7930000-0000-0000-0000-000000000001'


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def lexical_kernel(definition, bindings):
    """Expand the actual format argument order; never assume predecessor order."""
    match = re.search(r'v_sql\s*:=\s*format\(\$sql\$(.*?)\$sql\$\s*,\s*([^;]+?)\)\s*;', definition, re.S)
    if not match:
        raise ValueError('Unrecognized lexical dynamic template boundary')
    template, arguments = match.groups()
    arguments = [value.strip() for value in arguments.split(',')]
    clauses = {'text_match_clause': 'where f.search_text &@~| $14', 'json_filter_clause': ''}
    if template.count('%s') != len(arguments) or any(value not in clauses for value in arguments):
        raise ValueError('Unrecognized lexical format arguments; explicit review required')
    for argument in arguments:
        template = template.replace('%s', clauses[argument], 1)
    return re.sub(r'\$(\d+)', lambda value: bindings[int(value.group(1))], template)


def lexical_score_kernel(kernel):
    # This full ordered score/rank diagnostic reuses the real match/group/latest
    # and rank CTEs. Only the final payload/page projection is removed.
    marker = 'select paged_rows.rank, paged_rows.id'
    if kernel.count(marker) != 1:
        raise ValueError('Unrecognized lexical final projection; score probe refused')
    return kernel.split(marker, 1)[0] + 'select r.rank,r.id,r.search_score,r.version,r.modified_at,r.total_count from ranked_rows r order by r.rank,r.id'


def lexical_gate_probe(definition):
    """Run the candidate's actual prelude, not a guessed selectivity flag."""
    if 'use_type_keys' not in definition:
        prefix="begin return jsonb_build_object('use_type_keys',false,'gatePresent',false);"
    else:
        match=re.search(r'\bAS\s+(\$[A-Za-z0-9_]*\$)(.*?)\1',definition,re.S|re.I)
        if not match or '  v_sql := format($sql$' not in match.group(2):
            raise ValueError('Unrecognized gate prelude boundary')
        prefix=match.group(2).split('  v_sql := format($sql$',1)[0]
        marker='  if exact_query_id is not null then'
        if marker in prefix:
            before,tail=prefix.split(marker,1)
            after='  json_filter_clause := case'
            if after not in tail:
                raise ValueError('Unrecognized UUID early-return boundary')
            prefix=before+"  if exact_query_id is not null then raise exception 'gate probe excludes UUID path';end if;\n"+after+tail.split(after,1)[1]
        prefix+="return jsonb_build_object('use_type_keys',coalesce(use_type_keys,false),'gatePresent',true,'requestedTypes',flow_type_array);"
    return "create function pg_temp.gate793(query_text text,filter_condition jsonb,page_size bigint,page_current bigint,data_source text,this_user_id text,team_id_filter uuid,state_code_filter integer,query_terms text[]) returns jsonb language plpgsql security definer as $gate$"+prefix+"end;$gate$;grant execute on function pg_temp.gate793(text,jsonb,bigint,bigint,text,text,uuid,integer,text[]) to authenticated,api_internal_executor;"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local-container', required=True)
    parser.add_argument('--rows', type=int, default=135000)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--candidate-file', type=Path)
    parser.add_argument('--lexical-candidate-file', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.local_container != CONTAINER:
        parser.error('Only the exact task-owned Database #793 container is accepted')
    if not 100 <= args.rows <= 150000 or not 2 <= args.samples <= 30:
        parser.error('rows must be 100..150000 and samples 2..30; small rows are harness checks only')
    if os.environ.get('DOCKER_HOST') or os.environ.get('DOCKER_CONTEXT'):
        parser.error('Docker endpoint overrides are refused; use the selected local Unix-socket context')
    context = json.loads(subprocess.check_output(['docker','context','inspect'],text=True))[0]
    endpoint = context['Endpoints']['docker']['Host']
    if not endpoint.startswith('unix://'):
        parser.error('Only a local Unix-socket Docker endpoint is accepted')
    inspected = json.loads(subprocess.check_output(['docker', 'inspect', CONTAINER], text=True))[0]
    labels = inspected['Config']['Labels']
    if (inspected['Name'] != '/' + CONTAINER or
            labels.get('com.supabase.cli.project') != PROJECT or
            labels.get('com.docker.compose.project') != PROJECT or
            not labels.get('com.supabase.cli.workdir', '').endswith('/local-793')):
        raise SystemExit('Exact container/project/workdir ownership mismatch')
    cmd = ['docker', 'exec', '-i', CONTAINER, 'psql', '-XqAt', '-v',
           'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres']
    output = args.output.resolve()
    if output.exists() or output.with_suffix('.raw.log').exists():
        parser.error('Use a fresh output prefix; retained evidence must not be overwritten')
    output.parent.mkdir(parents=True, exist_ok=True)
    records = []
    report = {'benchmark': 'raw-flow-hybrid-attribution.v1', 'profile': 'isolated-synthetic',
              'containerId': inspected['Id'], 'container': CONTAINER,
              'image': inspected['Config']['Image'], 'rowsRequested': args.rows,
              'samples': args.samples, 'productionScaleFixture': args.rows >= 100000,
              'scriptSha256': sha(Path(__file__).read_text()),
              'records': records, 'cleanup': {'completed': False}}

    def save():
        output.write_text(json.dumps(report, indent=2) + '\n')

    def sql(query, timeout=1800):
        started = time.monotonic()
        run = subprocess.run(cmd, input=query, text=True, capture_output=True, timeout=timeout)
        with output.with_suffix('.raw.log').open('a') as log:
            log.write(run.stdout + run.stderr)
        if run.returncode:
            raise RuntimeError('Local SQL failed; inspect the private raw log')
        for line in run.stdout.splitlines():
            if line.startswith('{'):
                item = json.loads(line)
                records.append(item)
                if 'stage' in item:
                    print(json.dumps({k: v for k, v in item.items()
                                      if k not in ('plan', 'settings', 'definition')}), flush=True)
        save()
        return run.stdout, time.monotonic() - started

    def scalar(query):
        return subprocess.check_output(cmd + ['-c', query], text=True).strip()

    preflight = json.loads(scalar("select jsonb_build_object('rows',(select count(*) from public.flows),"
        "'head',(select max(version) from supabase_migrations.schema_migrations),"
        "'version',version(),'extensions',(select jsonb_object_agg(extname,extversion) from pg_extension "
        "where extname in ('pgroonga','vector','pgcrypto')),'indexes',"
        "(select jsonb_agg(jsonb_build_object('name',c.relname,'definition',pg_get_indexdef(i.indexrelid),"
        "'constraint',exists(select 1 from pg_constraint k where k.conindid=i.indexrelid),"
        "'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive) order by c.relname) "
        "from pg_index i join pg_class c on c.oid=i.indexrelid where i.indrelid='public.flows'::regclass),"
        "'triggers',(select jsonb_agg(jsonb_build_object('name',tgname,'enabled',tgenabled) order by tgname) "
        "from pg_trigger where tgrelid='public.flows'::regclass and not tgisinternal));"))
    if preflight['rows'] or preflight['head'] != '20261006094513':
        raise SystemExit('Empty exact Main baseline required; never clears existing data')
    if preflight['extensions'].get('pgroonga') != '3.2.5':
        raise SystemExit('Unqualified PGroonga version')
    if not all(i['valid'] and i['ready'] and i['live'] for i in preflight['indexes']):
        raise SystemExit('Baseline indexes must be healthy')
    def metadata_query(signature):
        return "select jsonb_build_object('owner',pg_get_userbyid(proowner),'acl',proacl::text,'definer',prosecdef,'volatility',provolatile,'config',proconfig,'parallel',proparallel,'strict',proisstrict,'leakproof',proleakproof,'cost',procost,'rows',prorows,'language',(select lanname from pg_language where oid=prolang),'support',prosupport::text) from pg_proc where oid="+quote(signature)+"::regprocedure;"
    function_meta_query=metadata_query(SIGNATURE)
    function_metadata=json.loads(scalar(function_meta_query))
    baseline_definition = scalar('select pg_get_functiondef(' + quote(SIGNATURE) + '::regprocedure);')
    baseline = baseline_definition.rstrip().rstrip(';')+';\n'
    candidate = args.candidate_file.read_text() if args.candidate_file else baseline
    if not re.match(r'\s*CREATE OR REPLACE FUNCTION\s+"?private"?\."?hybrid_search_flows_v2_impl"?\(', candidate, re.I):
        raise SystemExit('Candidate must replace only the reviewed raw private implementation')
    lexical = scalar('select pg_get_functiondef('+quote(LEXICAL_SIGNATURE)+'::regprocedure);')
    lexical_baseline=lexical.rstrip().rstrip(';')+';\n'
    lexical_candidate=args.lexical_candidate_file.read_text() if args.lexical_candidate_file else lexical_baseline
    if not re.match(r'\s*CREATE OR REPLACE FUNCTION\s+"?private"?\."?search_flows_latest_impl"?\(',lexical_candidate,re.I):
        raise SystemExit('Lexical candidate must replace the reviewed lexical helper')
    lexical_meta_query=metadata_query(LEXICAL_SIGNATURE)
    lexical_metadata=json.loads(scalar(lexical_meta_query))
    semantic = scalar("select pg_get_functiondef('private.semantic_flow_candidates(text,text,double precision,integer,text)'::regprocedure);")
    report.update({'baselineDefinitionSha256': sha(baseline_definition), 'candidateSha256': sha(candidate),
                   'lexicalDefinitionSha256': sha(lexical), 'semanticDefinitionSha256': sha(semantic),
                   'lexicalCandidateSha256':sha(lexical_candidate),'lexicalMetadata':lexical_metadata,
                   'lexicalCandidateFile':str(args.lexical_candidate_file) if args.lexical_candidate_file else None,
                   'preflight': preflight, 'functionMetadata': function_metadata,
                   'candidateFile': str(args.candidate_file) if args.candidate_file else None})
    output.with_suffix('.baseline.sql').write_text(baseline)
    output.with_suffix('.candidate.sql').write_text(candidate)
    output.with_suffix('.lexical-baseline.sql').write_text(lexical_baseline)
    output.with_suffix('.lexical-candidate.sql').write_text(lexical_candidate)
    marker = 'raw-flow-793:' + sha(str(output))[:16]
    report['fixtureMarker'] = marker
    nonconstraints = [i for i in preflight['indexes'] if not i['constraint']]
    triggers = preflight['triggers'] or []
    restore_triggers = '\n'.join('alter table public.flows ' + {
        'O': 'enable trigger ', 'D': 'disable trigger ', 'R': 'enable replica trigger ',
        'A': 'enable always trigger '}[t['enabled']] + ident(t['name']) + ';' for t in triggers)
    # Orthogonal-ish Fourier bases with a monotonically separated angle range.
    # The top distances are deliberately away from zero, avoiding float32
    # saturation ties; actual baseline repeatability is still checked.
    vector_expr = "array(select (cos(0.30+g*0.000006)*sin(d*2*pi()/1024)+sin(0.30+g*0.000006)*cos(d*2*pi()/1024)+0.00317)::real from generate_series(1,1024) d)::extensions.vector(1024)"
    query_vector = '[' + ','.join(f'{math.sin(d*2*math.pi/1024)+0.00317:.9g}' for d in range(1, 1025)) + ']'
    report['queryVectorSha256'] = sha(query_vector)
    setup = f"""begin;
set local statement_timeout='0';set local maintenance_work_mem='2GB';
lock table public.flows in access exclusive mode;
do $$begin if exists(select 1 from public.flows) then raise exception 'nonempty fixture target';end if;end$$;
alter table public.flows disable trigger user;
{''.join('drop index public.' + ident(i['name']) + ';' for i in nonconstraints)}
insert into public.flows(id,version,json,json_ordered,user_id,state_code,created_at,modified_at,embedding_ft,search_text)
select md5('raw793:'||(g/3)::text)::uuid,
 '01.00.00'||(g%3)::text,
 jsonb_build_object('_raw793', {quote(marker)},'syntheticRow',g,
   'flowDataSet',jsonb_build_object(
    'flowInformation',jsonb_build_object('dataSetInformation',jsonb_build_object(
     'name',jsonb_build_array(jsonb_build_object('@lang','en','#text','Electricity transfer'),jsonb_build_object('@lang','zh','#text','电力合成夹具')),
     'classificationInformation',jsonb_build_object('common:classification',jsonb_build_object('common:class',jsonb_build_array(jsonb_build_object('@level','0','@classId','793','#text','Energy')))),
     'generalComment',repeat('Structured synthetic lifecycle inventory description. ',32))),
    'modellingAndValidation',jsonb_build_object('LCIMethod',jsonb_build_object('typeOfDataSet',case when g%31=0 then 'Product flow' else 'Elementary flow' end)),
    'administrativeInformation',jsonb_build_object('publicationAndOwnership',jsonb_build_object('common:dataSetVersion','01.00.00'||(g%3)::text))),
   'entropy',(select string_agg(md5(g::text||':'||j::text),'') from generate_series(1,48) j)),
 '{{}}', {quote(OWNER)}::uuid,
 case when (g/3)%100<81 then 100 when (g/3)%100<84 then 200 else 0 end,
 '2026-01-01'::timestamptz+g*interval '1 second',
 '2026-01-01'::timestamptz+g*interval '1 second',
 case when g%503=0 then null else {vector_expr} end,
    array[case when g%97=0 then 'solar energy sparse raw793' else 'electricity power energy raw793' end] ||
    array(select case when j<=1+g%5 then repeat('electricity power ',1+g%4)
          else repeat('Synthetic classification material lifecycle inventory ',1+g%3) end||j::text
          from generate_series(1,4+g%13) j)
from generate_series(3,{args.rows + 2}) g;
{''.join(i['definition'] + ';' for i in nonconstraints)}
{restore_triggers}
commit;
vacuum(analyze) public.flows;
begin;alter table public.flows disable trigger user;
update public.flows set modified_at=modified_at where json->>'_raw793'={quote(marker)} and (json->>'syntheticRow')::int>{int(args.rows * .73)};
{restore_triggers}
commit;analyze public.flows;
select jsonb_build_object('stage','fixture','rowCount',count(*),'idCount',count(distinct id),
 'nonzeroVectorRows',count(embedding_ft),'stateCounts',(select jsonb_object_agg(state_code,n) from (select state_code,count(*) n from public.flows group by state_code) x),
 'jsonStoredAvg',round(avg(pg_column_size(json))),'jsonTextAvg',round(avg(octet_length(json::text))),
 'searchTextStoredAvg',round(avg(pg_column_size(search_text))),
 'searchTextStoredMin',min(pg_column_size(search_text)),'searchTextStoredMax',max(pg_column_size(search_text)),
 'heapBytes',pg_relation_size('public.flows'),'totalBytes',pg_total_relation_size('public.flows'),
 'toastBytes',pg_total_relation_size((select reltoastrelid from pg_class where oid='public.flows'::regclass)),
 'allVisiblePages',(select relallvisible from pg_class where oid='public.flows'::regclass),
 'heapPages',(select relpages from pg_class where oid='public.flows'::regclass),
 'identityDigest',md5(string_agg(id::text||'@'||version::text||':'||(json->>'syntheticRow'),'|' order by id,version)),
 'indexSizes',(select jsonb_object_agg(c.relname,pg_relation_size(c.oid)) from pg_index i join pg_class c on c.oid=i.indexrelid where i.indrelid='public.flows'::regclass)) from public.flows;
"""
    output.with_suffix('.fixture.sql').write_text(setup)
    report['fixtureSqlSha256'] = sha(setup)
    config = "set local search_path=private,api,public,util,extensions,pg_temp;set local jit=off;set local work_mem='12MB';set local statement_timeout='180s';"
    auth = f"set local role authenticated;select set_config('request.jwt.claims',{quote(json.dumps({'role':'authenticated','sub':OWNER}))},true);"
    measure = """create function pg_temp.measure793(p_query text) returns jsonb language plpgsql as $$
declare started timestamptz;result jsonb;begin
started:=clock_timestamp();execute 'select coalesce(jsonb_agg(to_jsonb(r)-''ordinality'' order by r.ordinality),''[]''::jsonb) from '||p_query||' with ordinality r' into result;
return jsonb_build_object('ms',round((extract(epoch from clock_timestamp()-started)*1000)::numeric,3),
'digest',md5(result::text),'rows',jsonb_array_length(result),'serializedBytes',octet_length(result::text),'totalCount',result->0->'total_count');end$$;
create function pg_temp.plan793(p_query text) returns jsonb language plpgsql as $$declare p jsonb;begin
execute 'explain(analyze,buffers,settings,format json) '||p_query into p;return p;end$$;
create function pg_temp.definer_plan793(p_query text) returns jsonb language plpgsql security definer as $$declare p jsonb;begin
execute 'explain(analyze,buffers,settings,format json) '||p_query into p;return p;end$$;
create function pg_temp.semantic793(q text,f text,t double precision,n integer,s text)
returns table(rank bigint,id uuid,distance double precision) language sql security definer as $$
select * from private.semantic_flow_candidates(q,f,t,n,s);$$;
create function pg_temp.score793(p_query text) returns jsonb language plpgsql security definer as $$
declare started timestamptz;result jsonb;begin
started:=clock_timestamp();execute 'select coalesce(jsonb_agg(to_jsonb(r) order by r.rank,r.id),''[]''::jsonb) from ('||p_query||') r' into result;
return jsonb_build_object('ms',round((extract(epoch from clock_timestamp()-started)*1000)::numeric,3),'digest',md5(result::text),'rows',jsonb_array_length(result),'serializedBytes',octet_length(result::text),'totalCount',result->0->'total_count',
'minScore',(select min((a->>'search_score')::double precision) from jsonb_array_elements(result) a),
'maxScore',(select max((a->>'search_score')::double precision) from jsonb_array_elements(result) a),
'distinctScores',(select count(distinct (a->>'search_score')::double precision) from jsonb_array_elements(result) a));end$$;
create function pg_temp.gated_plan793(p_query text,p_gate_call text) returns jsonb language plpgsql security definer as $$
declare g jsonb;begin execute 'select '||p_gate_call into g;
return jsonb_build_object('gate',g,'plan',pg_temp.definer_plan793(replace(p_query,'__GATE_PARAM15__',coalesce(g->>'use_type_keys','false')||'::boolean')));end$$;
create function pg_temp.gated_score793(p_query text,p_gate_call text) returns jsonb language plpgsql security definer as $$
declare g jsonb;begin execute 'select '||p_gate_call into g;
return pg_temp.score793(replace(p_query,'__GATE_PARAM15__',coalesce(g->>'use_type_keys','false')||'::boolean')) || jsonb_build_object('gate',g);end$$;
grant execute on function pg_temp.measure793(text),pg_temp.plan793(text),pg_temp.definer_plan793(text),pg_temp.semantic793(text,text,double precision,integer,text),pg_temp.score793(text) to authenticated,api_internal_executor;
grant execute on function pg_temp.gated_plan793(text,text),pg_temp.gated_score793(text,text) to authenticated,api_internal_executor;
"""
    cases = [('broad','electricity',{},20,10,1,.5), ('narrow','solar',{},20,10,1,.5),
             ('sparse_type','electricity',{'flowType':'Product flow'},20,10,1,.5),
             ('broad_type','electricity',{'flowType':'Elementary flow'},20,10,1,.5),
             ('narrow_type','solar',{'flowType':'Product flow'},20,10,1,.5),
             ('multi_type','electricity',{'flowType':'Product flow,Elementary flow'},20,10,1,.5),
             ('page80','electricity',{},20,80,1,.5),('deep','electricity',{},20,10,20,.5),
             ('zero','absent-raw793',{},20,10,1,1.)]
    report['cases'] = [dict(zip(['name','query','filter','match','pageSize','pageCurrent','threshold'], c)) for c in cases]
    def api_call(c):
        _, query, filters, match, size, page, threshold = c
        return f"api.hybrid_search_flows({quote(query)},{quote(query_vector)},{quote(json.dumps(filters))}::jsonb,{threshold},{match},0.5,0.5,10,'tg',{size},{page},array[{quote(query)}])"
    def stage_record(stage, name, extra):
        return f"select jsonb_build_object('stage',{quote(stage)},'case',{quote(name)}) || {extra};"
    def fusion_kernel(definition, c):
        kernel = definition.split('return query', 1)[1].split('end;', 1)[0].strip().rstrip(';')
        kernel = 'with text_matches as(select ft.rank as text_rank,ft.id as text_id from pg_temp.frozen_text ft), semantic as(select fs.rank as ss_rank,fs.id as ss_id from pg_temp.frozen_semantic fs), fused_raw as' + kernel.split('fused_raw as', 1)[1]
        values = {'rrf_k':'10::integer','text_weight':'0.5::double precision','semantic_weight':'0.5::double precision','data_source':"'tg'::text",'page_size':str(c[4]),'page_current':str(c[5])}
        for name, value in values.items():
            kernel = re.sub(r'\b'+name+r'\b', value, kernel)
        return kernel
    def with_kernel(definition, kernel):
        # Reuse the real API owner/invoker boundary; no SET ROLE permission or
        # membership widening is needed for the inaccessible internal role.
        return definition.split('return query',1)[0]+'return query\n'+kernel.rstrip(';')+';\nend;'+definition.split('end;',1)[1]
    def metadata_assert(query, expected):
        return 'do $meta$ begin if ('+query.rstrip(';')+') is distinct from '+quote(json.dumps(expected))+"::jsonb then raise exception 'benchmark candidate changed function metadata' using errcode='55000';end if;end $meta$;"

    fixture_committed = False
    try:
        print('Building the exact-owned logged fixture and original indexes', flush=True)
        sql(setup, timeout=3600)
        fixture_committed = True
        actual = json.loads(scalar("select jsonb_agg(jsonb_build_object('name',c.relname,'definition',pg_get_indexdef(i.indexrelid),'constraint',exists(select 1 from pg_constraint k where k.conindid=i.indexrelid),'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive) order by c.relname) from pg_index i join pg_class c on c.oid=i.indexrelid where i.indrelid='public.flows'::regclass;"))
        if actual != preflight['indexes']:
            raise RuntimeError('Exact index definitions/readiness were not restored; samples refused')
        report['indexesRestoredBeforeSamples'] = True
        report['typeExpressionStatistics']=json.loads(scalar("select coalesce(jsonb_agg(jsonb_build_object('inherited',inherited,'nullFrac',null_frac,'nDistinct',n_distinct,'mcv',most_common_vals::text,'frequencies',most_common_freqs)),'[]') from pg_stats where schemaname='public' and tablename='flows_json_typeofdataset' and attname='expr';"))
        sql('begin;' + config + "select jsonb_build_object('stage','settings','jit',current_setting('jit'),'workMem',current_setting('work_mem'),'vector', (select extversion from pg_extension where extname='vector'));rollback;")
        for c in cases:
            name, query, filters, match, size, page, threshold = c
            cap = max(match, size)*10
            lex_call = f"api.search_flows_latest({quote(query)},{quote(json.dumps(filters))}::jsonb,'{{}}',{cap},1,'tg','',null,null,array[{quote(query)}])"
            sem_call = f"pg_temp.semantic793({quote(query_vector)},{quote(json.dumps(filters))},{threshold},{max(match,size)},'tg')"
            parameters = {1:quote(query),2:"'{}'::jsonb",3:str(cap),4:'1',5:"'tg'",6:'auth.uid()',
                          7:'null::uuid',8:'null::integer',9:'false',
                          10:quote(filters['flowType']) if filters else 'null::text',
                          11:'array['+','.join(quote(t) for t in filters['flowType'].split(','))+']' if filters else 'null::text[]',
                          12:'null::boolean',13:"'[]'::jsonb",14:f"array[{quote(query)}]",15:'__GATE_PARAM15__'}
            lex_definitions={'baseline':lexical_baseline,'candidate':lexical_candidate}
            # Per-arm first/warm calls have new backends; do not present the
            # sequential backend/OS-cache difference as a candidate benefit.
            for arm in ['baseline','candidate']:
                stage_samples=''
                for sample in range(4):
                    stage_samples+=stage_record('S1',name,"jsonb_build_object('arm',"+quote(arm)+",'sample',"+str(sample)+") || pg_temp.measure793("+quote(lex_call)+")")
                    if arm=='baseline':
                        stage_samples+=stage_record('S2',name,"jsonb_build_object('sample',"+str(sample)+") || pg_temp.measure793("+quote(sem_call)+")")
                kernel=lexical_kernel(lex_definitions[arm],parameters)
                gate_call=f"pg_temp.gate793({quote(query)},{quote(json.dumps(filters))}::jsonb,{cap},1,'tg','',null,null,array[{quote(query)}])"
                plan=stage_record('S1-plan',name,"jsonb_build_object('arm',"+quote(arm)+") || pg_temp.gated_plan793("+quote(kernel)+","+quote(gate_call)+")")
                score_samples=''
                for sample in range(2):
                    score_samples+=stage_record('S1-score',name,"jsonb_build_object('arm',"+quote(arm)+",'sample',"+str(sample)+") || pg_temp.gated_score793("+quote(lexical_score_kernel(kernel))+","+quote(gate_call)+")")
                sql('begin;'+config+measure+lexical_gate_probe(lex_definitions[arm])+lex_definitions[arm]+metadata_assert(lexical_meta_query,lexical_metadata)+auth+stage_samples+plan+score_samples+'rollback;')
            # Separately compare the entire actual lexical candidate page,
            # including rank/count/payload, rather than Hybrid's top10 only.
            lexical_compare='begin;'+config+measure
            for sample in range(args.samples):
                for arm in (['baseline','candidate'] if sample%2==0 else ['candidate','baseline']):
                    lexical_compare+=lex_definitions[arm]+metadata_assert(lexical_meta_query,lexical_metadata)+auth+stage_record('S1-compare',name,
                        "jsonb_build_object('arm',"+quote(arm)+",'sample',"+str(sample)+") || pg_temp.measure793("+quote(lex_call)+")")+'reset role;'
            sql(lexical_compare+'rollback;')
            # Natural inner semantic plan: same custom/strict settings and exact
            # TG kernel; no forced scan/join method. Includes the real vector.
            sem_kernel = semantic.split('return query',1)[1].split('return;',1)[0].strip().rstrip(';')
            substitutions = {'query_embedding_vector':quote(query_vector)+'::extensions.vector(1024)',
                             'filter_condition_jsonb':"'{}'::jsonb",'flow_type':quote(filters.get('flowType')) if filters else 'null::text',
                             'flow_type_array':'array['+','.join(quote(t) for t in filters['flowType'].split(','))+']' if filters else 'null::text[]',
                             'as_input':'null::boolean','candidate_size':str(max(max(match,size)*10,200)),
                             'threshold_distance':str(1-threshold),'normalized_match_count':str(max(match,size))}
            for key,value in substitutions.items():sem_kernel=re.sub(r'\b'+key+r'\b',value,sem_kernel)
            sql('begin;' + config + measure + auth + "set local plan_cache_mode=force_custom_plan;set local hnsw.iterative_scan=strict_order;" +
                stage_record('S2-plan',name,'jsonb_build_object(\'plan\',pg_temp.definer_plan793('+quote(sem_kernel)+'))') + 'rollback;')
            # Freeze exact stream rows once; the comparison does not collapse IDs.
            freeze = f"create temp table frozen_text as select rank,id from {lex_call};create temp table frozen_semantic as select rank,id from {sem_call};grant select on pg_temp.frozen_text,pg_temp.frozen_semantic to api_internal_executor;"
            old_kernel, new_kernel = fusion_kernel(baseline,c), fusion_kernel(candidate,c)
            frozen_defs={'old':with_kernel(baseline,old_kernel),'new':with_kernel(candidate,new_kernel)}
            frozen_samples = ''
            for i in range(args.samples):
                for arm in (['old','new'] if i%2==0 else ['new','old']):
                    frozen_samples+=frozen_defs[arm]+auth+stage_record('S3',name,"jsonb_build_object('arm',"+quote(arm)+",'sample',"+str(i)+") || pg_temp.measure793("+quote(api_call(c))+")")+'reset role;'
            frozen_plans=''
            for arm,kernel in [('old',old_kernel),('new',new_kernel)]:
                plan_kernel="select null::uuid,pg_temp.plan793("+quote(kernel)+"),null::character,null::timestamptz,null::uuid,null::bigint"
                frozen_plans+=with_kernel(baseline,plan_kernel)+auth+stage_record('S3-'+arm+'-plan',name,
                    "jsonb_build_object('plan',(select r.json from "+api_call(c)+" r))")+'reset role;'
            sql('begin;'+config+measure+auth+freeze+'reset role;'+
                stage_record('S3-streams',name,"jsonb_build_object('lexicalRows',(select count(*) from pg_temp.frozen_text),'semanticRows',(select count(*) from pg_temp.frozen_semantic),'semanticIds',(select count(distinct id) from pg_temp.frozen_semantic))")+
                frozen_plans+frozen_samples+'rollback;')
            query_sql = 'begin;'+config+measure
            for i in range(args.samples):
                for arm in (['baseline','candidate'] if i%2==0 else ['candidate','baseline']):
                    query_sql += ('\n'+(baseline if arm=='baseline' else candidate)+'\n'+lex_definitions[arm]+metadata_assert(function_meta_query,function_metadata)+metadata_assert(lexical_meta_query,lexical_metadata)+auth+
                        stage_record('S0',name,"jsonb_build_object('arm',"+quote(arm)+",'sample',"+str(i)+") || pg_temp.measure793("+quote(api_call(c))+");")+'reset role;')
            sql(query_sql+'rollback;')
        if 'use_type_keys' in lexical_candidate:
            # Ordinary local DDL inside rollback gives an honest absent-index
            # statistics condition. Never edits pg_statistic or forces plans.
            proof_case=next(c for c in cases if c[0]=='sparse_type')
            _,query,filters,match,size,page,threshold=proof_case
            cap=max(match,size)*10
            proof_call=f"api.search_flows_latest({quote(query)},{quote(json.dumps(filters))}::jsonb,'{{}}',{cap},1,'tg','',null,null,array[{quote(query)}])"
            gate_call=f"pg_temp.gate793({quote(query)},{quote(json.dumps(filters))}::jsonb,{cap},1,'tg','',null,null,array[{quote(query)}])"
            bindings={1:quote(query),2:"'{}'::jsonb",3:str(cap),4:'1',5:"'tg'",6:'auth.uid()',7:'null::uuid',8:'null::integer',9:'false',10:quote(filters['flowType']),11:f"array[{quote(filters['flowType'])}]",12:'null::boolean',13:"'[]'::jsonb",14:f"array[{quote(query)}]",15:'__GATE_PARAM15__'}
            proof='begin;'+config+measure+lexical_gate_probe(lexical_candidate)+'drop index public.flows_json_typeofdataset;'
            for arm,definition in [('baseline',lexical_baseline),('candidate',lexical_candidate)]:
                proof+=definition+metadata_assert(lexical_meta_query,lexical_metadata)+auth+stage_record('S1-missing-stats','sparse_type',
                    "jsonb_build_object('arm',"+quote(arm)+") || pg_temp.measure793("+quote(proof_call)+")")+'reset role;'
            proof+=auth+stage_record('S1-missing-stats-plan','sparse_type',
                "pg_temp.gated_plan793("+quote(lexical_kernel(lexical_candidate,bindings))+","+quote(gate_call)+")")+'rollback;'
            sql(proof)
            proof_rows=[r for r in records if r.get('stage')=='S1-missing-stats']
            proof_plan=next(r for r in records if r.get('stage')=='S1-missing-stats-plan')
            proof_equal=len({(r['digest'],r['rows'],str(r['totalCount'])) for r in proof_rows})==1
            report['missingStatsFallback']={'gate':proof_plan['gate'],'fullLexicalEqual':proof_equal,'indexDropRolledBack':True}
            if proof_plan['gate']['use_type_keys'] or not proof_equal:
                raise RuntimeError('Missing-stat fallback failed')
        summaries=[]
        for c in cases:
            name=c[0]; group=[r for r in records if r.get('case')==name]
            s0=[r for r in group if r['stage']=='S0'];s3=[r for r in group if r['stage']=='S3']
            s1=[r for r in group if r['stage']=='S1-compare'];scores=[r for r in group if r['stage']=='S1-score']
            stable=len({(r['digest'],r['rows'],str(r['totalCount'])) for r in s0 if r['arm']=='baseline'})==1
            full_equal=stable and len({(r['digest'],r['rows'],str(r['totalCount'])) for r in s0})==1
            frozen_equal=len({(r['digest'],r['rows'],str(r['totalCount'])) for r in s3})==1
            lexical_stable=len({(r['digest'],r['rows'],str(r['totalCount'])) for r in s1 if r['arm']=='baseline'})==1
            lexical_equal=lexical_stable and len({(r['digest'],r['rows'],str(r['totalCount'])) for r in s1})==1
            score_stable=len({(r['digest'],r['rows'],str(r['totalCount'])) for r in scores if r['arm']=='baseline'})==1
            score_equal=score_stable and len({(r['digest'],r['rows'],str(r['totalCount'])) for r in scores})==1
            timings={}
            for stage, samples in [('S0',s0),('S3',s3),('S1',s1)]:
                for arm in {r['arm'] for r in samples}:
                    vals=sorted(r['ms'] for r in samples if r['arm']==arm)
                    timings[stage+'-'+arm]={'p50Ms':statistics.median(vals),'p95Ms':vals[math.ceil(.95*len(vals))-1],'maxMs':vals[-1]}
            summaries.append({'case':name,'baselineRepeatable':stable,'fullApiEqual':full_equal,'frozenEqual':frozen_equal,'lexicalBaselineRepeatable':lexical_stable,'fullLexicalEqual':lexical_equal,'scoreBaselineRepeatable':score_stable,'fullScoreRankEqual':score_equal,'timings':timings})
        report['summaries']=summaries
        report['qualifiedFullOutputParity']=all(r['baselineRepeatable'] and r['fullApiEqual'] and r['frozenEqual'] and r['fullLexicalEqual'] and r['fullScoreRankEqual'] for r in summaries)
        save()
        print(json.dumps({'stage':'summary','summaries':summaries}),flush=True)
        if not report['qualifiedFullOutputParity']:
            raise RuntimeError('Output comparison is unqualified; inspect repeatability/parity in the retained report')
    finally:
        # SETUP may have committed even if a later VACUUM/report statement failed.
        existing=int(scalar("select count(*) from public.flows where json->>'_raw793'="+quote(marker)))
        total=int(scalar('select count(*) from public.flows;'))
        if total != existing:
            report['cleanup']={'completed':False,'reason':'foreign rows found; retained fixture instead of unsafe cleanup'}
            save()
            raise RuntimeError('Unexpected foreign fixture rows; safe cleanup refused')
        cleanup='begin;lock table public.flows in access exclusive mode;alter table public.flows disable trigger user;delete from public.flows where json->>\'_raw793\'='+quote(marker)+';'+restore_triggers+'commit;vacuum(analyze) public.flows;'
        # Empty ordinary indexes should not retain the benchmark's gigabytes of
        # allocation; preserve their definitions/owners/ACLs while rebuilding.
        cleanup+=''.join('reindex index public.'+ident(i['name'])+';' for i in preflight['indexes'])
        sql(cleanup)
        remaining=int(scalar('select count(*) from public.flows;'))
        unchanged=sha(scalar('select pg_get_functiondef('+quote(SIGNATURE)+'::regprocedure);'))==sha(baseline_definition)
        function_metadata_restored=json.loads(scalar(function_meta_query))==function_metadata
        lexical_restored=sha(scalar('select pg_get_functiondef('+quote(LEXICAL_SIGNATURE)+'::regprocedure);'))==sha(lexical)
        lexical_metadata_restored=json.loads(scalar(lexical_meta_query))==lexical_metadata
        restored_indexes=json.loads(scalar("select jsonb_agg(jsonb_build_object('name',c.relname,'definition',pg_get_indexdef(i.indexrelid),'constraint',exists(select 1 from pg_constraint k where k.conindid=i.indexrelid),'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive) order by c.relname) from pg_index i join pg_class c on c.oid=i.indexrelid where i.indrelid='public.flows'::regclass;"))==preflight['indexes']
        restored_triggers=json.loads(scalar("select jsonb_agg(jsonb_build_object('name',tgname,'enabled',tgenabled) order by tgname) from pg_trigger where tgrelid='public.flows'::regclass and not tgisinternal;"))==triggers
        report['cleanup']={'completed':remaining==0 and unchanged and function_metadata_restored and lexical_restored and lexical_metadata_restored and restored_indexes and restored_triggers,'remainingFlows':remaining,'baselineFunctionRestored':unchanged,'functionMetadataRestored':function_metadata_restored,'lexicalDefinitionRestored':lexical_restored,'lexicalMetadataRestored':lexical_metadata_restored,'indexesRestored':restored_indexes,'triggersRestored':restored_triggers,'fixtureCommitted':fixture_committed}
        save()
        print(json.dumps({'stage':'cleanup',**report['cleanup']}),flush=True)
        if not report['cleanup']['completed']:
            raise RuntimeError('Cleanup verification failed; retained report identifies the remaining state')


if __name__ == '__main__':
    main()
