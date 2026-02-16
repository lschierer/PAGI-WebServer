// cspell: disable
import { Stack, type StackProps, Duration } from 'aws-cdk-lib';
import { type Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as cdk from 'aws-cdk-lib';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';

import * as iam from 'aws-cdk-lib/aws-iam';
import {
  aws_events as events,
  aws_events_targets as etargets,
  aws_lambda as lambda,
} from 'aws-cdk-lib';

import { UbuntuInstance } from './ec2-instance.ts';
import { type ApplicationStackProps } from './ApplicationStackProps.ts';

export class ApplicationStack extends Stack {
  readonly applicationURL;
  readonly appPrefix;
  constructor(scope: Construct, id: string, props: ApplicationStackProps) {
    super(scope, id, props);

    this.appPrefix = props.domainName.split('.').shift() ?? 'AppStack';

    this.applicationURL = `${props.appSubdomain}.${props.domainName}`;

    // Import existing hosted zone
    const hostedZone = route53.HostedZone.fromHostedZoneAttributes(
      this,
    `${this.appPrefix}HostedZone`,
    {
      hostedZoneId: props.hostedZoneId,
      zoneName: props.domainName,
    },
    );

    // Use provided VPC, import shared VPC, or create new one
    const vpc = props.vpc 
      ?? (props.CidrRange 
        ? new ec2.Vpc(this, `${this.appPrefix}Vpc`, {
            ipAddresses: ec2.IpAddresses.cidr(props.CidrRange),
            maxAzs: 2,
            natGateways: 0,
            subnetConfiguration: [
              {
                name: 'public',
                subnetType: ec2.SubnetType.PUBLIC,
                cidrMask: 28,
              },
            ],
          })
        : ec2.Vpc.fromVpcAttributes(this, 'ImportedVpc', {
            vpcId: cdk.Fn.importValue('SharedVpcId'),
            availabilityZones: ['us-east-2a', 'us-east-2b'],
            publicSubnetIds: [
              cdk.Fn.importValue('SharedVpcPublicSubnet1Id'),
              cdk.Fn.importValue('SharedVpcPublicSubnet2Id'),
            ],
          })
      );

    // Create S3 asset for application code
    const appCodeAsset = new s3assets.Asset(this, `${this.appPrefix}AppCode`, {
      path: props.appCodePath,
      exclude: props.appCodeExcludes ?? [
        'node_modules',
        'infrastructure/node_modules',
        'infrastructure/cdk.out',
        '.git',
        'dist',
      ],
    });

    const Instance = new UbuntuInstance(
      this,
    `${this.appPrefix}-${props.mode}-instance`,
    {
      ...props,
      vpc,
      appCodeAsset,
    },
    );

    // Create Route53 record
    if (props.mode === 'prod') {
      new route53.ARecord(this, `${this.appPrefix}RootDomainRecord`, {
        zone: hostedZone,
        recordName: '', // root domain
        target: route53.RecordTarget.fromIpAddresses(Instance.instancePublicIp),
      });
    } else {
      new route53.ARecord(this, `${this.appPrefix}DNSRecord`, {
        zone: hostedZone,
        recordName: `${props.appSubdomain}`,
        target: route53.RecordTarget.fromIpAddresses(Instance.instancePublicIp),
        ttl: Duration.minutes(5),
      });      
    }

    new route53.ARecord(this, `${this.appPrefix}WWWDNSRecord`, {
      zone: hostedZone,
      recordName: props.mode === 'prod' ? props.appSubdomain : `www.${props.appSubdomain}`,
      target: route53.RecordTarget.fromIpAddresses(Instance.instancePublicIp),
      ttl: Duration.minutes(5),
    });

    const instanceDNS = new route53.ARecord(this, `${this.appPrefix}InstanceDNSRecord`, {
      zone: hostedZone,
      recordName: `${Instance.hostname}`,
      target: route53.RecordTarget.fromIpAddresses(Instance.instancePublicIp),
      ttl: Duration.minutes(5),
    });
    instanceDNS.node.addDependency(Instance);

    new cdk.CfnOutput(this, `${this.appPrefix}InstanceDNSRecordOutput`, {
      value: `domainName: ${instanceDNS.domainName}; ip: ${Instance.instancePublicIp}`,
      description: 'The individual dns entry for the Ubuntu instance',
    });

    if (props.mode !== 'prod') {
      this.addSelfDestruct(24);
    }
  }

  private addSelfDestruct(hours: number) {
    const fn = new lambda.Function(this, `${this.appPrefix}SelfDestructFn`, {
      runtime: lambda.Runtime.NODEJS_LATEST,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
        const AWS = require('aws-sdk');
        const cf = new AWS.CloudFormation();
        exports.handler = async () => {
          const stackName = process.env.STACK_NAME;
          const maxAgeMs = Number(process.env.MAX_AGE_MS);
          const d = await cf.describeStacks({ StackName: stackName }).promise();
          const created = new Date(d.Stacks[0].CreationTime).getTime();
          const age = Date.now() - created;
          console.log({stackName, created, age, maxAgeMs});
          if (age >= maxAgeMs) {
            console.log('Deleting stack…');
            await cf.deleteStack({ StackName: stackName }).promise();
          } else {
            console.log('Not old enough yet.');
          }
        };
        `),
      timeout: Duration.minutes(5),
      environment: {
        STACK_NAME: Stack.of(this).stackName,
        MAX_AGE_MS: String(hours * 60 * 60 * 1000),
      },
    });

    // allow the function to look up and delete THIS stack only
    Stack.of(this).stackId.replace(':stack/', ':stack/*'); // describe needs wildcards sometimes
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['cloudformation:DescribeStacks'],
        resources: ['*'], // DescribeStacks doesn’t support resource-level perms reliably
      }),
      );
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['cloudformation:DeleteStack'],
        resources: [Stack.of(this).stackId],
      }),
      );

    // run every 3 hours; first run will be <24h so it will skip, then delete once it ages out
    const rule = new events.Rule(this, `${this.appPrefix}SelfDestructRule`, {
      schedule: events.Schedule.rate(Duration.hours(3)),
    });
    rule.addTarget(new etargets.LambdaFunction(fn));
  }
}
