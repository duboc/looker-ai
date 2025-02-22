/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module "project-services" {
  source                      = "terraform-google-modules/project-factory/google//modules/project_services"
  version                     = "14.2.1"
  disable_services_on_destroy = false

  project_id  = var.project_id
  enable_apis = true

  activate_apis = [
    "cloudresourcemanager.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "cloudapis.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
    "storage-api.googleapis.com",
    "storage.googleapis.com",
    "workflows.googleapis.com",
    "aiplatform.googleapis.com",
    "compute.googleapis.com"
  ]
}

resource "time_sleep" "wait_after_apis_activate" {
  depends_on      = [module.project-services]
  create_duration = "300s"
}


data "google_project" "project" {}

# [START storage_create_new_bucket_tf]
# Create new storage bucket in the US multi-region
# with coldline storage
resource "random_string" "random" {
  length  = 3
  special = false
  lower   = true
  upper   = false
}

# [START workflows_serviceaccount_create]
resource "google_service_account" "looker_llm_service_account" {
  account_id   = "looker-llm-sa"
  display_name = "Looker LLM SA"
  depends_on   = [time_sleep.wait_after_apis_activate]
}
# TODO: Remove Editor and apply right permissions
resource "google_project_iam_member" "iam_permission_looker_bq" {
  project    = var.project_id
  role       = "roles/editor"
  member     = format("serviceAccount:%s", google_service_account.looker_llm_service_account.email)
  depends_on = [time_sleep.wait_after_apis_activate]
}
resource "google_project_iam_member" "iam_permission_looker_aiplatform" {
  project    = var.project_id
  role       = "roles/aiplatform.user"
  member     = format("serviceAccount:%s", google_service_account.looker_llm_service_account.email)
  depends_on = [time_sleep.wait_after_apis_activate]
}

# IAM for connection to be able to execute vertex ai queries through BQ
resource "google_project_iam_member" "bigquery_connection_remote_model" {
  project    = var.project_id
  role       = "roles/aiplatform.user"
  member     = format("serviceAccount:%s", google_bigquery_connection.connection.cloud_resource[0].service_account_id)
  depends_on = [time_sleep.wait_after_apis_activate, google_bigquery_connection.connection]
}

resource "google_project_iam_member" "iam_service_account_act_as" {
  project    = var.project_id
  role       = "roles/iam.serviceAccountUser"
  member     = format("serviceAccount:%s", google_service_account.looker_llm_service_account.email)
  depends_on = [time_sleep.wait_after_apis_activate]
}
# IAM permission as Editor
resource "google_project_iam_member" "iam_looker_service_usage" {
  project    = var.project_id
  role       = "roles/serviceusage.serviceUsageConsumer"
  member     = format("serviceAccount:%s", google_service_account.looker_llm_service_account.email)
  depends_on = [time_sleep.wait_after_apis_activate]
}

# IAM permission as Editor
resource "google_project_iam_member" "iam_looker_bq_consumer" {
  project    = var.project_id
  role       = "roles/bigquery.connectionUser"
  member     = format("serviceAccount:%s", google_service_account.looker_llm_service_account.email)
  depends_on = [time_sleep.wait_after_apis_activate]
}

resource "google_bigquery_dataset" "dataset" {
  dataset_id    = var.dataset_id_name
  friendly_name = "llm"
  description   = "bq llm dataset for remote UDF"
  location      = var.bq_region

  depends_on = [time_sleep.wait_after_apis_activate]
}

## This creates a cloud resource connection.
## Note: The cloud resource nested object has only one output only field - serviceAccountId.
resource "google_bigquery_connection" "connection" {
  connection_id = "${var.bq_remote_connection_name}-${random_string.random.result}"
  project       = var.project_id
  location      = var.bq_region
  cloud_resource {}
  depends_on = [time_sleep.wait_after_apis_activate]
}

resource "google_bigquery_job" "create_bq_model_llm" {
  job_id = "create_looker_llm_model-${random_string.random.result}"
  query {
    query              = <<EOF
CREATE OR REPLACE MODEL `${var.project_id}.${var.dataset_id_name}.llm_model` 
REMOTE WITH CONNECTION `${var.project_id}.${var.bq_region}.${var.bq_remote_connection_name}-${random_string.random.result}` 
OPTIONS (REMOTE_SERVICE_TYPE = 'CLOUD_AI_LARGE_LANGUAGE_MODEL_V1')
EOF  
    create_disposition = ""
    write_disposition  = ""
  }
  depends_on = [google_bigquery_connection.connection, google_bigquery_dataset.dataset, time_sleep.wait_after_apis_activate]
}

resource "google_bigquery_table" "table_top_prompts" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "explore_prompts"
  deletion_protection = false

  schema     = <<EOF
[
  {
    "name": "description",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "prompt",
    "type": "STRING",
    "mode": "REQUIRED"
  },  
  {
    "name": "model_explore",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "type",
    "type": "STRING", 
    "mode": "NULLABLE"       
  }
]
EOF
  depends_on = [time_sleep.wait_after_apis_activate]
}

resource "google_bigquery_table" "table_explore_logging" {
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = "explore_logging"
  time_partitioning {
    type  = "DAY"
    field = "creation_timestamp"
  }
  deletion_protection = false
  schema              = <<EOF
[{
	"name": "userInput",
	"type": "STRING"
}, {
	"name": "modelFields",
	"type": "JSON"
}, {
	"name": "llmResult",
	"type": "JSON"
}, {
	"name": "creation_timestamp",
	"type": "TIMESTAMP"
}]
EOF
  depends_on = [time_sleep.wait_after_apis_activate]
}







