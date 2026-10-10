CREATE INDEX "d807_portal_sitemap_rows_shard_v1_idx" ON "private"."display_sitemap_rows_v1" USING "btree" ("shard_no", "contract_version", "dataset_kind", "id", "version" DESC, "modified_at" DESC);
