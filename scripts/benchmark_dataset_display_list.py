#!/usr/bin/env python3
"""Rollback-only large-JSON display pagination proof on exact task-owned local DB."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def validate_page_plan(records: list[dict], tables: set[str]) -> None:
    plan = next(r["plan"][0]["Plan"] for r in records if r["type"] == "plan")

    def nodes(node):
        yield node
        for child in node.get("Plans", []):
            yield from nodes(child)

    physical = list(nodes(plan))
    eligible = next(n for n in physical if n.get("Subplan Name") == "CTE eligible")
    if any("json" in output.lower() or "name" in output.lower()
           for output in eligible.get("Output", [])):
        raise SystemExit("Full candidate working set still carries name/JSON payload")
    hydration_rows = sum(n.get("Actual Rows", 0) * n.get("Actual Loops", 0)
                         for n in physical if n.get("Relation Name") in
                         tables and any(
                             '"json"' in output for output in n.get("Output", [])))
    if hydration_rows != 10:
        raise SystemExit(f"Hydration is not page-bounded: {hydration_rows} source rows")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-container", required=True)
    parser.add_argument("--rows", type=int, default=200000)
    parser.add_argument("--chunks", type=int, default=256,
                        help="Unique 32-byte chunks per source JSON payload")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.local_container != "supabase_db_codex-display-801":
        parser.error("Only exact task-owned supabase_db_codex-display-801 is allowed")
    if not 7000 <= args.rows <= 400000 or not 64 <= args.chunks <= 512:
        parser.error("rows must be 7000..400000 and chunks 64..512")
    if not 1 <= args.repeats <= 5:
        parser.error("repeats must be 1..5")
    if args.output.exists():
        parser.error("Output exists; refuse overwrite")
    context = subprocess.run(["docker", "context", "inspect"],
                             check=True, capture_output=True, text=True)
    endpoint = json.loads(context.stdout)[0]["Endpoints"]["docker"]["Host"]
    if not endpoint.startswith("unix://") or os.environ.get("DOCKER_HOST"):
        raise SystemExit("Only the current local Unix Docker daemon is allowed")
    inspect = subprocess.run(["docker", "inspect", "--format", "{{.Name}}",
                              args.local_container], check=True,
                             capture_output=True, text=True).stdout.strip()
    if inspect != "/" + args.local_container:
        raise SystemExit("Container identity mismatch")
    repo = Path(__file__).resolve().parents[1]
    migration = (repo / "supabase/migrations/20261009003748_dataset_display_settings.sql").read_text()
    baseline = migration.split("create function private.dataset_display_list(", 1)[1].split(
        "alter function private.dataset_display_list", 1)[0]
    baseline = "create function pg_temp.display_baseline801(" + baseline
    current = (repo / "supabase/migrations/20261009035945_dataset_display_list_page_hydration.sql").read_text()
    # The literal query is used only to inspect the physical plan of the real helper.
    before, after = current.split("execute $query$", 1)[1].split(
        "$query$ || v_search_filter || $query$", 1)
    page_query = before + after.split("$query$ into", 1)[0]
    values = {"1": "'all'", "2": "'all'", "3": "''", "4": "10", "5": "1", "6": "true"}
    page_query = re.sub(r"\$(\d+)", lambda m: values[m[1]], page_query)

    kinds = [
        ("contact", "contacts", ["contactDataSet", "contactInformation", "dataSetInformation", "common:name"], 700),
        ("flow", "flows", ["flowDataSet", "flowInformation", "dataSetInformation", "name"], 140000),
        ("flowproperty", "flowproperties", ["flowPropertyDataSet", "flowPropertiesInformation", "dataSetInformation", "common:name"], 500),
        ("lifecyclemodel", "lifecyclemodels", ["lifeCycleModelDataSet", "lifeCycleModelInformation", "dataSetInformation", "name"], 1000),
        ("process", "processes", ["processDataSet", "processInformation", "dataSetInformation", "name"], 44000),
        ("source", "sources", ["sourceDataSet", "sourceInformation", "dataSetInformation", "common:shortName"], 13500),
        ("unitgroup", "unitgroups", ["unitGroupDataSet", "unitGroupInformation", "dataSetInformation", "common:name"], 300),
    ]
    counts = [max(2, int(args.rows * k[3] / 200000)) for k in kinds]
    counts[1] += args.rows - sum(counts)
    empty = " + ".join(f"(select count(*) from public.{k[1]})" for k in kinds)
    sql = f"""begin;
set local statement_timeout='180s';
set local lock_timeout='5s';
set local jit=off;
set local work_mem='4MB';
do $$begin
 if ({empty}) <> 0 or exists(select 1 from private.dataset_display_settings) then
  raise exception 'refuse fixture on nonempty source';
 end if;
end$$;
create or replace function util.invoke_edge_function(name text,body jsonb,
 timeout_milliseconds integer default 300000) returns void
language plpgsql security definer set search_path='' as $$begin null;end$$;
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
values('80100000-0000-4000-8000-000000000999','authenticated','authenticated',
 'display-benchmark@example.invalid','{{}}','{{}}');
insert into private.users(id,raw_user_meta_data,contact)
values('80100000-0000-4000-8000-000000000999','{{}}',null);
insert into private.teams(id,json,rank,is_public)
values('00000000-0000-0000-0000-000000000000','{{"name":"System"}}',0,false)
on conflict(id) do nothing;
insert into private.roles(user_id,team_id,role)
values('80100000-0000-4000-8000-000000000999','00000000-0000-0000-0000-000000000000','data_product_manager');
select set_config('request.jwt.claim.sub','80100000-0000-4000-8000-000000000999',true);
"""
    for (kind, table, path, _), count in zip(kinds, counts):
        name = f"jsonb_build_object('@xml:lang','zh','#text',{literal(kind+' 测试 ')}||g)"
        if kind in ("process", "flow", "lifecyclemodel"):
            name = "jsonb_build_object('baseName'," + name + ")"
        doc = name
        for key in reversed(path):
            doc = "jsonb_build_object(" + literal(key) + "," + doc + ")"
        sql += f"""
