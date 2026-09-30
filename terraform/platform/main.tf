# The cluster's own services, each a Dokploy compose resource of type stack
# (a Swarm stack) in the "infrastructure" project. The compose files are
# built here with yamlencode, so there's no templating: values go straight
# in. Swarm's own interpolation still applies, so a literal $ is $$.
resource "dokploy_project" "infrastructure" {
  name        = "infrastructure"
  description = "Cluster infrastructure services"
}

locals {
  env_id = dokploy_project.infrastructure.production_environment_id

  # Services with a node-local volume: pinned to the manager (the control
  # plane), so a task never lands on an empty volume elsewhere, and the one
  # node that's never scaled away.
  on_manager = {
    replicas = 1
    placement = {
      constraints = ["node.role == manager"]
    }
    restart_policy = {
      condition = "any"
    }
  }
}

# --- Registry -----------------------------------------------------------------
# Published on Swarm's routing mesh, so every node reaches it on its own
# 127.0.0.1:5000: plain HTTP on loopback, no TLS or insecure-registries setup
# per node. Always 127.0.0.1, never localhost (moby/moby#53091). The port is
# open on every node's address (closed to the internet by GCP's firewall and
# the port guard), so it takes a password.

resource "random_password" "registry" {
  length  = 32
  special = false
}

locals {
  registry_addr = "127.0.0.1:5000"
  registry_user = "dokploy"
  # The htpasswd file, base64 so no $ of the bcrypt hash meets Swarm's
  # interpolation. bcrypt_hash is stable: random_password computes it once.
  registry_htpasswd = base64encode("${local.registry_user}:${random_password.registry.bcrypt_hash}\n")
}

resource "dokploy_compose" "registry" {
  name           = "registry"
  description    = "Container registry every node pulls from, at 127.0.0.1:5000"
  environment_id = local.env_id
  compose_type   = "stack"

  raw = {
    compose_file = yamlencode({
      services = {
        registry = {
          image = "registry:3"
          # Writes the htpasswd file, then starts the image's own entrypoint.
          entrypoint = ["/bin/sh", "-c", "mkdir -p /auth && echo \"$$HTPASSWD_B64\" | base64 -d >/auth/htpasswd && exec /entrypoint.sh /etc/distribution/config.yml"]
          environment = {
            HTPASSWD_B64                 = local.registry_htpasswd
            REGISTRY_AUTH                = "htpasswd"
            REGISTRY_AUTH_HTPASSWD_REALM = "Registry"
            REGISTRY_AUTH_HTPASSWD_PATH  = "/auth/htpasswd"
            # Lets image deletes through the API, so 'registry
            # garbage-collect' can actually free disk.
            REGISTRY_STORAGE_DELETE_ENABLED = "true"
          }
          ports = [{
            target    = 5000
            published = 5000
            protocol  = "tcp"
            mode      = "ingress"
          }]
          volumes = ["registry-data:/var/lib/registry"]
          deploy  = local.on_manager
        }
      }
      volumes = { registry-data = {} }
    })
  }
}

# Dokploy's registry.create runs `docker login` against the registry at once,
# but a stack deploy counts as done as soon as Swarm has accepted it, before
# the container is up: without a pause, the login finds nothing on port 5000.
# The port is closed to the machine running Terraform, so there's nothing to
# poll from here. Waits again whenever the stack changes (and restarts).
resource "time_sleep" "registry_up" {
  create_duration = "60s"
  triggers = {
    compose = sha256(dokploy_compose.registry.raw.compose_file)
  }
}

# Dokploy logs in with this to pull the apps' images, and hands it to Swarm
# so every worker can pull them too.
resource "dokploy_registry" "cluster" {
  name     = "cluster-registry"
  url      = local.registry_addr
  username = local.registry_user
  password = random_password.registry.result

  depends_on = [time_sleep.registry_up]
}

# --- OpenBao ------------------------------------------------------------------
# The cluster's secrets manager: the apps' secrets and the CI runners' GitHub
# token, fetched by Dokploy at deploy time (${{vault.<provider>.<ref>}}).
# Single node, Raft storage, pinned to the manager.
#
# It initializes itself on its first start (OpenBao's "initialize" config),
# so it's never reachable uninitialized: with auto-unseal, no root token is
# handed out, and the one step it takes is to create the user terraform/
# services logs in as, with the password from Secret Manager (a Swarm
# secret the control plane created). Everything after that is Terraform's.

