-- Database #793: reject oversized raw Search/Hybrid requests before retrieval.
-- Hybrid recall/page budgets are 100; lexical facades retain 1000 because
-- existing Hybrid kernels delegate 10x lexical candidate budgets (200/800/1000).
-- NULL/nonpositive inputs retain the original kernels' normalization. No query,
-- filter, weight, visibility, ranking, default, signature, owner or ACL changes.
-- The common normalized OFFSET limit is INT_MAX row slots, not a small page
-- count: existing Hybrid OFFSET arithmetic is int32. Division detects excess
-- before multiplication, including BIGINT_MAX lexical pages, without clipping.
-- Portal, matched versions, Open Data and closed internal kernels are excluded.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create temp table raw793_targets (
  signature text primary key, source_md5 text not null, source_language text not null,
  page_cap integer not null, hybrid boolean not null
) on commit drop;
insert into raw793_targets values
  ('api.hybrid_search_contacts(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','1f434cc6ec56b47bd1e6d4d14013a271','sql',100,true),
  ('api.hybrid_search_contacts_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','1f8550a75fef6fc803a58a29e295b08f','sql',100,true),
  ('api.hybrid_search_flowproperties(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','bb91c3a5b94d5ad43723d17bddae1ed1','sql',100,true),
  ('api.hybrid_search_flowproperties_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','cd555bd88ab199fdde30a1cc1c434996','sql',100,true),
  ('api.hybrid_search_flows(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','6da8a894f0aaa2f630ea84b9139ea335','sql',100,true),
  ('api.hybrid_search_flows_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','c59c10820b3e3d4decea0ea2e9634e05','sql',100,true),
  ('api.hybrid_search_lifecyclemodels(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','00f0a9bbcfbcc71db14fce19cd78d614','sql',100,true),
  ('api.hybrid_search_lifecyclemodels_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','584cd7922e9da6458bd8160d642ba553','sql',100,true),
  ('api.hybrid_search_processes(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','6b42d5d3c1f097ec7371921c86b026da','sql',100,true),
  ('api.hybrid_search_processes_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])','1c13c5abae0a9d0775d044d199626cdc','sql',100,true),
  ('api.hybrid_search_sources(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','d4a01baecb5f125ec686d63799d2521f','sql',100,true),
  ('api.hybrid_search_sources_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','e7a1a741f1a0c3074f014354ab7d900a','sql',100,true),
  ('api.hybrid_search_unitgroups(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','e0092be15fe182fb51ce9dd308b61da1','sql',100,true),
  ('api.hybrid_search_unitgroups_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)','55e97f8a3730477da58656214be2d8b6','sql',100,true),
  ('api.search_contacts(text,jsonb,integer,integer,text,text,uuid,integer)','f8bb07f57a85bf6bc55f6b9e7a872257','plpgsql',1000,false),
  ('api.search_contacts_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)','7a33fc38a8115fa7856afebef2a571c9','plpgsql',1000,false),
  ('api.search_flowproperties(text,jsonb,integer,integer,text,text,uuid,integer)','b7617e56165d6f2d216592ec62f5a4ab','plpgsql',1000,false),
  ('api.search_flowproperties_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)','7fe730527f91a80d5d2e3f6b17b8b088','plpgsql',1000,false),
  ('api.search_flows(text,jsonb,integer,integer,text,text,uuid,integer,text[])','0be76355ae924caa893bbcebd69d39c9','plpgsql',1000,false),
  ('api.search_flows_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[])','397a26702b254bfbfffda49605b5335f','plpgsql',1000,false),
  ('api.search_lifecyclemodels(text,jsonb,integer,integer,text,text,uuid,integer,text[])','afc2fcd263683c281f8160e4e24b4d1f','plpgsql',1000,false),
  ('api.search_lifecyclemodels_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[])','679390d8a8e3c38c94e593d97a2b5a76','plpgsql',1000,false),
  ('api.search_processes(text,jsonb,integer,integer,text,text,uuid,integer,text,text[],boolean)','ff85b915e71070d7e898401ba1bc5d5c','sql',1000,false),
  ('api.search_processes_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[])','e29e0e2c12ff06a581dd7777390ff7d8','sql',1000,false),
  ('api.search_processes_latest_v2(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean)','1e35291804b3caabf8f73a53d75bdc33','sql',1000,false),
  ('api.search_sources(text,jsonb,integer,integer,text,text,uuid,integer)','f6a894c8e8d3e3ec0343a6b595918c8f','plpgsql',1000,false),
  ('api.search_sources_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)','217562a5ee8f685c7875044a7a75641a','plpgsql',1000,false),
  ('api.search_unitgroups(text,jsonb,integer,integer,text,text,uuid,integer)','48edd3b12c5ba14f0159ac544579d079','plpgsql',1000,false),
  ('api.search_unitgroups_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)','cdca6052404c0998ecdfaf22d7e54402','plpgsql',1000,false);
