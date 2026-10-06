-- Manual negative diagnostic for Database #781, not a pgTAP qualification test.
-- Run only in an explicitly owned disposable local database, in a fresh backend
-- for each path. Never run against shared, Preview, Dev or production data.
-- PG17.6 / PGroonga3.2.5 / Groonga14.0.5 retains Sources and returns one hit.
-- PG17.11.0.002 with the same extension versions loses the TEMP Sources object
-- after ANALYZE or pgroonga_vacuum(), then the indexed query errors. This is an
-- unresolved PG17.7+ compatibility limitation, not an expected-pass CI check.
-- Default path: ANALYZE. Pass psql -v run_vacuum=true for the separate vacuum
-- path; use a new psql process, not the same transaction/backend, for each run.
-- ON_ERROR_STOP retains the real error/exit status. Backend exit rolls back
-- failed transactions and removes this backend's TEMP relation and index.
\set ON_ERROR_STOP on
\if :{?run_vacuum}
\else
  \set run_vacuum false
\endif

begin;
set local search_path = extensions, public;
select pg_backend_pid() as backend_pid,
       current_setting('server_version') as postgres_version,
       extversion as pgroonga_version,
       extensions.pgroonga_command('status')::jsonb->1->>'version' as groonga_version
from pg_extension where extname = 'pgroonga';

create temporary table issue781_temp_probe (
  id integer primary key,
  search_text text[]
) on commit drop;
create index issue781_temp_probe_search_text_pgroonga
  on issue781_temp_probe using pgroonga (
    search_text pgroonga_text_array_full_text_search_ops_v2
  ) with (tokenizer='TokenBigram', normalizer='NormalizerAuto');
insert into issue781_temp_probe(id, search_text)
select id, array[case when id = 460 then 'needle460' else format('noise460_%s', id) end]
from generate_series(1, 20000) as rows(id);

select pg_relation_filenode('issue781_temp_probe_search_text_pgroonga') as index_file \gset
select pg_filenode_relation(0, :index_file) as resolved_index,
       exists (
         select 1 from jsonb_array_elements(extensions.pgroonga_command('table_list')::jsonb->1) item
         where item->>1 = 'Sources' || :index_file
       ) as sources_before;
select count(*) as hits_before from issue781_temp_probe where search_text &@~ 'needle460';

\if :run_vacuum
  select extensions.pgroonga_vacuum();
\else
  analyze issue781_temp_probe;
\endif

select exists (
  select 1 from jsonb_array_elements(extensions.pgroonga_command('table_list')::jsonb->1) item
  where item->>1 = 'Sources' || :index_file
) as sources_after;
explain (analyze, buffers, format text)
select id from issue781_temp_probe where search_text &@~ 'needle460';
select count(*) as hits from issue781_temp_probe where search_text &@~ 'needle460';
rollback;
