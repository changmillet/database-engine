-- Database #774: narrow the legacy latest-Flow lexical working set.
-- PGroonga matching, max score per historical visible ID, latest-visible version,
-- rank, exact total and pagination stay unchanged. Empty content filters no longer
-- carry JSON through materialization; the selected exact page is hydrated last.
-- No relation, index, writer, ACL, role, signature or timeout is changed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function pg_temp.flow_lexical_replace_once(
  p_source text, p_old text, p_new text
) returns text language plpgsql as $replace$
declare v_count integer;
begin
  v_count := (length(p_source) - length(replace(p_source, p_old, ''))) / length(p_old);
  if v_count <> 1 then
    raise exception 'Flow lexical source drift: expected one replacement, got %', v_count
      using errcode = '55000';
  end if;
  return replace(p_source, p_old, p_new);
end;
$replace$;

do $migration$
declare
  v_signature constant regprocedure :=
    'private.search_flows_latest_impl(text,jsonb,bigint,bigint,text,text,uuid,integer,text[])'::regprocedure;
  v_definition text := pg_get_functiondef(v_signature);
  v_boundary integer;
  v_prefix text;
  v_dynamic text;
begin
  -- The UUID branch stays byte-identical; only the lexical dynamic query changes.
  v_boundary := strpos(v_definition, '  v_sql := format($sql$');
  if v_boundary = 0 then
    raise exception 'Flow lexical source boundary drift' using errcode = '55000';
  end if;
  v_prefix := left(v_definition, v_boundary - 1);
  v_dynamic := substr(v_definition, v_boundary);
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    '             f.json,',
    $new$             case when $2 = '{}'::jsonb and $10 is null
               and not coalesce($12, false) and jsonb_array_length($13) = 0
               then null::jsonb else f.json end as json,$new$);
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    'latest_row.json, latest_row.version', 'latest_row.version');
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    'select f2.json, f2.version', 'select f2.version');
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    'latest_row.modified_at, latest_row.team_id, matched_ids.search_score',
    'latest_row.modified_at, matched_ids.search_score');
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    'select f2.version, f2.modified_at, f2.team_id',
    'select f2.version, f2.modified_at');
  v_dynamic := pg_temp.flow_lexical_replace_once(v_dynamic,
    $old$    select ranked_rows.rank, ranked_rows.id, ranked_rows.json, ranked_rows.version, ranked_rows.modified_at, ranked_rows.team_id, ranked_rows.total_count
    from ranked_rows
    order by ranked_rows.rank, ranked_rows.id
    limit $3
    offset ($4 - 1) * $3$old$,
    $new$    , paged_rows as materialized (
      select ranked_rows.*
      from ranked_rows
      order by ranked_rows.rank, ranked_rows.id
      limit $3
      offset ($4 - 1) * $3
    )
    select paged_rows.rank, paged_rows.id, payload.json, paged_rows.version,
           paged_rows.modified_at, payload.team_id, paged_rows.total_count
    from paged_rows
    join public.flows payload on payload.id = paged_rows.id
      and payload.version = paged_rows.version
    order by paged_rows.rank, paged_rows.id$new$);
  execute v_prefix || v_dynamic;
end;
$migration$;
commit;
