#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ENVIRONMENT="${1:-dev}"
AMI_ID="${2:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

usage() {
    cat <<EOF
Usage: $0 <environment> [ami-id]

Deploy a golden image AMI to a specific environment.

Arguments:
    environment    Target environment (dev|staging|production)
    ami-id         AMI ID to deploy (optional, uses latest if not specified)

Environment Variables:
    AWS_REGION     AWS region (default: us-east-1)

Examples:
    $0 dev
    $0 staging ami-0123456789abcdef0
    AWS_REGION=us-west-2 $0 production

EOF
    exit 1
}

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
    echo "Error: Invalid environment. Must be dev, staging, or production."
    usage
fi

if [ "$ENVIRONMENT" == "production" ]; then
    read -p "Deploy to PRODUCTION? (yes/no): " confirm
    [ "$confirm" != "yes" ] && exit 0
fi

if [ -z "$AMI_ID" ]; then
    AMI_ID=$(aws ec2 describe-images \
        --owners self \
        --region "$AWS_REGION" \
        --filters "Name=tag:Environment,Values=$ENVIRONMENT" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
    [ "$AMI_ID" == "None" ] || [ -z "$AMI_ID" ] && exit 1
else
    AMI_STATE=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$AWS_REGION" --query 'Images[0].State' --output text)
    [ "$AMI_STATE" != "available" ] && exit 1
fi
LT_ID=$(aws ec2 describe-launch-templates \
    --region "$AWS_REGION" \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
    --query 'LaunchTemplates[0].LaunchTemplateId' \
    --output text)

if [ "$LT_ID" != "None" ] && [ -n "$LT_ID" ]; then
    NEW_VERSION=$(aws ec2 create-launch-template-version \
        --region "$AWS_REGION" \
        --launch-template-id "$LT_ID" \
        --source-version '$Latest' \
        --launch-template-data "{\"ImageId\":\"$AMI_ID\"}" \
        --version-description "Deployed AMI $AMI_ID on $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --query 'LaunchTemplateVersion.VersionNumber' \
        --output text)

    echo "✓ Created launch template version: $NEW_VERSION"

    aws ec2 modify-launch-template \
        --region "$AWS_REGION" \
        --launch-template-id "$LT_ID" \
        --default-version "$NEW_VERSION" >/dev/null

    echo "✓ Set version $NEW_VERSION as default"
else
    echo "⚠ No launch template found for $ENVIRONMENT"
fi

ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
    --region "$AWS_REGION" \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' \
    --output text)

if [ "$ASG_NAME" != "None" ] && [ -n "$ASG_NAME" ]; then
    echo ""
    echo "Initiating Auto Scaling Group instance refresh..."

    REFRESH_ID=$(aws autoscaling start-instance-refresh \
        --region "$AWS_REGION" \
        --auto-scaling-group-name "$ASG_NAME" \
        --preferences '{
            "MinHealthyPercentage": 90,
            "InstanceWarmup": 300,
            "CheckpointPercentages": [50, 100],
            "CheckpointDelay": 300
        }' \
        --query 'InstanceRefreshId' \
        --output text)

    echo "✓ Instance refresh started: $REFRESH_ID"
    echo ""
    echo "Monitor progress with:"
    echo "  aws autoscaling describe-instance-refreshes \\"
    echo "    --auto-scaling-group-name $ASG_NAME \\"
    echo "    --instance-refresh-ids $REFRESH_ID"
else
    echo "⚠ No Auto Scaling Group found for $ENVIRONMENT"
fi

aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$AMI_ID" \
    --tags \
        Key=LastDeployed,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        Key=DeployedTo,Value="$ENVIRONMENT" >/dev/null

echo ""
echo "=========================================="
echo "✓ Deployment Complete"
echo "=========================================="
echo "AMI $AMI_ID deployed to $ENVIRONMENT"
echo ""
