locals {
  cluster_name = "test"
  cidr = "172.16.0.0/16"
  private_subnets = ["172.16.1.0/24", "172.16.2.0/24"]
  public_subnets = ["172.16.3.0/24", "172.16.4.0/24"]

  k8s = {
    app = {
      nginx = {
        namespace = "default"
        name = "nginx"
        port = "80"
      }
    }
  }
}