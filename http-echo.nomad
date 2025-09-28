job "http-echo" {
  datacenters = ["dc1"]

  group "echo" {
    count = 1

    task "server" {
      driver = "docker"

      config {
        image = "hashicorp/http-echo:0.2.3"
        args = [
          "-listen", ":8080",
          "-text", "Hello from Nomad Cluster!"
        ]
        port_map {
          http = 8080
        }
      }

      resources {
        network {
          mbits = 10
          port "http" {
            static = 8080
          }
        }
      }
    }
  }
}
