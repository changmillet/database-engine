-- Database #762: rejection opinions are evidence, not approved metadata.
-- cmd_review_submit_comment provisions references only for state 1; final
-- approval applies only that metadata. Match current derivation to those writes.
-- Keep real Root JSON and approval-comment dependencies fail-closed.
begin;

do $migration$
declare
  v_definition text := pg_catalog.pg_get_functiondef(
    'private.review_resolve_current_reference_targets_v1(uuid[])'::regprocedure
  );
  v_old constant text := 'and comment_row.state_code in (1, -3, 2)';
  v_new constant text := 'and comment_row.state_code in (1, 2)';
begin
  if pg_catalog.strpos(v_definition, v_old) = 0
    or pg_catalog.strpos(
      pg_catalog.substr(v_definition, pg_catalog.strpos(v_definition, v_old) + pg_catalog.length(v_old)),
      v_old
    ) > 0 then
    raise exception using errcode = '55000',
      message = 'EXPECTED_COMMENT_REFERENCE_FILTER_NOT_UNIQUE';
  end if;
  execute pg_catalog.replace(v_definition, v_old, v_new);
end;
$migration$;

comment on function private.review_resolve_current_reference_targets_v1(uuid[]) is
  'Resolves exact current Root JSON and approval Comment references (states 1, 2). Rejection opinions, drafts and revoked Comments do not create dependencies; real missing current Reference Reviews remain fail-closed.';

commit;
