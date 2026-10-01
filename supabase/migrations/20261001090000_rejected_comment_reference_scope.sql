-- Database #762: current rejection opinions (-3) do not admit dependencies.
-- cmd_review_submit_comment provisions references only for state 1; final
-- approval applies only that metadata. Match current derivation to those writes.
-- Retain finalized Comment state 2 compatibility and real-reference guards.
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
  'Resolves exact current Root JSON, approving submissions (1) and retained finalized-Comment compatibility (2). Current rejection opinions (-3), drafts (0), revoked (-2) and terminal rejected (-1) Comments do not add dependencies. State 2 records finalization, not the original decision; exact current Reference Review guards remain intact.';

commit;