locals {
  openbao_config = {
    ui            = true
    disable_mlock = true
    # Single node: nothing else ever dials these, but Raft requires them.
    api_addr     = "http://127.0.0.1:8200"
    cluster_addr = "http://127.0.0.1:8201"
    storage = {
      raft = {
        path    = "/openbao/file"
        node_id = "openbao-1"
      }
    }
    # Plain HTTP inside the overlay network; Traefik terminates TLS for
    # bao.<domain>.
    listener = {
      tcp = {
        address     = "0.0.0.0:8200"
        tls_disable = true
      }
    }
    # Auto-unseal from a 32-byte key the control plane made and keeps as a
    # Swarm secret, so a restarted task unseals itself. The key id must stay
    # paired with the key for the life of the data.
    seal = {
      static = {
        current_key_id = "cluster-1"
        current_key    = "file:///run/secrets/openbao_unseal_key"
      }
    }
    initialize = [{
      terraform = {
        request = [
          {
            policy = {
              operation = "update"
              path      = "sys/policies/acl/terraform"
              data = {
                policy = <<-EOT
                  path "*" {
                    capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
                  }
                EOT
              }
            }
          },
          {
            enable-userpass = {
              operation = "update"
              path      = "sys/auth/userpass"
              data      = { type = "userpass" }
            }
          },
          {
            user = {
              operation = "update"
              path      = "auth/userpass/users/terraform"
              data = {
                password = {
                  eval_source = "file"
                  eval_type   = "string"
                  path        = "/run/secrets/openbao_terraform_password"
                }
                token_policies = ["terraform"]
                token_ttl      = "1h"
              }
            }
          },
        ]
      }
    }]
  }
}

# https://bao.<domain>, through Dokploy's Traefik. These are the labels a
# dokploy_domain would make Dokploy add, written into the stack instead:
# Dokploy adds a stack's domain labels only when it deploys the stack, and
# nothing redeploys it after the domain is created, so the route would be
# missing until someone redeployed OpenBao by hand. Written here, Traefik has
# it from the first deploy. Dokploy leaves labels it didn't generate alone;
# the cost is that the domain doesn't show in Dokploy's UI.
locals {
  openbao_host = "bao.${local.gcp.domain}"
  openbao_labels = [
    "traefik.enable=true",
    "traefik.swarm.network=dokploy-network",
    "traefik.http.services.openbao.loadbalancer.server.port=8200",
    "traefik.http.routers.openbao-web.rule=Host(`${local.openbao_host}`)",
    "traefik.http.routers.openbao-web.entrypoints=web",
    "traefik.http.routers.openbao-web.middlewares=redirect-to-https@file",
    "traefik.http.routers.openbao-web.service=openbao",
    "traefik.http.routers.openbao-websecure.rule=Host(`${local.openbao_host}`)",
    "traefik.http.routers.openbao-websecure.entrypoints=websecure",
    "traefik.http.routers.openbao-websecure.tls.certresolver=letsencrypt",
    "traefik.http.routers.openbao-websecure.service=openbao",
  ]
}

resource "dokploy_compose" "openbao" {
  name           = "openbao"
  description    = "Secrets manager for the apps and CI"
  environment_id = local.env_id
  compose_type   = "stack"

  raw = {
    compose_file = yamlencode({
      services = {
        openbao = {
          image = "openbao/openbao:2.7.0"
          # The image's entrypoint writes BAO_LOCAL_CONFIG to its config
          # directory, runs `bao server` on it and drops root.
          command     = "server"
          environment = { BAO_LOCAL_CONFIG = jsonencode(local.openbao_config) }
          networks = {
            # Dokploy's own server fetches secrets at deploy time as
            # http://openbao:8200, and Traefik reaches it here too.
            dokploy-network = { aliases = ["openbao"] }
          }
          volumes = ["openbao-data:/openbao/file"]
          secrets = [
            { source = "unseal_key", target = "openbao_unseal_key" },
            { source = "terraform_password", target = "openbao_terraform_password" },
          ]
          deploy = merge(local.on_manager, { labels = local.openbao_labels })
        }
      }
      networks = { dokploy-network = { external = true } }
      volumes  = { openbao-data = {} }
      # Created by the control plane's startup script (terraform/gcp).
      secrets = {
        unseal_key         = { external = true, name = "openbao-unseal-key" }
        terraform_password = { external = true, name = "openbao-terraform-password" }
      }
    })
  }
}

