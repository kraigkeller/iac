#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENVIRONMENT="${1:-}"
AMI_ID="${2:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

usage() {
    cat <<EOF
Usage: $0 <environment> [ami-id]

Rollback to a previous golden image AMI.

Arguments:
    environment    Target environment (dev|staging|production)
    ami-id         AMI ID to rollback to (optional, uses previous version if not specified)

Environment Variables:
    AWS_REGION     AWS region (default: us-east-1)

Examples:
    $0 dev
    $0 production ami-0123456789abcdef0
    AWS_REGION=us-west-2 $0 staging

EOF
    exit 1
}

if [ -z "$ENVIRONMENT" ]; then
    usage
fi

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
    echo "Error: Invalid environment. Must be dev, staging, or production."
    usage
fi

echo "=========================================="
echo "⚠️  AMI Rollback Utility"
echo "=========================================="
echo "Environment: $ENVIRONMENT"
echo "AWS Region: $AWS_REGION"
echo ""

read -p "⚠️  Rollback is a critical operation. Enter reason for rollback: " REASON

if [ -z "$REASON" ]; then
    echo "Error: Rollback reason is required."
    exit 1
fi

CURRENT_AMI=$(aws ec2 describe-images \
    --owners self \
    --region "$AWS_REGION" \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
              "Name=tag:Production,Values=true" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

echo "Current production AMI: $CURRENT_AMI"

if [ -z "$AMI_ID" ]; then
    echo ""
    echo "Fetching previous AMI version..."

    AMI_ID=$(aws ec2 describe-images \
        --owners self \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
                  "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-2].ImageId' \
        --output text)

    if [ "$AMI_ID" == "None" ] || [ -z "$AMI_ID" ]; then
        echo "Error: No previous AMI found for rollback"
        exit 1
    fi

    echo "Selected previous AMI: $AMI_ID"
else
    echo "Using specified AMI: $AMI_ID"
fi

if [ "$AMI_ID" == "$CURRENT_AMI" ]; then
    echo "Error: Target AMI is the same as current AMI"
    exit 1
fi

AMI_STATE=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$AWS_REGION" \
    --query 'Images[0].State' \
    --output text)

if [ "$AMI_STATE" != "available" ]; then
    echo "Error: Target AMI is not available (state: $AMI_STATE)"
    exit 1
fi

AMI_INFO=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$AWS_REGION" \
    --query 'Images[0].[Name,CreationDate,Description]' \
    --output text)

echo ""
echo "Rollback Target Details:"
echo "$AMI_INFO" | awk '{print "  " $0}'
echo ""

read -p "⚠️  Proceed with rollback from $CURRENT_AMI to $AMI_ID? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Rollback cancelled."
    exit 0
fi

echo ""
echo "Executing rollback..."

echo "Tagging current AMI as superseded..."
aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$CURRENT_AMI" \
    --tags \
        Key=Status,Value=Superseded \
        Key=SupersededDate,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        Key=RollbackReason,Value="$REASON" >/dev/null

echo "✓ Tagged current AMI as superseded"

echo "Promoting rollback AMI to production..."
aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$AMI_ID" \
    --tags \
        Key=Production,Value=true \
        Key=RolledBackDate,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        Key=RollbackReason,Value="$REASON" >/dev/null

echo "✓ Promoted rollback AMI to production"

LT_ID=$(aws ec2 describe-launch-templates \
    --region "$AWS_REGION" \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
    --query 'LaunchTemplates[0].LaunchTemplateId' \
    --output text)

if [ "$LT_ID" != "None" ] && [ -n "$LT_ID" ]; then
    echo "Updating launch template..."

    NEW_VERSION=$(aws ec2 create-launch-template-version \
        --region "$AWS_REGION" \
        --launch-template-id "$LT_ID" \
        --source-version '$Latest' \
        --launch-template-data "{\"ImageId\":\"$AMI_ID\"}" \
        --version-description "ROLLBACK: $REASON" \
        --query 'LaunchTemplateVersion.VersionNumber' \
        --output text)

    echo "✓ Created launch template version: $NEW_VERSION"

    aws ec2 modify-launch-template \
        --region "$AWS_REGION" \
        --launch-template-id "$LT_ID" \
        --default-version "$NEW_VERSION" >/dev/null

    echo "✓ Set version $NEW_VERSION as default"
fi

ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
    --region "$AWS_REGION" \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' \
    --output text)

if [ "$ASG_NAME" != "None" ] && [ -n "$ASG_NAME" ]; then
    echo "Initiating Auto Scaling Group instance refresh..."

    REFRESH_ID=$(aws autoscaling start-instance-refresh \
        --region "$AWS_REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --preferences '{
            "MinHealthyPercentage": 90,
            "InstanceWarmup": 300
        }' \
        --query 'InstanceRefreshId' \
        --output text)

    echo "✓ Instance refresh started: $REFRESH_ID"
fi

RECORD_FILE="$PROJECT_ROOT/rollback-records/rollback-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$PROJECT_ROOT/rollback-records"

cat > "$RECORD_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "$ENVIRONMENT",
  "reason": "$REASON",
  "from_ami": "$CURRENT_AMI",
  "to_ami": "$AMI_ID",
  "initiated_by": "${USER:-unknown}"
}
EOF

echo "✓ Rollback record saved: $RECORD_FILE"

echo ""
echo "=========================================="
echo "✓ Rollback Complete"
echo "=========================================="
echo "Environment: $ENVIRONMENT"
echo "Previous AMI: $CURRENT_AMI"
echo "Current AMI: $AMI_ID"
echo "Reason: $REASON"
echo ""
echo "⚠️  IMPORTANT: Monitor application health and verify successful rollback"
echo ""
