import { type StackProps } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';

export interface ApplicationStackProps extends StackProps {
  mode: 'dev' | 'testing' | 'staging' | 'prod';
  CidrRange?: string; // Optional if vpc is provided
  prefix: string;
  domainName: string;
  appSubdomain: string;
  hostedZoneId: string;
  zoneName: string;
  appPort: number;
  instanceSize: ec2.InstanceSize;
  mainPerlDistro: string;
  appCodePath: string;
  appCodeExcludes?: string[];
  vpc?: ec2.IVpc; // Optional: use shared VPC
}
