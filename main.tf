terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.47.0"
    }
  }
}

provider "yandex" {
  token     = local.token
  cloud_id  = local.cloud_id
  folder_id = local.folder_id
  zone      = local.zone_subnet
}

resource "yandex_vpc_subnet" "lab-subnet-a" {
  name           = local.subnet_name
  v4_cidr_blocks = [local.CIDR_ipv4]
  zone           = local.zone_subnet
  network_id     = local.network_id
}

resource "yandex_vpc_security_group" "default_sg" {
  name        = "default_sg"
  description = "Default security group"
  network_id  = local.network_id
}

resource "yandex_vpc_security_group_rule" "rule1" {
  security_group_binding = yandex_vpc_security_group.default_sg.id
  security_group_id = yandex_vpc_security_group.default_sg.id
  direction         = "ingress"
  description       = "mysql"
  port              = 3306
  protocol          = "TCP"
}

resource "yandex_vpc_security_group_rule" "rule2" {
  security_group_binding = yandex_vpc_security_group.default_sg.id
  security_group_id = yandex_vpc_security_group.default_sg.id
  direction         = "egress"
  description       = "mysql"
  port              = 3306
  protocol          = "TCP"
}

resource "yandex_vpc_security_group_rule" "rule3" {
  security_group_binding = yandex_vpc_security_group.default_sg.id
  v4_cidr_blocks    = ["0.0.0.0/0"]
  direction         = "ingress"
  description       = "vpn"
  from_port         = 0
  to_port           = 65535
  protocol          = "ANY"
}

resource "yandex_vpc_security_group_rule" "rule4" {
  security_group_binding = yandex_vpc_security_group.default_sg.id
  v4_cidr_blocks    = ["0.0.0.0/0"]
  direction         = "egress"
  description       = "vpn"
  from_port         = 0
  to_port           = 65535
  protocol          = "ANY"
}

resource "yandex_compute_instance" "vpn-server" {
  name        = "vpn-server"
  platform_id = "standard-v3"
  zone        = local.zone_subnet

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = local.image_vpn_server_id
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.lab-subnet-a.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.default_sg.id]
    nat_ip_address     = local.static_ip_vpn_server
  }

  metadata = {
    user-data = <<-EOF
      #cloud-config
      users:
        - name: ${local.username}
          groups: sudo
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          ssh-authorized-keys:
            - ${file(local.ssh_key_path)}
      EOF
  }
}

resource "yandex_compute_instance" "host-vm" {
  name        = "host-vm"
  platform_id = "standard-v3"
  zone        = local.zone_subnet

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = local.image_host_vm_id
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.lab-subnet-a.id
    security_group_ids = [yandex_vpc_security_group.default_sg.id]
  }

  metadata = {
    user-data = <<-EOF
      #cloud-config
      users:
        - name: ${local.username}
          groups: sudo
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          ssh-authorized-keys:
            - ${file(local.ssh_key_path)}
      EOF
  }
}

resource "yandex_mdb_mysql_cluster" "mysql1" {
  name                = "mysql1"
  environment         = "PRODUCTION"
  network_id          = local.network_id
  version             = "8.0"
  security_group_ids  = [ yandex_vpc_security_group.default_sg.id ]

  resources {
    resource_preset_id = "s2.micro"
    disk_type_id       = "network-hdd"
    disk_size          = "10"
  }

  host {
    zone             = local.zone_subnet
    subnet_id        = yandex_vpc_subnet.lab-subnet-a.id
    assign_public_ip = false
    priority         = 0
    backup_priority  = 0
  }
  access {
    web_sql = true
  }
}

resource "yandex_mdb_mysql_database" "mysql_database" {
  cluster_id = yandex_mdb_mysql_cluster.mysql1.id
  name       = "crmbase"
}

resource "yandex_mdb_mysql_user" "mysql_user" {
  cluster_id = yandex_mdb_mysql_cluster.mysql1.id
  name       = "user1"
  password   = local.mysql_password
  permission {
    database_name = yandex_mdb_mysql_database.mysql_database.name
    roles         = ["ALL"]
  }
}

resource "yandex_datatransfer_endpoint" "new-cluster" {
  name = "new-cluster"
  settings {
    mysql_target {
      connection {
        mdb_cluster_id = yandex_mdb_mysql_cluster.mysql1.id
      }
      database = "crmbase"
      user = "user1"
      password {
        raw = local.mysql_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "transfer-to-new-database" {
  folder_id   = local.folder_id
  name        = "transfer-to-new-database"
  description = "mysql-to-mysql"
  source_id   = "dtee0686sa2j6dj5l00m"
  target_id   = yandex_datatransfer_endpoint.new-cluster.id
  type        = "SNAPSHOT_AND_INCREMENT"
}

resource "yandex_function" "function" {
  name               = "check-site-availability"
  user_hash          = "function"
  runtime            = "python312"
  entrypoint         = "index.entry"
  memory             = "512"
  execution_timeout  = "10"
  service_account_id = local.sa_id
  environment = {
    DB_USER = "user1"
    VERBOSE_LOG = "False"
    DB_NAME = "crmbase"
    CRM_SERVER_URL = "http://${yandex_compute_instance.host-vm.network_interface[0].ip_address}/index.php"
    DB_HOST = yandex_mdb_mysql_cluster.mysql1.host[0].fqdn
    DB_PASSWORD = local.mysql_password
  }
  package {
    bucket_name = "crmbase-storage"
    object_name = "check-crm-availability.zip"
    sha_256 = null
  }
  connectivity {
    network_id = local.network_id
  }
}

resource "yandex_function_iam_binding" "function-iam" {
  function_id = yandex_function.function.id
  role        = "serverless.functions.invoker"
  members = [
    "system:allUsers",
  ]
}