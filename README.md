# Platform Image Builder - Golden Images

Automated build system for immutable, zero-identity AMIs using Packer and Ansible with CI/CD promotion pipeline. Supports multiple Ubuntu versions via variable configuration.

## Overview

Builds Ubuntu AMIs (22.04, 24.04, 20.04) with pre-installed enterprise software:
- Docker and containerd
- Kubernetes tools (kubectl, kubeadm, kubelet, Helm)
- Fluent Bit for log aggregation
- Prometheus Node Exporter for metrics
- HashiCorp Vault CLI for secrets management
- AppArmor, Fail2ban, Auditd for security
- SSSD/Realmd for Active Directory integration
- Certbot for HTTPS certificate management

All machine-specific identifiers are removed before AMI creation (zero-identity).

## Architecture

**Build Process:**
1. Packer provisions EC2 instance from base Ubuntu AMI
2. Ansible runs provisioning roles
3. Zero-identity cleanup removes all machine-specific data
4. AMI snapshot created

**Deployment Pipeline:**
- DEV: Automatic build on push to `develop` branch
- STAGING: Automatic promotion on push to `main` branch
- PRODUCTION: Manual workflow dispatch with approval gate

**Rollback:**
- GitHub Actions workflow or CLI script
- Automated launch template updates
- ASG instance refresh


## Prerequisites

- AWS Account with appropriate IAM permissions
- Packer >= 1.10.0
- Ansible >= 2.15.0
- AWS CLI configured
- GitHub Secrets configured

## Quick Start

Ubuntu 22.04 build:

```bash
cd packer
packer init golden-image.pkr.hcl
packer build \
  -var "os_version=22.04" \
  -var "os_codename=jammy" \
  -var "environment=dev" \
  golden-image.pkr.hcl
```

Ubuntu 24.04 build:

```bash
packer build \
  -var "os_version=24.04" \
  -var "os_codename=noble" \
  -var "environment=dev" \
  golden-image.pkr.hcl
```

Using environment variable files:

```bash
packer build -var-file="../config/environments/dev.auto.pkrvars.hcl" golden-image.pkr.hcl
```

Deploy and rollback:

```bash
./scripts/deploy-ami.sh dev
./scripts/rollback-ami.sh dev
```

Validate configuration:

```bash
./scripts/validate-ansible.sh
```

## Configuration

### Version Management

All software versions defined in: `ansible/roles/k8s_prereqs/vars/main.yml`

```yaml
docker_version: "5:24.0.7-1~ubuntu.22.04~jammy"
kubernetes_version: "1.28.4"
helm_version: "3.13.2"
node_exporter_version: "1.7.0"
vault_version: "1.15.4-1"
```

Update versions by editing this file.

### Packer Variables

- `os_version` - Ubuntu version (22.04, 24.04, 20.04)
- `os_codename` - Ubuntu codename (jammy, noble, focal)
- `environment` - Environment tag (dev, staging, production)
- `image_version` - Semantic version
- `aws_region` - AWS region
- `encrypt_boot` - EBS encryption

## CI/CD Pipeline

### Environments

**DEV:**
- Trigger: Push to `develop` branch
- Build: Automatic
- Test: Automated instance validation
- Approval: None

**STAGING:**
- Trigger: Push to `main` branch
- Build: Automatic after DEV tests pass
- Approval: None

**PRODUCTION:**
- Trigger: Manual workflow dispatch
- Build: Requires manual approval in GitHub UI
- Approval: Required

### GitHub Secrets

**DEV:**
- `AWS_ROLE_ARN_DEV`
- `VPC_ID_DEV`
- `SUBNET_ID_DEV`
- `SG_ID_DEV`
- `INSTANCE_PROFILE_DEV`

**STAGING:**
- `AWS_ROLE_ARN_STAGING`

**PRODUCTION:**
- `AWS_ROLE_ARN_PROD`
- `KMS_KEY_ID_PROD`

