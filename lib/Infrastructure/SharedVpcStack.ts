import { Stack, type StackProps } from 'aws-cdk-lib';
import { type Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';

export interface SharedVpcStackProps extends StackProps {
  vpcCidr: string;
  maxAzs?: number;
}

export class SharedVpcStack extends Stack {
  public readonly vpc: ec2.Vpc;

  constructor(scope: Construct, id: string, props: SharedVpcStackProps) {
    super(scope, id, props);

    this.vpc = new ec2.Vpc(this, 'SharedVpc', {
      ipAddresses: ec2.IpAddresses.cidr(props.vpcCidr),
      maxAzs: props.maxAzs ?? 2,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24, // /24 = 256 IPs, plenty for many instances
        },
      ],
    });
  }
}
