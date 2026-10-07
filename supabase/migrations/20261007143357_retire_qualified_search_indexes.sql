-- Database #793: qualified contraction, after current consumer and local-volume proof.
-- No table, writer, shared rank-key helper, or current V2 access method is retired.
begin;
set local lock_timeout='3s';
set local statement_timeout='30s';
set local search_path='';

-- Borrow SET authority through the existing closed NOLOGIN owner. Preserve
-- every prior membership row/options; no external role or routine ACL changes.
do $retire_793_acl_begin$
declare v_before jsonb;v_all_before jsonb;
begin
  if current_user<>'postgres' then
    raise exception using errcode='42501',message='Search retirement requires the postgres migration actor';
  end if;
  if not exists(select 1 from pg_catalog.pg_roles where rolname='portal_public_executor'
      and not rolcanlogin and not rolinherit and not rolsuper and not rolbypassrls
      and not rolcreaterole) then
    raise exception using errcode='55000',message='Search retirement Portal owner role drifted';
  end if;
  select jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
    into v_before from pg_catalog.pg_auth_members m
    where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole
      and m.grantor=current_user::regrole;
  select coalesce(jsonb_agg(to_jsonb(m) order by m.grantor,m.oid),'[]'::jsonb)
    into v_all_before from pg_catalog.pg_auth_members m
    where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole;
  perform pg_catalog.set_config('retire793.portal_grant',coalesce(v_before,'null'::jsonb)::text,true);
  perform pg_catalog.set_config('retire793.portal_memberships',v_all_before::text,true);
  perform pg_catalog.set_config('retire793.private_schema',(
    select jsonb_build_object('owner',nspowner,'acl',to_jsonb(nspacl))::text
    from pg_catalog.pg_namespace where oid='private'::regnamespace),true);
  grant portal_public_executor to postgres with inherit false,set true;
end
$retire_793_acl_begin$;

-- Hold the same owning relations required by ordinary DROP INDEX throughout
-- catalog validation, preventing a same-name replacement between check/drop.
lock table private.lcia_scope_closure_issue_roots,
  private.portal_catalog_search_rows_v1,public.lciamethods
  in access exclusive mode;

do $retire_793$
declare
  v_index record;
  v_routine record;
  v_present_indexes integer;
  v_present_routines integer;
  v_pk pg_catalog.pg_index%rowtype;
  v_candidate pg_catalog.pg_index%rowtype;
  v_oid oid;
  v_routine_oids oid[];
  v_ord integer;
  v_indexes constant text[] := array[
    'private.lcia_scope_closure_issue_roots_issue_idx',
    'public.lciamethods_json_idx',
    'private.portal_catalog_search_process_document_v1_pgroonga',
    'private.portal_catalog_search_process_exact_rank_v1_gin',
    'public.lciamethods_json_pgroonga'];
  v_routines constant text[] := array[
    'private.catalog_portal_process_keyword_relevance_v1_impl(text,text,uuid,text,integer,text)',
    'private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer)',
    'private.assert_portal_process_keyword_rank_contract_v1()',
    'private.portal_process_keyword_rank_manifest_sha256_v1()'];
