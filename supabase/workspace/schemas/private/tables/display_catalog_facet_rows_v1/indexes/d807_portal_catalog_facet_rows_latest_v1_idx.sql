CREATE INDEX "d807_portal_catalog_facet_rows_latest_v1_idx" ON "private"."display_catalog_facet_rows_v1" USING "btree" ("dataset_kind", "id", "version" DESC, "modified_at" DESC, "state_code" DESC);
