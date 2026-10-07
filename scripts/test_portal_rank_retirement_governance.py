"""The obsolete four-helper retirement must not weaken live manifest protection."""
import unittest

from check_portal_projection_manifest import (
    MIGRATIONS_DIR,
    PROCESS_KEYWORD_RANK_FUNCTION_IDENTITIES,
    PROCESS_KEYWORD_RANK_RETIREMENT_NAME,
    RETIRED_PROCESS_KEYWORD_RANK_IDENTITIES,
    reviewed_process_rank_retirement,
    sql_without_comments,
)


class RetirementBoundary(unittest.TestCase):
    def test_reviewed_literal_drops(self):
        source = sql_without_comments(
            (MIGRATIONS_DIR / PROCESS_KEYWORD_RANK_RETIREMENT_NAME).read_text()
        )
        for identity in RETIRED_PROCESS_KEYWORD_RANK_IDENTITIES:
            with self.subTest(identity=identity):
                self.assertTrue(reviewed_process_rank_retirement(
                    PROCESS_KEYWORD_RANK_RETIREMENT_NAME, source, identity))

    def test_no_filename_or_ddl_kind_waiver(self):
        for identity in RETIRED_PROCESS_KEYWORD_RANK_IDENTITIES:
            good = f"execute 'drop function {identity} restrict';"
            rejected = (
                good.replace("restrict", "cascade"),
                good.replace("drop function", "drop routine"),
                good.replace("drop function", "alter function"),
                good.replace("drop function", "create or replace function"),
                good + good,
                good + f"alter function {identity} set search_path='public';",
                good.replace(identity, identity.replace("(", "(boolean,")),
            )
            for source in rejected:
                with self.subTest(identity=identity, source=source):
                    self.assertFalse(reviewed_process_rank_retirement(
                        PROCESS_KEYWORD_RANK_RETIREMENT_NAME, source, identity))
            self.assertFalse(reviewed_process_rank_retirement(
                "20261008000000_unreviewed.sql", good, identity))

    def test_shared_and_current_helpers_never_exempt(self):
        for identity in PROCESS_KEYWORD_RANK_FUNCTION_IDENTITIES[:2] + (
            "private.assert_portal_process_keyword_rank_contract_cn1()",
        ):
            self.assertFalse(reviewed_process_rank_retirement(
                PROCESS_KEYWORD_RANK_RETIREMENT_NAME,
                f"drop function {identity} restrict;", identity))

    def test_hidden_second_drop_target_rejects_the_whole_exception(self):
        source = sql_without_comments(
            (MIGRATIONS_DIR / PROCESS_KEYWORD_RANK_RETIREMENT_NAME).read_text()
        )
        for extra in (
            "drop function if exists private.issue793_probe(), private.portal_process_rank_name_keys_v1(jsonb) cascade;",
            "drop routine private.issue793_probe(), private.assert_portal_process_keyword_rank_contract_cn1() restrict;",
            "execute format('drop function %s cascade', 'private.portal_process_rank_name_keys_v1(jsonb)');",
        ):
            for identity in RETIRED_PROCESS_KEYWORD_RANK_IDENTITIES:
                with self.subTest(extra=extra, identity=identity):
                    self.assertFalse(reviewed_process_rank_retirement(
                        PROCESS_KEYWORD_RANK_RETIREMENT_NAME, source + extra, identity))


if __name__ == "__main__":
    unittest.main()
