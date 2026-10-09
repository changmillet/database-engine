CREATE INDEX "dataset_display_settings_visible_idx" ON "private"."dataset_display_settings" USING "btree" ("dataset_kind", "dataset_id", "dataset_version") WHERE "is_visible";