**Optional:**
- `SHARE_AMI_ACCOUNTS` - AWS account IDs for AMI sharing
- `SLACK_WEBHOOK_URL` - Notification webhook

### Build Triggers

DEV build:
```bash
git checkout develop
git commit -am "Update configuration"
git push origin develop
```

STAGING build:
```bash
git checkout main
git merge develop
git push origin main
```

PRODUCTION build:
1. Navigate to GitHub Actions tab
2. Select "Golden Image CI/CD Pipeline"
3. Click "Run workflow"
4. Select environment: `production`, version: `1.0.0`
5. Approve deployment in GitHub UI

## Zero-Identity Implementation

Removed items before AMI creation:
- SSH host keys
- Machine-ID
- Cloud-init instance data
- User command histories
- SSH authorized keys
- DHCP leases
- Log files
- Netplan configuration
- Temporary files
- Package cache

Verification after instance launch:
```bash
cat /etc/machine-id          # Should be unique
ls -la /etc/ssh/ssh_host_*   # Fresh keys
cat ~/.bash_history          # Empty
```

## Pre-Installed Components

**Base System:**
- Ubuntu (22.04, 24.04, 20.04)
- Kernel tuning (BBR, optimized TCP)
- Common utilities

**Container Runtime:**
- Docker with containerd
- Docker Compose

**Kubernetes:**
- kubectl, kubeadm, kubelet
- Helm 3

**Security:**
- HashiCorp Vault CLI
- AppArmor (enforcing)
- Fail2ban
- Auditd
- SSH hardening
- Automated security updates

**Observability:**
- Prometheus Node Exporter (port 9100)
- Fluent Bit

**Authentication:**
- SSSD/Realmd
- Kerberos
- Helper scripts: `/usr/local/bin/ad-join.sh`

**HTTPS:**
- Certbot

## Customization

### Adding New Software

1. **Create new Ansible role**:
   ```bash
   mkdir -p ansible/roles/my_app/tasks
   touch ansible/roles/my_app/tasks/main.yml
   ```

2. **Define tasks**:
   ```yaml
   ---
   - name: Install my application
     ansible.builtin.apt:
       name: my-app
       state: present
     become: yes
   ```

3. **Add to playbook**:
   ```yaml
   roles:
     - role: my_app
       tags: ['custom']
   ```

### Updating Versions

Edit **`ansible/roles/k8s_prereqs/vars/main.yml`**:

```yaml
# Update this single file
docker_version: "5:24.0.8-1~ubuntu.22.04~jammy"  # New version
kubernetes_version: "1.29.0"                       # New version
```

All roles automatically use updated versions.

### Environment-Specific Configuration

Use Packer variables:

```bash
packer build \
  -var "environment=prod" \
  -var "vpc_id=vpc-prod123" \
  -var "subnet_id=subnet-prod456" \
  ubuntu-2204.pkr.hcl
```

## Testing

### Automated Testing

The pipeline automatically:
1. Launches test instance from new AMI
2. Validates Docker installation
3. Validates Kubernetes tools
4. Verifies zero-identity state
5. Terminates test instance
6. Tags AMI with test results

### Manual Testing

```bash
# Launch instance from AMI
aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.micro \
  --key-name my-key \
  --subnet-id subnet-xxxxx

# SSH into instance
ssh ubuntu@<instance-ip>

# Verify installations
docker --version
kubectl version --client
helm version
fluent-bit --version
certbot --version

# Check zero-identity
cat /etc/machine-id
ls /etc/ssh/ssh_host_*
history
```

## Operational Flow

### Development Workflow

1. Push to `develop` triggers DEV build
2. Automated tests run
3. Merge to `main` triggers STAGING build
4. Manual workflow dispatch for PRODUCTION
5. Approval gate before deployment

### Version Strategy

- **DEV**: Auto-incremented `1.0.${BUILD_NUMBER}`
- **STAGING**: Promoted from DEV with same version
- **PRODUCTION**: Manual semantic versioning (e.g., `2.1.0`)