create temp table raw793_before on commit drop as
select p.* from pg_catalog.pg_proc p join raw793_targets t
  on p.oid=pg_catalog.to_regprocedure(t.signature);

-- Production postgres is not a superuser and its supabase_admin-granted
-- executor membership has INHERIT=false/SET=false. Borrow only our own SET
-- grant; preserve every pre-existing grantor row and the schema ACL exactly.
create temp table raw793_membership_before on commit drop as
select m.* from pg_catalog.pg_auth_members m
where m.roleid='api_internal_executor'::regrole and m.member=current_user::regrole;
create temp table raw793_schema_before on commit drop as
select oid,nspacl from pg_catalog.pg_namespace where oid='api'::regnamespace;
do $authority_begin$
declare own_grant jsonb; actor text:=current_user;
begin
  select pg_catalog.jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
    into own_grant from pg_catalog.pg_auth_members m
    where m.roleid='api_internal_executor'::regrole and m.member=current_user::regrole
      and m.grantor=current_user::regrole;
  perform pg_catalog.set_config('raw793.ddl_actor',actor,true);
  perform pg_catalog.set_config('raw793.own_grant',coalesce(own_grant,'null'::jsonb)::text,true);
  perform pg_catalog.set_config('raw793.create_added',
    (not pg_catalog.has_schema_privilege('api_internal_executor','api','CREATE'))::text,true);
  execute pg_catalog.format('grant api_internal_executor to %I with inherit false, set true',actor);
  if pg_catalog.current_setting('raw793.create_added')::boolean then
    grant create on schema api to api_internal_executor;
  end if;
end;
$authority_begin$;
do $temp_access$
begin
  execute pg_catalog.format('grant usage on schema %I to api_internal_executor',
    (select nspname from pg_catalog.pg_namespace where oid=pg_catalog.pg_my_temp_schema()));
end;
$temp_access$;
grant select on table raw793_targets,raw793_before to api_internal_executor;
set local role api_internal_executor;

do $bounds$
declare
  target record;
  proc record;
  definition text;
  bounded_body text;
  guard text;
begin
  if (select count(*) from raw793_before)<>29 then
    raise exception using errcode='55000',message='Database #793 raw search target set drift';
  end if;
  for target in select * from raw793_targets order by signature loop
    select p.*,l.lanname into strict proc from pg_catalog.pg_proc p
      join pg_catalog.pg_language l on l.oid=p.prolang
      where p.oid=target.signature::regprocedure;
    if pg_catalog.md5(proc.prosrc) is distinct from target.source_md5
       or proc.lanname is distinct from target.source_language
       or proc.proowner is distinct from 'api_internal_executor'::regrole
       or not proc.prosecdef or proc.proisstrict then
      raise exception using errcode='55000',message='Database #793 raw search facade prestate drift';
    end if;
    guard:=pg_catalog.format($guard$
  -- raw793 bounds: validate original inputs before the existing delegate.
  if page_size > %s then
    raise exception using errcode='22023',message='Raw search page_size exceeds %s';
  end if;
$guard$,target.page_cap,target.page_cap);
    if target.hybrid then
      guard:=guard||$guard$  if match_count > 100 then
    raise exception using errcode='22023',message='Raw hybrid match_count exceeds 100';
  end if;
