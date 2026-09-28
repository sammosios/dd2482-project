ui = true

# Raft is OpenBao's recommended storage even for one node, and mlock is
# recommended off with it (it also spares us the IPC_LOCK capability).
disable_mlock = true

# Single node: nothing else ever dials these, but Raft requires them.
api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-1"
}

# Plain HTTP: reached over the Swarm overlay by Dokploy, and over the
# routing mesh from the host. See DESIGN.md "Secrets: OpenBao".
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Auto-unseal from a 32-byte key handed in as a Swarm secret, so a restarted
# task unseals itself. The key id must stay paired with the key for the
# life of the data; rotating means adding previous_key/previous_key_id.
seal "static" {
  current_key_id = "${OPENBAO_UNSEAL_KEY_ID}"
  current_key    = "file:///run/secrets/openbao_unseal_key"
}
