CREATE OR REPLACE VIEW "private"."dataset_display_catalog" AS
 SELECT 'lifecyclemodel'::"text" AS "dataset_kind",
    "lifecyclemodels"."id" AS "dataset_id",
    ("lifecyclemodels"."version")::"text" AS "dataset_version",
    ("lifecyclemodels"."json" #> '{lifeCycleModelDataSet,lifeCycleModelInformation,dataSetInformation,name}'::"text"[]) AS "name",
    "lifecyclemodels"."state_code"
   FROM "public"."lifecyclemodels"
UNION ALL
 SELECT 'process'::"text" AS "dataset_kind",
    "processes"."id" AS "dataset_id",
    ("processes"."version")::"text" AS "dataset_version",
    ("processes"."json" #> '{processDataSet,processInformation,dataSetInformation,name}'::"text"[]) AS "name",
    "processes"."state_code"
   FROM "public"."processes"
UNION ALL
 SELECT 'flow'::"text" AS "dataset_kind",
    "flows"."id" AS "dataset_id",
    ("flows"."version")::"text" AS "dataset_version",
    ("flows"."json" #> '{flowDataSet,flowInformation,dataSetInformation,name}'::"text"[]) AS "name",
    "flows"."state_code"
   FROM "public"."flows"
UNION ALL
 SELECT 'flowproperty'::"text" AS "dataset_kind",
    "flowproperties"."id" AS "dataset_id",
    ("flowproperties"."version")::"text" AS "dataset_version",
    ("flowproperties"."json" #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name}'::"text"[]) AS "name",
    "flowproperties"."state_code"
   FROM "public"."flowproperties"
UNION ALL
 SELECT 'unitgroup'::"text" AS "dataset_kind",
    "unitgroups"."id" AS "dataset_id",
    ("unitgroups"."version")::"text" AS "dataset_version",
    ("unitgroups"."json" #> '{unitGroupDataSet,unitGroupInformation,dataSetInformation,common:name}'::"text"[]) AS "name",
    "unitgroups"."state_code"
   FROM "public"."unitgroups"
UNION ALL
 SELECT 'source'::"text" AS "dataset_kind",
    "sources"."id" AS "dataset_id",
    ("sources"."version")::"text" AS "dataset_version",
    COALESCE(("sources"."json" #> '{sourceDataSet,sourceInformation,dataSetInformation,common:shortName}'::"text"[]), ("sources"."json" #> '{sourceDataSet,sourceInformation,dataSetInformation,sourceCitation}'::"text"[])) AS "name",
    "sources"."state_code"
   FROM "public"."sources"
UNION ALL
 SELECT 'contact'::"text" AS "dataset_kind",
    "contacts"."id" AS "dataset_id",
    ("contacts"."version")::"text" AS "dataset_version",
    COALESCE(("contacts"."json" #> '{contactDataSet,contactInformation,dataSetInformation,common:name}'::"text"[]), ("contacts"."json" #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}'::"text"[])) AS "name",
    "contacts"."state_code"
   FROM "public"."contacts";

ALTER VIEW "private"."dataset_display_catalog" OWNER TO "postgres";
