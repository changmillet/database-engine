-- Database #785: remove only the verified duplicate-DataSet-root typo index.
-- Verified canonical LCIA Method input has zero wrong roots/keys; version/PK,
-- sync trigger, table owner/ACL/RLS and every other index remain protected.
-- No replacement JSON expression index or extension CASCADE is introduced.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
lock table only public.lciamethods in access exclusive mode;
create temp table issue785_method_table_before on commit drop as
select oid,relowner,relacl,relrowsecurity,relforcerowsecurity from pg_catalog.pg_class
where oid='public.lciamethods'::regclass;
create temp table issue785_method_indexes_before on commit drop as
select i.indexrelid,to_jsonb(i) as properties,pg_catalog.pg_get_indexdef(i.indexrelid) as definition
from pg_catalog.pg_index i where i.indrelid='public.lciamethods'::regclass
and i.indexrelid is distinct from pg_catalog.to_regclass('public.lciamethods_json_dataversion');
do $guard$
declare idx oid; p record;
begin
 if not exists(select 1 from pg_catalog.pg_index i
  join pg_catalog.pg_attribute id_col on id_col.attrelid=i.indrelid and id_col.attname='id'
  join pg_catalog.pg_attribute version_col on version_col.attrelid=i.indrelid and version_col.attname='version'
  where i.indexrelid='public.lciamethods_pkey'::regclass and i.indrelid='public.lciamethods'::regclass
  and i.indisprimary and i.indisunique and i.indisvalid and i.indisready and i.indislive
  and i.indnkeyatts=2 and i.indkey[0]=id_col.attnum and i.indkey[1]=version_col.attnum)
 or not exists(select 1 from pg_catalog.pg_trigger where tgrelid='public.lciamethods'::regclass
  and tgname='lciamethods_json_sync_trigger' and tgenabled='O'
  and tgfoid='private.lciamethods_sync_jsonb_version()'::regprocedure) then
  raise exception using errcode='55000',message='Database #785 canonical LCIA Method contract absent';
 end if;
 if exists(select 1 from public.lciamethods where json ? 'LCIAMethodDataSetDataSet') then
  raise exception using errcode='55000',message='Database #785 wrong-root LCIA Method data requires separate review';
 end if;
 idx:=pg_catalog.to_regclass('public.lciamethods_json_dataversion');
 if idx is null then return; end if; -- canonical postimage / COMMIT-history retry
 select i.*,c.relowner,c.relkind,am.amname into strict p from pg_catalog.pg_index i
 join pg_catalog.pg_class c on c.oid=i.indexrelid join pg_catalog.pg_am am on am.oid=c.relam
 where i.indexrelid=idx;
 if p.indrelid<>'public.lciamethods'::regclass or p.relowner<>'postgres'::regrole
 or p.relkind<>'i' or p.amname<>'btree' or p.indisunique or p.indisprimary
 or not p.indisvalid or not p.indisready or not p.indislive
 or pg_catalog.pg_get_indexdef(idx) is distinct from 'CREATE INDEX lciamethods_json_dataversion ON public.lciamethods USING btree (((((("json" -> ''LCIAMethodDataSetDataSet''::text) -> ''administrativeInformation''::text) -> ''publicationAndOwnership''::text) ->> ''common:dataSetVersion''::text)))'
 or exists(select 1 from pg_catalog.pg_constraint where conindid=idx)
 or exists(select 1 from pg_catalog.pg_depend where refclassid='pg_catalog.pg_class'::regclass and refobjid=idx) then
  raise exception using errcode='55000',message='Database #785 obsolete-index preimage or dependency drift';
 end if;
 execute 'drop index public.lciamethods_json_dataversion';
end;
$guard$;
do $postcondition$
begin
 if exists(select 1 from issue785_method_table_before b join pg_catalog.pg_class c using(oid)
  where (b.relowner,b.relacl,b.relrowsecurity,b.relforcerowsecurity)
   is distinct from(c.relowner,c.relacl,c.relrowsecurity,c.relforcerowsecurity))
 or exists(select 1 from issue785_method_indexes_before b full join
  (select * from pg_catalog.pg_index where indrelid='public.lciamethods'::regclass) i using(indexrelid)
  where b.indexrelid is null or i.indexrelid is null or b.properties is distinct from to_jsonb(i)
   or b.definition is distinct from pg_catalog.pg_get_indexdef(i.indexrelid)) then
  raise exception using errcode='55000',message='Database #785 protected table/index graph changed';
 end if;
end;
$postcondition$;
commit;