-- Read-only benchmark fixtures bypass source derivative writers, transactionally.
alter table public.{table} disable trigger user;
insert into public.{table}(id,version,state_code,json)
select md5('display801:'||(g/2))::uuid,
 case when g%2=0 then '01.00.000' else '02.00.000' end,
 case when g%3=0 then 20 else 0 end,
 {doc} || jsonb_build_object('largePayload',(
   select string_agg(md5(g::text||':'||j::text),'') from generate_series(1,{args.chunks}) j))
from generate_series(1,{count}) g;
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible)
select {literal(kind)},id,version,(row_number() over(order by id,version))%80=0
from public.{table} offset 0;
delete from private.dataset_display_settings where dataset_kind={literal(kind)} and not is_visible;
analyze public.{table};
"""
    sql += "analyze private.dataset_display_settings;\n" + baseline
    sql += """
create function pg_temp.measure801(p_case text,p_phase text,p_query text)
returns jsonb language plpgsql as $$
declare started timestamptz:=clock_timestamp(); result jsonb; begin
 execute p_query into result;
 return jsonb_build_object('type','measurement','case',p_case,'phase',p_phase,
  'ms',extract(epoch from clock_timestamp()-started)*1000,'digest',md5(result::text),
  'total',result->'total','pageRows',jsonb_array_length(result->'data'));
exception when query_canceled then
 return jsonb_build_object('type','measurement','case',p_case,'phase',p_phase,
  'ms',extract(epoch from clock_timestamp()-started)*1000,'code','57014');
end$$;
create function pg_temp.plan801(p_query text) returns jsonb language plpgsql as $$
declare result jsonb;begin
 execute 'explain(analyze,buffers,verbose,format json) '||p_query into result;
 return jsonb_build_object('type','plan','case','all_first_page','plan',result);
end$$;
"""
    sql += "select jsonb_build_object('type','fixture','rows'," + str(args.rows)
    sql += ",'chunks'," + str(args.chunks)
    sql += """,'sources',(select jsonb_agg(jsonb_build_object('table',c.relname,
 'rows',c.reltuples,'heapBytes',pg_relation_size(c.oid),'totalBytes',pg_total_relation_size(c.oid),
 'toastBytes',pg_total_relation_size(c.reltoastrelid))) from pg_class c
 join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relname in ('contacts','flows','flowproperties','lifecyclemodels','processes','sources','unitgroups')));
set local statement_timeout='15s';
"""
    cases = [
        ("all_first_page", "'all','all','',10,1,true", "'all','all','',10,1"),
        ("all_deep_page", f"'all','all','',10,{max(1,args.rows//10-1)},true",
         f"'all','all','',10,{max(1,args.rows//10-1)}"),
        ("all_empty_page", "'all','all','',10,1000000,true", "'all','all','',10,1000000"),
        ("process_page", "'process','all','',10,1,true", "'process','all','',10,1"),
        ("visible_page", "'all','visible','',10,1,true", "'all','visible','',10,1"),
        ("hidden_page", "'all','hidden','',10,1,true", "'all','hidden','',10,1"),
        ("contact_search", "'contact','all','测试',10,1,true", "'contact','all','测试',10,1"),
    ]
    for case, old_params, params in cases:
        for phase, query in [
            ("before", f"select pg_temp.display_baseline801({old_params})"),
            ("after", f"select api.list_dataset_display_candidates({params})"),
        ]:
            for _ in range(args.repeats):
                sql += f"select pg_temp.measure801({literal(case)},{literal(phase)},{literal(query)});\n"
    sql += "select pg_temp.plan801(" + literal(page_query) + ");\nrollback;\n"
    command = ["docker", "exec", "-i", args.local_container, "psql", "-X", "-qAt",
               "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
    result = subprocess.run(command, input=sql, text=True, capture_output=True,
                            timeout=1200)
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    payload = {"synthetic": True, "rows": args.rows, "records": records,
               "returncode": result.returncode}
    with args.output.open("x") as f:
        os.chmod(args.output, 0o600)
        json.dump(payload, f, indent=2)
    if result.returncode:
        # Output contains only fixture data; keep SQL diagnostic private.
        raise SystemExit("Local fixture failed; no commit executed. SQLSTATE/fixture diagnostics:\n" + result.stderr[-2400:])
    for case, _, _ in cases:
        measurements = [r for r in records if r.get("case") == case and r["type"] == "measurement"]
        after = [r for r in measurements if r["phase"] == "after"]
        if any("code" in r for r in after):
            raise SystemExit(f"Current query timed out: {case}")
        digests = {r["digest"] for r in measurements if "digest" in r}
        if len(digests) != 1:
            raise SystemExit(f"Before/after result mismatch: {case}")
        print(case, {phase: [round(r["ms"], 2) for r in measurements if r["phase"] == phase]
                     for phase in ("before", "after")})
    validate_page_plan(records, {k[1] for k in kinds})
    if subprocess.run(command, input=f"select ({empty})=0;", capture_output=True,
                      text=True, check=True).stdout.strip() != "t":
        raise SystemExit("Rollback verification failed")
    print("PASS: result parity, current 15s budget, plan captured, source fixtures rolled back")


if __name__ == "__main__":
    main()
