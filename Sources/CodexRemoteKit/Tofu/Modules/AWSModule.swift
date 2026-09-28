import Foundation

public extension TofuModule {
    /// Amazon EC2 through the `hashicorp/aws` provider.
    ///
    /// A stock EC2 default security group has no inbound rules, so nothing could SSH in.
    /// The module creates a `codex-remote-ssh` group in the account's default VPC — once, and
    /// reused by every later machine, because destroying a machine must not take the group
    /// out from under the others.
    static let awsEC2 = TofuModule(
        kind: .aws,
        displayName: "Amazon EC2",
        blurb: "EC2 instances in your default VPC. Needs an IAM access key with EC2 permissions.",
        providerSource: "hashicorp/aws",
        providerVersion: "~> 5.60",
        providerBody: """
        region = var.region
        """,
        credentialFields: [
            CredentialField(key: "accessKeyID", label: "Access key ID",
                            help: "IAM user or role access key, e.g. AKIA…",
                            style: .secret, environmentVariable: "AWS_ACCESS_KEY_ID"),
            CredentialField(key: "secretAccessKey", label: "Secret access key",
                            help: "The matching secret.",
                            style: .secret, environmentVariable: "AWS_SECRET_ACCESS_KEY"),
            CredentialField(key: "sessionToken", label: "Session token",
                            help: "Only for temporary STS credentials. Leave blank for a long-lived IAM key.",
                            style: .secret, environmentVariable: "AWS_SESSION_TOKEN", isOptional: true),
            CredentialField(key: "region", label: "Default region",
                            help: "e.g. eu-central-1. Machines are created here unless you pick another region.",
                            style: .plain, environmentVariable: "AWS_REGION"),
        ],
        tokenHelpURL: "https://console.aws.amazon.com/iam/home#/security_credentials",
        machineBody: """
        data "aws_vpc" "default" {
          default = true
        }

        data "aws_ami" "image" {
          count       = var.image == "" ? 1 : 0
          most_recent = true
          owners      = ["099720109477"] # Canonical
          filter {
            name   = "name"
            values = ["ubuntu/images/hvm-ssd*/ubuntu-*-26.04-amd64-server-*"]
          }
        }

        resource "aws_key_pair" "machine" {
          key_name   = "codex-remote-${var.name}"
          public_key = trimspace(var.ssh_public_key)
          tags       = var.tags
        }

        # Shared across machines, hence the fixed name and the lifecycle guard.
        resource "aws_security_group" "ssh" {
          name        = "codex-remote-ssh"
          # ASCII only: EC2 rejects a GroupDescription with anything outside it.
          description = "Codex Remote - inbound SSH for managed Codex machines"
          vpc_id      = data.aws_vpc.default.id

          ingress {
            description = "SSH"
            from_port   = 22
            to_port     = 22
            protocol    = "tcp"
            cidr_blocks = ["0.0.0.0/0"]
          }

          egress {
            from_port        = 0
            to_port          = 0
            protocol         = "-1"
            cidr_blocks      = ["0.0.0.0/0"]
            ipv6_cidr_blocks = ["::/0"]
          }

          lifecycle {
            create_before_destroy = true
          }
        }

        resource "aws_instance" "machine" {
          ami                    = var.image == "" ? data.aws_ami.image[0].id : var.image
          instance_type          = var.size
          key_name               = aws_key_pair.machine.key_name
          vpc_security_group_ids = [aws_security_group.ssh.id]
          user_data              = var.user_data

          root_block_device {
            volume_size = 40
            volume_type = "gp3"
          }

          tags = merge(var.tags, { Name = var.name })

          lifecycle {
            ignore_changes = [ami, user_data]
          }
        }

        output "instance_id"   { value = aws_instance.machine.id }
        output "instance_name" { value = var.name }
        output "public_ipv4"   { value = aws_instance.machine.public_ip }
        output "public_ipv6"   { value = "" }
        output "private_ipv4"  { value = aws_instance.machine.private_ip }
        output "state"         { value = aws_instance.machine.instance_state }
        output "region"        { value = var.region }
        output "size"          { value = aws_instance.machine.instance_type }
        output "image"         { value = aws_instance.machine.ami }
        """,
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "eu-central-1", name: "Frankfurt"),
                          Region(slug: "eu-west-1", name: "Ireland"),
                          Region(slug: "us-east-1", name: "N. Virginia"),
                          Region(slug: "us-west-2", name: "Oregon")],
                sizes: AWSProvider.curatedSizes,
                images: [OSImage(slug: "", name: "Ubuntu 26.04 (latest Canonical AMI)", family: "ubuntu")],
                recommendedImage: "", recommendedSize: "t3.medium", recommendedRegion: "eu-central-1")
        },
        environment: { fields, secrets in
            var environment: [String: String] = [:]
            if let key = secrets["accessKeyID"] { environment["AWS_ACCESS_KEY_ID"] = key.raw }
            if let key = secrets["secretAccessKey"] { environment["AWS_SECRET_ACCESS_KEY"] = key.raw }
            if let token = secrets["sessionToken"], !token.isEmpty { environment["AWS_SESSION_TOKEN"] = token.raw }
            if let region = fields["region"], !region.isEmpty { environment["AWS_REGION"] = region }
            return environment
        },
        // Canonical's Ubuntu images log in as `ubuntu`, not root.
        sshUser: "ubuntu",
        managesSSHKey: true
    )
}
