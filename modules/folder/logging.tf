/**
 * Copyright 2022 Google LLC
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

# tfdoc:file:description Log sinks and supporting resources.

locals {
  sink_bindings = {
    for type in ["bigquery", "pubsub", "logging", "storage"] :
    type => {
      for name, sink in var.logging_sinks :
      name => sink
      if sink.type == type
    }
  }
}

resource "google_folder_iam_audit_config" "default" {
  for_each = (
    var.iam_policy == null ? var.logging_data_access : {}
  )
  folder  = local.folder.name
  service = each.key
  dynamic "audit_log_config" {
    for_each = each.value
    iterator = config
    content {
      log_type         = config.key
      exempted_members = config.value
    }
  }
}

resource "google_logging_folder_sink" "sink" {
  for_each         = var.logging_sinks
  name             = each.key
  description      = coalesce(each.value.description, "${each.key} (Terraform-managed).")
  folder           = local.folder.name
  destination      = "${each.value.type}.googleapis.com/${each.value.destination}"
  filter           = each.value.filter
  include_children = each.value.include_children
  disabled         = each.value.disabled

  dynamic "bigquery_options" {
    for_each = each.value.type == "biquery" && each.value.bq_partitioned_table != false ? [""] : []
    content {
      use_partitioned_tables = each.value.bq_partitioned_table
    }
  }

  dynamic "exclusions" {
    for_each = each.value.exclusions
    iterator = exclusion
    content {
      name   = exclusion.key
      filter = exclusion.value
    }
  }

  depends_on = [
    google_folder_iam_binding.authoritative
  ]
}

resource "google_storage_bucket_iam_member" "gcs-sinks-binding" {
  for_each = local.sink_bindings["storage"]
  bucket   = each.value.destination
  role     = "roles/storage.objectCreator"
  member   = google_logging_folder_sink.sink[each.key].writer_identity
}

resource "google_bigquery_dataset_iam_member" "bq-sinks-binding" {
  for_each   = local.sink_bindings["bigquery"]
  project    = split("/", each.value.destination)[1]
  dataset_id = split("/", each.value.destination)[3]
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_folder_sink.sink[each.key].writer_identity
}

resource "google_pubsub_topic_iam_member" "pubsub-sinks-binding" {
  for_each = local.sink_bindings["pubsub"]
  project  = split("/", each.value.destination)[1]
  topic    = split("/", each.value.destination)[3]
  role     = "roles/pubsub.publisher"
  member   = google_logging_folder_sink.sink[each.key].writer_identity
}

resource "google_project_iam_member" "bucket-sinks-binding" {
  for_each = local.sink_bindings["logging"]
  project  = split("/", each.value.destination)[1]
  role     = "roles/logging.bucketWriter"
  member   = google_logging_folder_sink.sink[each.key].writer_identity

  condition {
    title       = "${each.key} bucket writer"
    description = "Grants bucketWriter to ${google_logging_folder_sink.sink[each.key].writer_identity} used by log sink ${each.key} on ${local.folder.id}"
    expression  = "resource.name.endsWith('${each.value.destination}')"
  }
}

resource "google_logging_folder_exclusion" "logging-exclusion" {
  for_each    = var.logging_exclusions
  name        = each.key
  folder      = local.folder.name
  description = "${each.key} (Terraform-managed)."
  filter      = each.value
}