$guard$;
    end if;
    guard:=guard||$guard$  if greatest(coalesce(page_current::bigint,1),1)-1
       > 2147483647::bigint / greatest(coalesce(page_size::bigint,10),1) then
    raise exception using errcode='22023',message='Raw search normalized offset exceeds 2147483647';
  end if;
  -- raw793 bounds end.
$guard$;
    if proc.lanname='plpgsql' then
      if (length(proc.prosrc)-length(replace(proc.prosrc,E'begin\n','')))
           /length(E'begin\n')<>1 then
        raise exception using errcode='55000',message='Database #793 lexical delegate shape drift';
      end if;
      bounded_body:=replace(proc.prosrc,E'begin\n',E'begin\n'||guard);
    else
      -- The SQL facade has one SELECT only. Preserve that SELECT byte-for-byte
      -- under RETURN QUERY, so validation executes before its heavy delegate.
      if proc.prosrc !~ '^\s*select\s' or proc.prosrc ~ '\$function\$' then
        raise exception using errcode='55000',message='Database #793 SQL delegate shape drift';
      end if;
      bounded_body:=E'\nbegin\n'||guard||E'  return query\n'
        ||regexp_replace(proc.prosrc,';?\s*$','')||E';\nend;\n';
    end if;
    definition:=pg_catalog.pg_get_functiondef(proc.oid);
    if proc.lanname='sql' then
      if strpos(definition,'LANGUAGE sql')=0 then
        raise exception using errcode='55000',message='Database #793 SQL language header drift';
      end if;
      definition:=replace(definition,'LANGUAGE sql','LANGUAGE plpgsql');
    end if;
    if strpos(definition,'AS $function$'||proc.prosrc||'$function$')=0 then
      raise exception using errcode='55000',message='Database #793 function body boundary drift';
    end if;
    execute replace(definition,'AS $function$'||proc.prosrc||'$function$',
      'AS $function$'||bounded_body||'$function$');
  end loop;
  if exists(select 1 from raw793_before b left join pg_catalog.pg_proc p using(oid)
      where p.oid is null or (to_jsonb(b)-'prosrc'-'prolang')
        is distinct from (to_jsonb(p)-'prosrc'-'prolang')) then
    raise exception using errcode='55000',message='Database #793 raw search facade metadata changed';
  end if;
end;
$bounds$;
reset role;
do $authority_end$
declare own_grant jsonb; actor text:=pg_catalog.current_setting('raw793.ddl_actor');
begin
  -- Test harnesses may enter as a selected migration role. Return to that exact
  -- actor rather than using the session owner's broader restoration authority.
  execute pg_catalog.format('set local role %I',actor);
  if pg_catalog.current_setting('raw793.create_added')::boolean then
    revoke create on schema api from api_internal_executor;
  end if;
  own_grant:=pg_catalog.current_setting('raw793.own_grant')::jsonb;
  if own_grant='null'::jsonb then
    execute pg_catalog.format('revoke api_internal_executor from %I',actor);
  else
    execute pg_catalog.format('grant api_internal_executor to %I with admin %s, inherit %s, set %s',
      actor,own_grant->>'admin',own_grant->>'inherit',own_grant->>'set');
  end if;
  if exists((select * from raw793_membership_before
      except select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member=actor::regrole)
    union all (select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member=actor::regrole
      except select * from raw793_membership_before))
     or exists(select 1 from raw793_schema_before b join pg_catalog.pg_namespace n using(oid)
       where n.nspacl is distinct from b.nspacl) then
    raise exception using errcode='55000',message='Database #793 temporary DDL authority did not restore exactly';
  end if;
end;
$authority_end$;
commit;
