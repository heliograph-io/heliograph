# =============================================================================
#  webapp/main.tf - run the heliograph agent as a Web App for Containers
# =============================================================================
#  The Terraform twin of webapp/main.bicep. Same shape, same traps, same
#  result - see that file's header for the full reasoning. This creates one
#  azurerm_linux_web_app and nothing else: the VNet, subnet and App Service
#  Plan already exist in the estate.
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
  description = "Name for the web app (must be globally unique - becomes <name>.azurewebsites.net)."
  type        = string
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
  description = "Existing VNet this app integrates with."
  type        = string
}

variable "subnetName" {
  description = "Existing subnet, delegated to Microsoft.Web/serverFarms."
  type        = string
}

variable "planName" {
  description = "Existing Linux App Service Plan, Basic tier or above (Free/Shared do not support VNet integration or Always On)."
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
  description = "Arguments for start.sh, and after --, for station.sh. The repo URL is NOT one of these: it travels as REPO_URL. Space-joined into the Startup Command."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Accepted for parameter parity with the other hosts in this PR, but NOT actionable here: sizing comes entirely from the App Service Plan's SKU (planName above)."
  type        = number
  default     = 1
}

variable "memory" {
  description = "See cpu above: not actionable for this host, kept only for parameter parity."
  type        = number
  default     = 1
}

data "azurerm_service_plan" "this" {
  name                = var.planName
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "this" {
  name                 = var.subnetName
  virtual_network_name = var.vnetName
  resource_group_name  = var.resource_group_name
}

resource "azurerm_linux_web_app" "this" {
  lifecycle {
    precondition {
      # A DEPLOYMENT THAT VALIDATES AND THEN EXITS 2 IS THE WORST OF BOTH. Making
      # repoUrl optional for the non-git transports also made it optional for
      # git, where it is the one thing the entrypoint cannot do without: the
      # container came up, printed "no repository URL given", and stopped -
      # after terraform reported success.
      condition     = var.transport != "git" || var.repoUrl != ""
      error_message = "transport is git, so repoUrl is required: that is the repository the station clones. For any other transport leave it empty - the image carries the payload."
    }
  }


  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = data.azurerm_service_plan.this.id

  virtual_network_subnet_id = data.azurerm_subnet.this.id

  site_config {
    # Regional VNet Integration is outbound-only by default: it routes only
    # traffic bound for addresses inside the VNet through the integration.
    # Everything else - including the git host - would otherwise take the
    # platform's own public egress, defeating the point of handing this
    # template a subnet at all. vnet_route_all_enabled sends everything
    # through it instead, matching the bicep version's vnetRouteAllEnabled.
    vnet_route_all_enabled = true
    # Keeps the container running with no inbound HTTP traffic. Web Apps
    # idle out and unload the container after ~20 minutes without a request
    # when this is off - fatal for a loop whose whole job is to sit there
    # polling git with nothing to serve. Needs Basic tier or above.
    always_on = true

    application_stack {
      # The FULL reference, registry host included (var.image is already
      # "ghcr.io/dbhq-uk/..."). docker_registry_url is deliberately NOT set
      # alongside it: that field is for a registry that needs credentials
      # attached separately (ACR, a private Docker Hub repo), and setting it
      # here as well double-prefixes what azurerm builds - linuxFxVersion
      # came out as "DOCKER|ghcr.io/ghcr.io/dbhq-uk/...", a registry ghcr.io
      # does not have, and the app never started. Found by deploying this
      # exact shape - see https://docs.heliograph.io/azure. For a public registry the
      # image name alone is enough.
      docker_image_name = var.image
    }

    # The image's ENTRYPOINT is never touched here - App Service's Startup
    # Command is appended as arguments to whatever the image already
    # declares, unlike ACI's `command`/`commands`, which replaces the
    # ENTRYPOINT outright. An empty startArgs leaves this empty and the
    # image's own ENTRYPOINT runs with no arguments - see main.bicep's
    # matching comment, confirmed by hand and recorded in
    # https://docs.heliograph.io/azure.
    app_command_line = join(" ", var.startArgs)
  }

  app_settings = merge(
    var.transport == "git" ? { REPO_URL = var.repoUrl } : { TRANSPORT = var.transport },
    {
      # Turns off the persistent Azure Files /home mount every Linux
      # container Web App gets by default, so the checkout stays exactly as
      # transient as it is on every other host in this PR: git is the
      # persistence, not the platform.
      WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    },
    var.gitTokenUser == "" ? {} : { GIT_TOKEN_USER = var.gitTokenUser },
    # App settings have no separate "secure" field the way ACI's
    # secure_environment_variables does - this still keeps the token out of
    # the .tf files and out of a plan's diff-free re-apply, but anyone who
    # can read this app's own configuration
    # (`az webapp config appsettings list`) can read it back in plain text.
    # Same caveat as every other host's environment-variable credential.
    var.gitToken == "" ? {} : { GIT_TOKEN = var.gitToken },
    var.extraEnv,
    # App settings have no separate secure field, so secureEnv lands here too -
    # the same caveat as gitToken above, stated once and applying to both.
    var.extraSecureEnv,
  )
}

output "site_name" {
  value = azurerm_linux_web_app.this.name
}

output "logs_command" {
  value = "az webapp log tail -g ${var.resource_group_name} -n ${azurerm_linux_web_app.this.name}"
}
