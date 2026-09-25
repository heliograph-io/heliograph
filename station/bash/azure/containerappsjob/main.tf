# =============================================================================
#  containerappsjob/main.tf - run the heliograph agent as a scheduled Azure
#  Container Apps Job
# =============================================================================
#  The Terraform twin of containerappsjob/main.bicep. Same shape, same
#  traps, same result - see that file's header for the full reasoning,
#  especially the URL-travels-positionally workaround and the
#  scheduled-not-long-running trade-off.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "name" {
  description = "Name for the job."
  type        = string
  default     = "caj-heliograph"
}

variable "location" {
  description = "Location."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into."
  type        = string
}

variable "vnetName" {
  description = "Existing VNet. Accepted for parameter parity with the other hosts, but NOT used directly here: the Container Apps Environment already owns the VNet integration."
  type        = string
  default     = ""
}

variable "subnetName" {
  description = "Existing subnet. See vnetName above: accepted for parity, not used."
  type        = string
  default     = ""
}

variable "containerAppsEnvironmentName" {
  description = "Existing Container Apps Environment, VNet-integrated on its own dedicated /27-or-larger subnet delegated to Microsoft.App/environments."
  type        = string
}

variable "repoUrl" {
  description = "The transport repo to clone, https:// or git@. Empty for any transport but git, which has no repository to clone."
  type        = string
  default     = ""
}
# --- the transport -------------------------------------------------------------
# EVERY OTHER HOST TAKES ONE, and this template did not: it required a repoUrl
# and built a fixed environment, so a relay, share or blob station could not be
# deployed here at all. station.sh has taken TRANSPORT since A3 and the image
# carries the station payload, so the only thing missing was a way to say so.
#
# `env` AND `secureEnv` RATHER THAN A VARIABLE PER TRANSPORT. Each transport
# declares its own requirements with cap_need and the station reads them from
# the environment, so a template that named RELAY_URL, PIGEONHOLE_SAS and the
# rest would need editing every time a transport gains a variable - and would be
# five templates out of date at once.
variable "transport" {
  description = "Which channel the station uses: git, relay, share, blob. Anything but git needs no repoUrl - the image carries the payload."
  type        = string
  default     = "git"
}

variable "extraEnv" {
  description = "Extra plain environment, for the selected transport's own variables. Visible in the resource definition: put anything secret in extraSecureEnv."
  type        = map(string)
  default     = {}
}

variable "extraSecureEnv" {
  description = "Extra SECRET environment, for tokens."
  type        = map(string)
  default     = {}
  sensitive   = true
}


