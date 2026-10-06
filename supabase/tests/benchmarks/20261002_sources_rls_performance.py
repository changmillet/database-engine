#!/usr/bin/env python3
"""Compare Source RLS on an empty, explicitly named local synthetic fixture."""
import argparse
import json
from pathlib import Path
import subprocess


def docker(*args, sql=None):
    return subprocess.run(["docker", *args], input=sql, text=True,
                          capture_output=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    if not args.container.startswith("supabase_db_database-engine-766-"):
        parser.error("Use only an explicitly owned isolated Database #766 container")
    context = json.loads(docker("context", "inspect"))[0]
    endpoint = context["Endpoints"]["docker"]["Host"]
    if not endpoint.startswith(("unix://", "npipe://")):
        parser.error("Hosted and remote Docker endpoints are forbidden")
    if args.report.exists():
        parser.error("The report path must be new")
    here = Path(__file__).resolve().parent
    fixture = (here / "20261002_sources_rls_fixture.sql").read_text()
    old = (here / "20261002_sources_rls_predecessor.sql").read_text()
    setup = r"""
begin;
do $$ begin
 if exists(select 1 from public.sources) or exists(select 1 from private.reviews)
 then raise exception 'EMPTY_LOCAL_FIXTURE_REQUIRED'; end if;
end $$;
create temporary table benchmark_policies(name text primary key, ddl text);
create temp table source_policy_layout as select not exists(
 select 1 from pg_policy where polrelid='public.sources'::regclass
 and polname='authenticated_example_read') as merged_examples;
insert into benchmark_policies
select 'new',format('alter policy "Enable read access for authenticated users" on public.sources using (%s)',qual)
from pg_policies where schemaname='public' and tablename='sources' and policyname='Enable read access for authenticated users';
""" + "insert into benchmark_policies values ('old',$old$" + old + "$old$);\n" + fixture
    runner = r"""
create function pg_temp.measure(p_actor uuid,p_pattern text) returns jsonb language plpgsql as $$
declare plan jsonb; result jsonb; started timestamptz:=clock_timestamp(); query text;
begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',p_actor)::text,true);
 execute 'set local role authenticated';
 query:=format($query$
 with pgrst_source as (
  select id,version,state_code,user_id,json_ordered->'sourceDataSet'->'sourceInformation' as information
  from public.sources
  where json_ordered->'sourceDataSet'->'sourceInformation'->'dataSetInformation'->>'sourceCitation' ilike %L
  limit 50 offset 0)
 select jsonb_build_object('count',count(t),'body',coalesce(jsonb_agg(t),'[]')) from pgrst_source t
 $query$,p_pattern);
 begin
  execute 'explain (analyze,buffers,format json) '||query into plan;
  execute query into result;
  result:=jsonb_build_object('execution_ms',plan->0->'Execution Time','body_md5',md5((result->'body')::text),'count',result->'count','plan',plan);
 exception when query_canceled then
  result:=jsonb_build_object('sqlstate',sqlstate,'elapsed_ms',extract(epoch from clock_timestamp()-started)*1000);
 end;
 execute 'reset role';
 return result;
end $$;
create function pg_temp.policy(p_name text) returns void language plpgsql as $$
begin
 execute (select ddl from benchmark_policies where name=p_name);
 if (select merged_examples from source_policy_layout) then
  if p_name='old' then
   execute 'create policy authenticated_example_read on public.sources for select to authenticated using (state_code=-1 and (select auth.uid()) is not null)';
  else
   execute 'drop policy authenticated_example_read on public.sources';
  end if;
 end if;
end $$;
set local statement_timeout='20s';
"""
    statements = []
    for cohort, actor in [("representative", 1), ("representative-member", 3),
                          ("representative-member-hints", 3), ("worst-case", 1)]:
        if cohort == "representative-member-hints":
            statements += ["set local session_replication_role=replica;",
                           "update public.sources set reviews=jsonb_build_array(jsonb_build_object('id',md5('review-766-1')::uuid)) where state_code=20;",
                           "set local session_replication_role=origin;"]
        if cohort == "worst-case":
            statements += ["set local session_replication_role=replica;",
                           "update public.sources set state_code=20 where state_code=0;",
                           "set local session_replication_role=origin;"]
        actor_id = f"76600000-0000-4000-8000-{actor:012}"
        for variant in ["old", "new"]:
            statements.append(f"select pg_temp.policy('{variant}');")
            patterns = ["%766-no-hit%"] if variant == "old" else ["%766-no-hit%", "%766-hit%", "%766-no-hit%"]
            for sample, pattern in enumerate(patterns):
                statements.append(f"select jsonb_build_object('cohort','{cohort}','variant','{variant}','sample',{sample},'pattern','{pattern}','measurement',pg_temp.measure('{actor_id}','{pattern}'));")
    statements.append("rollback;")
    output = docker("exec", "-i", args.container, "psql", "-XAtq", "-v",
                    "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres",
                    sql=setup + runner + "\n".join(statements))
    records = [json.loads(line) for line in output.splitlines() if line.startswith('{"cohort"')]
    if len(records) != 16:
        raise RuntimeError("Incomplete benchmark results")
    for record in records:
        measure = record["measurement"]
        if record["variant"] == "new":
            expected_count = 1 if record["pattern"] == "%766-hit%" else 0
            if measure.get("count") != expected_count:
                raise RuntimeError("Replacement query failed or returned unexpected fixture rows")
            def review_loops(node):
                loops = [node["Actual Loops"]] if node.get("Relation Name") == "reviews" else []
                for child in node.get("Plans", []):
                    loops.extend(review_loops(child))
                return loops
            loops = review_loops(measure["plan"][0]["Plan"])
            if not loops or max(loops) > 1:
                raise RuntimeError("Actor-visible Review scan repeated per Source")
            measure["review_scan_loops"] = loops
    report = {"classification": "isolated-synthetic", "container": args.container,
              "sources": 14420, "reviews": 2789,
              "representative_state20": 161, "worst_case_state20": 3048,
              "statement_timeout_ms": 20000, "measurements": records}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x") as target:
        json.dump(report, target, indent=2)
        target.write("\n")
    for record in records:
        measure = record["measurement"]
        print(json.dumps({**{k:record[k] for k in ["cohort", "variant", "sample", "pattern"]},
                          **{k:measure[k] for k in ["sqlstate", "elapsed_ms", "execution_ms", "count", "body_md5"] if k in measure}}))


if __name__ == "__main__":
    main()
