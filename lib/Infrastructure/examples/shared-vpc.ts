#!/usr/bin/env node
import * as cdk from "aws-cdk-lib/core";
import * as ec2 from 'aws-cdk-lib/aws-ec2';

import {
  SharedVpcStack,
  ApplicationStack,
  type ApplicationStackProps,
} from '../../../PAGI-WebServer/lib/Infrastructure/index.ts';

const app = new cdk.App();

const region = 'us-east-2';
const account = process.env.CDK_DEFAULT_ACCOUNT;

// Create shared VPC once
const vpcStack = new SharedVpcStack(app, 'SharedVpc', {
  env: { account, region },
  vpcCidr: '10.233.0.0/16',
  maxAzs: 2,
});

// Example: Multiple apps sharing the VPC
// Each gets isolated by security groups, not separate VPCs

const lukesEbooksProps: ApplicationStackProps = {
  env: { account, region },
  mode: 'dev',
  prefix: "LukesEBooks",
  appSubdomain: 'dev',
  domainName: "books.schierer.org",
  hostedZoneId: "ZOB4NXMJR2BZF",
  zoneName: 'schierer.org',
  instanceSize: ec2.InstanceSize.NANO,
  appPort: 3002,
  mainPerlDistro: 'App-LukesEbooks',
  appCodePath: '../Lukes-Ebooks',
  vpc: vpcStack.vpc, // Use shared VPC
};

const evonyProps: ApplicationStackProps = {
  env: { account, region },
  mode: 'dev',
  prefix: "EvonyTKR",
  appSubdomain: 'dev',
  domainName: "evonytkrtips.net",
  hostedZoneId: "Z02705452UES0AYN9485J",
  zoneName: 'evonytkrtips.net',
  instanceSize: ec2.InstanceSize.SMALL,
  appPort: 3000,
  mainPerlDistro: 'Game-EvonyTKR',
  appCodePath: '../Game-EvonyTKR',
  vpc: vpcStack.vpc, // Use shared VPC
};

new ApplicationStack(app, 'LukesEBooks-dev', lukesEbooksProps);
new ApplicationStack(app, 'EvonyTKR-dev', evonyProps);

app.synth();