variable "gitToken" {
  description = "Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gitTokenUser" {
  description = "Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty."
  type        = string
  default     = ""
}

variable "image" {
  description = "Image to run."
  type        = string
  default     = "ghcr.io/heliograph-io/heliograph-toolkit:0.4.3"
}

variable "startArgs" {
  description = "Arguments for start.sh, and after --, for station.sh. Defaults to [\"--\", \"--once\"]: a Job executes once per schedule tick and must exit."
  type        = list(string)
  default     = ["--", "--once"]
}

variable "cronExpression" {
  description = "Cron expression (UTC, standard 5-field) for how often a fresh execution starts."
  type        = string
  default     = "*/15 * * * *"
}

variable "replicaTimeoutSeconds" {
  description = "Seconds before an execution is killed for running too long."
  type        = number
  default     = 1800
}

variable "cpu" {
  type    = number
  default = 1.0
}

variable "memory" {
  type    = string
  default = "2Gi"
}

data "azurerm_container_app_environment" "this" {
  name                = var.containerAppsEnvironmentName
  resource_group_name = var.resource_group_name
}

# A Container Apps secret name must be lowercase alphanumeric and dashes, so
# RELAY_TOKEN becomes relay-token. That mapping is not injective and not always
# valid, and both failures are worth refusing rather than deploying:
#
#   TOKEN and token   -> the same secret, one silently winning
#   _TOKEN            -> "-token", which Azure rejects
#   GIT_TOKEN         -> "git-token", colliding with the built-in one
#
# Checked here rather than left to the platform, because a deployment that fails
# halfway has already created a resource group's worth of things.
locals {
  extra_secret_names = [for k in nonsensitive(keys(var.extraSecureEnv)) : lower(replace(k, "_", "-"))]
}

resource "azurerm_container_app_job" "this" {
  lifecycle {
    precondition {
      # A DEPLOYMENT THAT VALIDATES AND THEN EXITS 2 IS THE WORST OF BOTH.
      # Making repoUrl optional for the non-git transports also made it optional
      # for git, where it is the one thing the entrypoint cannot do without.
      condition     = var.transport != "git" || var.repoUrl != ""
      error_message = "transport is git, so repoUrl is required: that is the repository the station clones. For any other transport leave it empty - the image carries the payload."
    }
    precondition {
      condition     = length(local.extra_secret_names) == length(distinct(local.extra_secret_names))
      error_message = "Two extraSecureEnv keys map to the same Container Apps secret name. Names are lowercased and underscores become dashes, so TOKEN and token collide. Rename one."
    }
    precondition {
      condition     = alltrue([for n in local.extra_secret_names : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", n))])
      error_message = "An extraSecureEnv key does not produce a valid Container Apps secret name. Lowercased with underscores as dashes, it must be alphanumeric and dashes and must not start or end with a dash - so no leading or trailing underscore."
    }
    precondition {
      condition     = !contains(local.extra_secret_names, "git-token")
      error_message = "extraSecureEnv sets GIT_TOKEN, which collides with the built-in git-token secret. Use the gitToken variable instead."
    }
  }

  name                         = var.name
  location                     = var.location
  resource_group_name          = var.resource_group_name
  container_app_environment_id = data.azurerm_container_app_environment.this.id

  replica_timeout_in_seconds = var.replicaTimeoutSeconds
  # 0, not the platform default: see main.bicep's matching comment - a
  # retry from a fresh container could re-poll and re-run the same request.
  replica_retry_limit = 0

  schedule_trigger_config {
    cron_expression          = var.cronExpression
    parallelism              = 1
    replica_completion_count = 1
  }

  dynamic "secret" {
    for_each = nonsensitive(var.gitToken) == "" ? [] : [1]
    content {
      name  = "git-token"
      value = var.gitToken
    }
  }

  # One secret per secureEnv entry. A Container Apps secret name must be
  # lowercase alphanumeric and dashes, so RELAY_TOKEN becomes relay-token and
  # the env reference below derives the same name - which is why the derivation
  # is a plain expression rather than anything the caller supplies.
  dynamic "secret" {
    for_each = toset(nonsensitive(keys(var.extraSecureEnv)))
    content {
      name  = lower(replace(secret.value, "_", "-"))
      value = var.extraSecureEnv[secret.value]
    }
  }

  template {
    container {
      name   = "agent"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      # NO `command` set: unlike ACI's azurerm_container_group, which has
      # only `commands` (replacing the image's ENTRYPOINT outright),
      # azurerm_container_app_job's container block has separate `command`
      # and `args`, closer to Kubernetes. Leaving `command` unset keeps the
      # image's own ENTRYPOINT (entrypoint.sh) in force, and `args` below
      # becomes its argv.
      #
      # THE URL TRAVELS IN args, NOT AS A REPO_URL ENVIRONMENT VARIABLE.
      # The published image's entrypoint.sh refuses outright whenever
      # REPO_URL is set AND any positional argument is also given, and a
      # Job's whole point is passing --once - so REPO_URL and an argument
      # are unavoidable together here. Passing the URL positionally instead
      # avoids that refusal entirely and needs no new image tag. See
      # https://docs.heliograph.io/azure.
      # FOR GIT ONLY. A non-git station has nothing to clone, and the
      # entrypoint refuses a repository URL - positional or REPO_URL - beside a
      # non-git TRANSPORT rather than ignoring it. So the URL is simply not
      # passed, and TRANSPORT goes in the environment like every other host.
      args = concat(var.transport == "git" ? [var.repoUrl] : [], var.startArgs)

      dynamic "env" {
        for_each = var.transport == "git" ? [] : [1]
        content {
          name  = "TRANSPORT"
          value = var.transport
        }
      }

      dynamic "env" {
        for_each = var.extraEnv
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.gitTokenUser == "" ? [] : [1]
        content {
          name  = "GIT_TOKEN_USER"
          value = var.gitTokenUser
        }
      }

      # `nonsensitive`, because a SENSITIVE VALUE CANNOT DRIVE for_each.
      #
      # Terraform refuses it - "Cannot use a string value in for_each" - since a
      # for_each key ends up in a resource address, which is not a place a
      # secret may go. `var.gitToken` is sensitive, so the comparison and the
      # conditional built on it are sensitive too, and this whole block has
      # therefore never validated under the terraform CI pins. Nothing noticed,
      # because nothing had ever run `terraform validate` over these templates.
      #
      # Only the EMPTINESS is unwrapped here. The value itself still goes
      # through the secret above and is never interpolated into anything.
      dynamic "env" {
        for_each = nonsensitive(var.gitToken) == "" ? [] : [1]
        content {
          name        = "GIT_TOKEN"
          secret_name = "git-token"
        }
      }

      # A secret per entry, referenced by name, exactly as gitToken is. The
      # secret NAME has to be a valid Container Apps secret name - lowercase
      # alphanumeric and dashes - so it is derived from the variable name rather
      # than being it.
      # OVER THE KEYS, not the map: a sensitive map cannot drive for_each, and
      # the NAMES are not the secret - the values are. So the names are
      # unwrapped and iterated, and each value is fetched inside the block,
      # where it stays sensitive and goes to the secret field.
      dynamic "env" {
        for_each = toset(nonsensitive(keys(var.extraSecureEnv)))
        content {
          name        = env.value
          secret_name = lower(replace(env.value, "_", "-"))
        }
      }
    }
  }
}

output "job_name" {
  value = azurerm_container_app_job.this.name
}

output "trigger_command" {
  value = "az containerapp job start -g ${var.resource_group_name} -n ${azurerm_container_app_job.this.name}"
}

output "logs_query" {
  value = "az containerapp job logs show -g ${var.resource_group_name} -n ${azurerm_container_app_job.this.name} --container agent --follow"
}
