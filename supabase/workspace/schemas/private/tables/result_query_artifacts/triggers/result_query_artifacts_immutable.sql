CREATE OR REPLACE TRIGGER "result_query_artifacts_immutable" BEFORE DELETE OR UPDATE ON "private"."result_query_artifacts" FOR EACH ROW EXECUTE FUNCTION "private"."result_query_immutable_guard"();