begin
  -- These assertions pin current Process V2 + retained Flow V1 routing, RLS,
  -- manifests and the V2 GIN, rather than trusting a retained v1 function name.
  execute 'set local role portal_public_executor';
  perform private.assert_portal_catalog_projection_contract_cn1();
  perform private.assert_portal_process_keyword_rank_contract_cn1();
  execute 'reset role';
  if (select pg_catalog.md5(prosrc) from pg_catalog.pg_proc where oid=
      'private.catalog_portal_process_pattern_versions_v1(text)'::regprocedure)
       is distinct from 'c39d6bcf3cee67a00fb278e0893f1afe'
     or (select pg_catalog.md5(prosrc) from pg_catalog.pg_proc where oid=
       'private.catalog_portal_process_keyword_keys_cn1(text,text,uuid,text,integer)'::regprocedure)
       is distinct from 'a57bfbc54c86e697e2cdabc42dc90f45'
     or pg_catalog.pg_get_functiondef(
       'private.catalog_portal_process_pattern_versions_v1(text)'::regprocedure
     ) not like '%private.portal_catalog_search_current_v2%'
     or pg_catalog.pg_get_functiondef(
       'private.catalog_portal_process_keyword_keys_cn1(text,text,uuid,text,integer)'::regprocedure
     ) not like '%private.portal_catalog_search_rows_v2%'
     or (select count(*) from pg_catalog.pg_trigger
         where tgrelid='public.processes'::regclass
           and tgname in ('portal_catalog_projection_content_sync_v1',
                          'portal_catalog_projection_content_sync_v2')
           and tgenabled='O' and not tgisinternal) <> 2 then
    raise exception using errcode='55000',message='Search retirement current routing or writers drifted';
  end if;

  select * into strict v_pk from pg_catalog.pg_index
  where indexrelid='private.lcia_scope_closure_issue_roots_pkey'::regclass;
  if not (v_pk.indisprimary and v_pk.indisunique and v_pk.indisvalid
          and v_pk.indisready and v_pk.indislive)
     or v_pk.indnkeyatts<>5 or v_pk.indnatts<>5
     or v_pk.indexprs is not null or v_pk.indpred is not null
     or pg_catalog.pg_get_indexdef(v_pk.indexrelid) <>
       'CREATE UNIQUE INDEX lcia_scope_closure_issue_roots_pkey ON private.lcia_scope_closure_issue_roots USING btree (closure_issue_id, root_dataset_type, root_dataset_id, root_dataset_version, impact_role)'
     or (select count(*) from pg_catalog.pg_constraint where
         conrelid='private.lcia_scope_closure_issue_roots'::regclass and contype='f'
         and pg_catalog.pg_get_constraintdef(oid)=
         'FOREIGN KEY (closure_issue_id) REFERENCES private.lcia_scope_closure_issues(id) ON DELETE CASCADE')<>1
     or exists (select 1 from pg_catalog.pg_constraint
                where confrelid='private.lcia_scope_closure_issue_roots'::regclass)
     or exists (select 1 from pg_catalog.pg_trigger
                where tgrelid='private.lcia_scope_closure_issue_roots'::regclass
                  and not tgisinternal) then
    raise exception using errcode='55000',message='Search retirement issue roots PK or RI contract drifted';
  end if;
  if (select count(*) from pg_catalog.pg_policies where schemaname='public'
      and tablename='lciamethods' and cmd='SELECT' and permissive='PERMISSIVE'
      and roles=array['authenticated']::name[] and qual='true')<>1
     or (select count(*) from pg_catalog.pg_policies where schemaname='public'
         and tablename='lciamethods' and policyname='oauth_client_select_capability_guard'
         and permissive='RESTRICTIVE' and roles=array['authenticated']::name[]
         and qual like '%DB-CORE-READ-01%')<>1
     or (select not relrowsecurity or relowner<>'postgres'::regrole
         from pg_catalog.pg_class where oid='public.lciamethods'::regclass) is not false
     or (select count(*) from pg_catalog.pg_trigger where tgrelid='public.lciamethods'::regclass
         and tgname in ('lcia_scope_closure_candidate_hash_refresh',
                        'lciamethods_json_sync_trigger','lciamethods_set_modified_at_trigger')
         and tgenabled='O' and not tgisinternal)<>3 then
    raise exception using errcode='55000',message='Search retirement LCIA relation authorization or writers drifted';
  end if;

  select count(*) into v_present_indexes from unnest(v_indexes) identity
    where pg_catalog.to_regclass(identity) is not null;
  select count(*),array_agg(pg_catalog.to_regprocedure(identity)::oid)
    into v_present_routines,v_routine_oids from unnest(v_routines) identity
    where pg_catalog.to_regprocedure(identity) is not null;
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='private' and p.proname in(
        'catalog_portal_process_keyword_relevance_v1_impl','catalog_portal_process_keyword_keys_v1',
        'assert_portal_process_keyword_rank_contract_v1','portal_process_keyword_rank_manifest_sha256_v1'))
     <> v_present_routines then
    raise exception using errcode='55000',message='Search retirement legacy helper overload drifted';
  end if;
  -- A fully verified terminal replay is harmless; partial absence is unknown.
  if v_present_indexes=0 and v_present_routines=0 then
    return;
  elsif v_present_indexes<>5 or v_present_routines<>4 then
    raise exception using errcode='55000',message='Search retirement has an unknown partial object state';
  end if;

  for v_index in select * from (values
    ('private.lcia_scope_closure_issue_roots_issue_idx','private.lcia_scope_closure_issue_roots','btree',
     'CREATE INDEX lcia_scope_closure_issue_roots_issue_idx ON private.lcia_scope_closure_issue_roots USING btree (closure_issue_id, root_dataset_type, root_dataset_id, root_dataset_version)'),
    ('public.lciamethods_json_idx','public.lciamethods','gin',
     'CREATE INDEX lciamethods_json_idx ON public.lciamethods USING gin ("json")'),
    ('private.portal_catalog_search_process_document_v1_pgroonga','private.portal_catalog_search_rows_v1','pgroonga',
     'CREATE INDEX portal_catalog_search_process_document_v1_pgroonga ON private.portal_catalog_search_rows_v1 USING pgroonga (document) WITH (tokenizer=''TokenBigram'', normalizer=''NormalizerAuto'') WHERE (dataset_kind = ''process''::text)'),
    ('private.portal_catalog_search_process_exact_rank_v1_gin','private.portal_catalog_search_rows_v1','gin',
     'CREATE INDEX portal_catalog_search_process_exact_rank_v1_gin ON private.portal_catalog_search_rows_v1 USING gin (private.portal_process_rank_name_keys_v1(card), private.portal_process_rank_classification_keys_v1(card)) WHERE (dataset_kind = ''process''::text)'),
    ('public.lciamethods_json_pgroonga','public.lciamethods','pgroonga',
     'CREATE INDEX lciamethods_json_pgroonga ON public.lciamethods USING pgroonga ("json" extensions.pgroonga_jsonb_full_text_search_ops_v2)')
  ) expected(identity,table_identity,access_method,definition) loop
    v_oid:=pg_catalog.to_regclass(v_index.identity);
    if not exists (select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_index i on i.indexrelid=c.oid
        join pg_catalog.pg_am a on a.oid=c.relam
        where c.oid=v_oid and c.relowner='postgres'::regrole
          and c.relkind='i' and a.amname=v_index.access_method
          and i.indrelid=pg_catalog.to_regclass(v_index.table_identity)
          and i.indisvalid and i.indisready and i.indislive
          and not i.indisprimary and not i.indisunique and not i.indisexclusion
          and i.indnatts=i.indnkeyatts
          and pg_catalog.pg_get_indexdef(c.oid)=v_index.definition)
       or exists (select 1 from pg_catalog.pg_constraint where conindid=v_oid)
       or exists (select 1 from pg_catalog.pg_depend
                  where refclassid='pg_catalog.pg_class'::regclass and refobjid=v_oid)
       or exists (select 1 from pg_catalog.pg_depend
                  where classid='pg_catalog.pg_class'::regclass and objid=v_oid
                    and deptype in ('e','x')) then
      raise exception using errcode='55000',message='Search retirement index definition or dependencies drifted';
    end if;
  end loop;
  select * into strict v_candidate from pg_catalog.pg_index
    where indexrelid='private.lcia_scope_closure_issue_roots_issue_idx'::regclass;
  if v_candidate.indnkeyatts<>4 or v_candidate.indnatts<>4
     or v_candidate.indexprs is not null or v_candidate.indpred is not null then
    raise exception using errcode='55000',message='Search retirement roots prefix layout drifted';
  end if;
  for v_ord in 0..3 loop
    if v_candidate.indkey[v_ord]<>v_pk.indkey[v_ord]
       or v_candidate.indclass[v_ord]<>v_pk.indclass[v_ord]
       or v_candidate.indcollation[v_ord]<>v_pk.indcollation[v_ord]
       or v_candidate.indoption[v_ord]<>v_pk.indoption[v_ord] then
      raise exception using errcode='55000',message='Search retirement roots PK prefix is not an exact replacement';
    end if;
  end loop;

  execute 'set local role portal_public_executor';
  perform private.assert_portal_process_keyword_rank_contract_v1();
  execute 'reset role';
  for v_routine in select * from (values
    (v_routines[1],'9a33af21be38a3a121577fc542a22c52','sql',
      array['search_path=""','statement_timeout=8s','plan_cache_mode=force_custom_plan','row_security=on']::text[]),
    (v_routines[2],'13a1867c89e10247136d748c53ce7dec','plpgsql',
      array['search_path=""','statement_timeout=8s','plan_cache_mode=force_custom_plan','row_security=on']::text[]),
    (v_routines[3],'8aec6cf20b256f4e4d62594d5d05f39d','plpgsql',array['search_path=""','row_security=on']::text[]),
    (v_routines[4],'ad012c29a9a98eb912bf22eab20b169b','sql',array['search_path=""','row_security=on']::text[])
  ) expected(identity,body_md5,language,config) loop
    v_oid:=pg_catalog.to_regprocedure(v_routine.identity);
    if not exists (select 1 from pg_catalog.pg_proc p
        join pg_catalog.pg_language l on l.oid=p.prolang
        where p.oid=v_oid and p.proowner='portal_public_executor'::regrole
          and p.prosecdef and p.provolatile='s' and p.proparallel='r'
          and l.lanname=v_routine.language and p.proconfig=v_routine.config
          and pg_catalog.md5(p.prosrc)=v_routine.body_md5)
       or exists (select 1 from pg_catalog.pg_proc p cross join lateral
                  pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
                  where p.oid=v_oid and a.grantee<>p.proowner)
       or exists (select 1 from private.api_capability_grants where routine_identity=v_routine.identity)
       or exists (select 1 from unnest(array['anon','authenticated','service_role','api_internal_executor']) role_name
                  where pg_catalog.has_function_privilege(role_name,v_oid,'EXECUTE'))
       or exists (select 1 from pg_catalog.pg_depend
                  where refclassid='pg_catalog.pg_proc'::regclass and refobjid=v_oid
                    and not (classid='pg_catalog.pg_proc'::regclass and objid=any(v_routine_oids)))
       or exists (select 1 from pg_catalog.pg_depend
                  where classid='pg_catalog.pg_proc'::regclass and objid=v_oid and deptype in ('e','x')) then
      raise exception using errcode='55000',message='Search retirement legacy helper definition ACL or dependencies drifted';
    end if;
  end loop;
  if exists (select 1 from pg_catalog.pg_proc p where p.prokind in ('f','p')
      and not (p.oid=any(v_routine_oids)) and p.prosrc ~*
      '\m(catalog_portal_process_keyword_relevance_v1_impl|catalog_portal_process_keyword_keys_v1|assert_portal_process_keyword_rank_contract_v1|portal_process_keyword_rank_manifest_sha256_v1)\M') then
    raise exception using errcode='55000',message='Search retirement found an unexpected legacy helper caller';
  end if;

  -- RESTRICT is deliberate. Any uncataloged/unanticipated DDL race aborts all
  -- five retirements and all four helper removals, rather than cascading scope.
  execute 'drop index private.lcia_scope_closure_issue_roots_issue_idx restrict';
  execute 'drop index public.lciamethods_json_idx restrict';
  execute 'drop index private.portal_catalog_search_process_document_v1_pgroonga restrict';
  execute 'drop index private.portal_catalog_search_process_exact_rank_v1_gin restrict';
  execute 'drop index public.lciamethods_json_pgroonga restrict';
  execute 'set local role portal_public_executor';
  execute 'drop function private.catalog_portal_process_keyword_relevance_v1_impl(text,text,uuid,text,integer,text) restrict';
  execute 'drop function private.catalog_portal_process_keyword_keys_v1(text,text,uuid,text,integer) restrict';
  execute 'drop function private.assert_portal_process_keyword_rank_contract_v1() restrict';
  execute 'drop function private.portal_process_keyword_rank_manifest_sha256_v1() restrict';
  perform private.assert_portal_catalog_projection_contract_cn1();
  perform private.assert_portal_process_keyword_rank_contract_cn1();
  execute 'reset role';
end
$retire_793$;
do $retire_793_acl_end$
declare v_before jsonb;v_all_after jsonb;
begin
  v_before:=pg_catalog.current_setting('retire793.portal_grant')::jsonb;
  if v_before='null'::jsonb then
    revoke portal_public_executor from postgres;
  else
    execute pg_catalog.format('grant portal_public_executor to postgres with admin %s, inherit %s, set %s',
      v_before->>'admin',v_before->>'inherit',v_before->>'set');
  end if;
  select coalesce(jsonb_agg(to_jsonb(m) order by m.grantor,m.oid),'[]'::jsonb)
    into v_all_after from pg_catalog.pg_auth_members m
    where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole;
  if current_user<>'postgres' or v_all_after is distinct from
     pg_catalog.current_setting('retire793.portal_memberships')::jsonb
     or (select jsonb_build_object('owner',nspowner,'acl',to_jsonb(nspacl))
         from pg_catalog.pg_namespace where oid='private'::regnamespace) is distinct from
        pg_catalog.current_setting('retire793.private_schema')::jsonb then
    raise exception using errcode='55000',message='Search retirement Portal membership restoration drifted';
  end if;
end
$retire_793_acl_end$;
commit;