### Rollback Procedure

Using rollback script:

```bash
./scripts/rollback-ami.sh production
./scripts/rollback-ami.sh staging ami-specific-version
```

Or via GitHub Actions workflow dispatch.

## Security Best Practices

### Image Security
- All packages updated to latest versions
- No default passwords or credentials
- SSH keys regenerated per instance
- IMDSv2 enforced
- EBS volumes encrypted
- Security group restrictions applied

### Runtime Security
- Use instance profiles (IAM roles) instead of access keys
- Enable VPC Flow Logs
- Use Systems Manager Session Manager instead of SSH
- Enable CloudWatch Logs for audit trails
- Implement least-privilege IAM policies

### Compliance
- Zero-Identity: Meets NIST compliance for image reuse
- Encryption: Complies with encryption at rest requirements
- Audit: Full build history in GitHub Actions logs
- Traceability: Git commit SHA tagged on each AMI

## Monitoring and Observability

### Fluent Bit Configuration

Default inputs:
- **Systemd**: All system journal logs
- **Syslog**: `/var/log/syslog`
- **Auth**: `/var/log/auth.log`

Default output:
- **Stdout**: JSON lines (customize for production)

### Production Integration

Update `/etc/fluent-bit/fluent-bit.conf`:

```ini
[OUTPUT]
    Name        es
    Match       *
    Host        elasticsearch.example.com
    Port        9200
    Index       golden-image-logs
    Type        _doc
```

Or send to CloudWatch:

```ini
[OUTPUT]
    Name        cloudwatch_logs
    Match       *
    region      us-east-1
    log_group_name   /aws/ec2/golden-images
    log_stream_prefix from-fluent-bit-
    auto_create_group true
```

## Troubleshooting

### Common Issues

#### Packer Build Fails

```bash
# Enable debug logging
export PACKER_LOG=1
packer build ubuntu-2204.pkr.hcl
```

#### Ansible Playbook Errors

```bash
# Run with verbose output
ansible-playbook playbook.yml -vvv
```

#### AMI Won't Boot

Check cloud-init logs in EC2 console:
```bash
# In instance
sudo cat /var/log/cloud-init-output.log
```

#### SSH Keys Not Generated

Verify cloud-init is enabled:
```bash
sudo systemctl status cloud-init
```

### Support Contacts

- Infrastructure Team: infrastructure@example.com
- GitHub Issues: <repository-url>/issues
- Slack: #platform-engineering

## Maintenance

### Regular Updates

**Monthly**:
- Update base OS packages
- Review and update software versions in `vars/main.yml`
- Rebuild DEV image for testing

**Quarterly**:
- Update Kubernetes versions
- Review and update security configurations
- Audit AMI sharing permissions

**Annually**:
- Major version upgrades (if applicable)
- Security audit of build pipeline
- Review and update documentation

### Decommissioning Old AMIs

```bash
# List old AMIs
aws ec2 describe-images \
  --owners self \
  --filters "Name=tag:Environment,Values=production" \
  --query 'Images | sort_by(@, &CreationDate)[:-3].[ImageId,CreationDate]' \
  --output table

# Deregister (after confirming no instances use it)
aws ec2 deregister-image --image-id ami-xxxxx

# Delete snapshots
aws ec2 delete-snapshot --snapshot-id snap-xxxxx
```

## Additional Resources

### Documentation
- [Packer Documentation](https://www.packer.io/docs)
- [Ansible Best Practices](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html)
- [AWS AMI Best Practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)

### Related Repositories
- [Terraform Modules](https://github.com/your-org/terraform-modules) - Infrastructure as Code
- [Kubernetes Configs](https://github.com/your-org/k8s-configs) - K8s deployments
- [Monitoring Stack](https://github.com/your-org/monitoring) - Observability

## License

This project is licensed under the MIT License - see LICENSE file for details.
