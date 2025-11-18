packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for AMI building"
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC ID for builder instance (optional)"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for builder instance (optional)"
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for building"
}

variable "os_distribution" {
  type        = string
  default     = "ubuntu"
  description = "Operating system distribution"

  validation {
    condition     = contains(["ubuntu", "debian"], var.os_distribution)
    error_message = "OS distribution must be ubuntu or debian."
  }
}

variable "os_version" {
  type        = string
  default     = "22.04"
  description = "Operating system version (e.g., 22.04, 24.04, 20.04)"
}

variable "os_codename" {
  type        = string
  default     = "jammy"
  description = "Operating system codename (e.g., jammy, focal, noble)"
}

variable "os_arch" {
  type        = string
  default     = "amd64"
  description = "Operating system architecture"

  validation {
    condition     = contains(["amd64", "arm64"], var.os_arch)
    error_message = "Architecture must be amd64 or arm64."
  }
}

variable "source_ami_owner" {
  type        = string
  default     = "099720109477"
  description = "AMI owner ID (099720109477 for Canonical/Ubuntu)"
}

variable "ami_name_prefix" {
  type        = string
  default     = "golden"
  description = "Prefix for AMI name"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment tag (dev, staging, prod)"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "image_version" {
  type        = string
  default     = "1.0.0"
  description = "Image version number (semantic versioning)"
}

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "SSH username for provisioning"
}

variable "encrypt_boot" {
  type        = bool
  default     = true
  description = "Encrypt AMI boot volume"
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "KMS key ID for AMI encryption (optional)"
}

variable "volume_size" {
  type        = number
  default     = 30
  description = "Root volume size in GB"
}

locals {
  timestamp         = regex_replace(timestamp(), "[- TZ:]", "")
  os_version_clean  = replace(var.os_version, ".", "")
  ami_name          = "${var.ami_name_prefix}-${var.os_distribution}${local.os_version_clean}-${var.environment}-${var.image_version}-${local.timestamp}"

  ami_name_filter = var.os_distribution == "ubuntu" ? "ubuntu/images/hvm-ssd/ubuntu-${var.os_codename}-${var.os_version}-${var.os_arch}-server-*" : "debian-${var.os_version}-${var.os_arch}-*"

  common_tags = {
    Name           = local.ami_name
    Environment    = var.environment
    Version        = var.image_version
    BuildDate      = local.timestamp
    OS             = "${var.os_distribution} ${var.os_version}"
    OSCodename     = var.os_codename
    OSArchitecture = var.os_arch
    ManagedBy      = "Packer"
    ImageType      = "GoldenImage"
    ZeroIdentity   = "true"
  }
}

data "amazon-ami" "base_image" {
  filters = {
    virtualization-type = "hvm"
    name                = local.ami_name_filter
    root-device-type    = "ebs"
    architecture        = var.os_arch == "amd64" ? "x86_64" : "arm64"
  }
  owners      = [var.source_ami_owner]
  most_recent = true
  region      = var.aws_region
}

source "amazon-ebs" "golden_image" {
  region     = var.aws_region
  vpc_id     = var.vpc_id
  subnet_id  = var.subnet_id

  source_ami    = data.amazon-ami.base_image.id
  instance_type = var.instance_type

  ssh_username = var.ssh_username
  ssh_timeout  = "20m"

  ami_name        = local.ami_name
  ami_description = "${var.os_distribution} ${var.os_version} Golden Image - Zero Identity - Version ${var.image_version}"

  encrypt_boot = var.encrypt_boot
  kms_key_id   = var.kms_key_id

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = var.encrypt_boot
    kms_key_id            = var.kms_key_id
  }

  ami_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
  }

  tags = merge(
    local.common_tags,
    {
      SourceAMI = data.amazon-ami.base_image.id
    }
  )

  snapshot_tags = merge(
    local.common_tags,
    {
      Type = "AMI Snapshot"
    }
  )

  run_tags = {
    Name        = "packer-builder-${local.ami_name}"
    Environment = var.environment
    Purpose     = "AMI Building"
  }

  temporary_security_group_source_public_ip = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
}

build {
  name    = "golden-image-builder"
  sources = ["source.amazon-ebs.golden_image"]

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'Cloud-init complete. System ready for provisioning.'"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo 'Updating system packages...'",
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y python3 python3-pip ansible"
    ]
  }

  provisioner "ansible" {
    playbook_file = "../ansible/playbook.yml"

    extra_arguments = [
      "--extra-vars",
      "IMAGE_VERSION=${var.image_version} os_distribution=${var.os_distribution} os_version=${var.os_version} os_codename=${var.os_codename}",
      "--tags",
      "all"
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_FORCE_COLOR=1",
      "ANSIBLE_STDOUT_CALLBACK=yaml"
    ]

    user = var.ssh_username
  }

  provisioner "shell" {
    inline = [
      "echo 'Validating image build...'",
      "docker --version",
      "kubectl version --client",
      "helm version",
      "fluent-bit --version",
      "vault version",
      "echo 'Validation complete.'",
      "cat /etc/golden-image-manifest.txt"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo 'Performing final sync...'",
      "sudo sync",
      "echo 'Image preparation complete.'"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      ami_name        = local.ami_name
      environment     = var.environment
      version         = var.image_version
      build_time      = local.timestamp
      source_ami      = data.amazon-ami.base_image.id
      os_distribution = var.os_distribution
      os_version      = var.os_version
      os_codename     = var.os_codename
      os_architecture = var.os_arch
      zero_identity   = "true"
    }
  }
}
