# TFTP/PXE boot — OPNsense serves iPXE files, matchbox on navi serves boot scripts
#
# PXE chain: DHCP → TFTP (ipxe.efi from OPNsense) → HTTP (matchbox on navi)
# iPXE files uploaded via bootstrap-navi.sh

resource "restapi_object" "tftp" {
  path           = "/api/tftp/general/set"
  read_path      = "/api/tftp/general/get"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data = jsonencode({
    general = {
      enabled = "1"
      listen  = local.zones.servers.gateway
    }
  })
  id_attribute = "result"
  object_id    = "tftp-general"
}

resource "restapi_object" "tftp_reconfigure" {
  path           = "/api/tftp/service/reconfigure"
  create_method  = "POST"
  read_method    = "GET"
  update_method  = "POST"
  destroy_method = "POST"
  data           = jsonencode({})
  id_attribute   = "status"
  object_id      = "tftp-reconfigure"

  depends_on = [restapi_object.tftp]
}
