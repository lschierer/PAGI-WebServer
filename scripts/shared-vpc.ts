#!/usr/bin/env node
import * as cdk from "aws-cdk-lib/core";
import { SharedVpcStack } from '../lib/Infrastructure/index.ts';

const app = new cdk.App();

const vpcStack = new SharedVpcStack(app, 'SharedVpc', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'us-east-2',
  },
  vpcCidr: '10.173.0.0/16',
  maxAzs: 2,
});

// Export VPC ID and subnet IDs for other stacks to import
new cdk.CfnOutput(vpcStack, 'VpcId', {
  value: vpcStack.vpc.vpcId,
  exportName: 'SharedVpcId',
});

new cdk.CfnOutput(vpcStack, 'PublicSubnet1Id', {
  value: vpcStack.vpc.publicSubnets[0].subnetId,
  exportName: 'SharedVpcPublicSubnet1Id',
});

new cdk.CfnOutput(vpcStack, 'PublicSubnet2Id', {
  value: vpcStack.vpc.publicSubnets[1].subnetId,
  exportName: 'SharedVpcPublicSubnet2Id',
});

app.synth();
