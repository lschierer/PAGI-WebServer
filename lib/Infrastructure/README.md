# PAGI-WebServer Infrastructure Framework

This directory contains the consolidated CDK infrastructure code used by all PAGI-WebServer-based projects.

## Architecture

All projects deploy as:
- Single EC2 instance (t4g.nano to t4g.medium depending on needs)
- Ubuntu 24.04 LTS (Noble)
- Nginx reverse proxy with SSL/TLS (Let's Encrypt via certbot)
- Perl/Mojolicious application
- Application code deployed via S3 asset (no git clone needed)
- Route53 DNS with custom domain
- CloudWatch monitoring and alarms

## Usage

### Option 1: Standalone (Each App Gets Its Own VPC)

Create a simple wrapper script (e.g., `infrastructure/bin/app.ts` or `scripts/infra.ts`):

```typescript
#!/usr/bin/env node
import * as cdk from "aws-cdk-lib/core";
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import path from 'path';
import { fileURLToPath } from 'url';

import {
  ApplicationStack,
  type ApplicationStackProps,
} from '../../../PAGI-WebServer/lib/Infrastructure/index.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = new cdk.App();

const props: ApplicationStackProps = {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'us-east-2',
  },
  mode: 'prod',
  CidrRange: '10.233.0.64/27',
  prefix: "MyApp",
  appSubdomain: 'www',
  domainName: "myapp.example.com",
  hostedZoneId: "Z1234567890ABC",
  zoneName: 'example.com',
  instanceSize: ec2.InstanceSize.NANO,
  appPort: 3000,
  mainPerlDistro: 'App-MyApp',
  appCodePath: path.join(__dirname, '../..'),
  appCodeExcludes: [
    'node_modules',
    'infrastructure/node_modules',
    'infrastructure/cdk.out',
    '.git',
    'dist',
  ],
};

new ApplicationStack(app, 'myapp-prod-stack', props);

app.synth();
```

### Option 2: Shared VPC (Recommended for Multiple Apps)

More cost-effective when running multiple applications. Each app is isolated by security groups:

```typescript
#!/usr/bin/env node
import * as cdk from "aws-cdk-lib/core";
import * as ec2 from 'aws-cdk-lib/aws-ec2';

import {
  SharedVpcStack,
  ApplicationStack,
  type ApplicationStackProps,
} from '../../../PAGI-WebServer/lib/Infrastructure/index.ts';

const app = new cdk.App();

// Create shared VPC once
const vpcStack = new SharedVpcStack(app, 'SharedVpc', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-2' },
  vpcCidr: '10.233.0.0/16',
  maxAzs: 2,
});

// App 1
const app1Props: ApplicationStackProps = {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-2' },
  mode: 'prod',
  prefix: "App1",
  appSubdomain: 'www',
  domainName: "app1.example.com",
  hostedZoneId: "Z1234567890ABC",
  zoneName: 'example.com',
  instanceSize: ec2.InstanceSize.NANO,
  appPort: 3000,
  mainPerlDistro: 'App-App1',
  appCodePath: '../App1',
  vpc: vpcStack.vpc, // Share VPC
};

// App 2
const app2Props: ApplicationStackProps = {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-2' },
  mode: 'prod',
  prefix: "App2",
  appSubdomain: 'www',
  domainName: "app2.example.com",
  hostedZoneId: "Z1234567890DEF",
  zoneName: 'example.com',
  instanceSize: ec2.InstanceSize.NANO,
  appPort: 3001,
  mainPerlDistro: 'App-App2',
  appCodePath: '../App2',
  vpc: vpcStack.vpc, // Share VPC
};

new ApplicationStack(app, 'App1-prod', app1Props);
new ApplicationStack(app, 'App2-prod', app2Props);

app.synth();
```

Deploy all at once:
```bash
cdk deploy --all
```

Or deploy individually:
```bash
cdk deploy SharedVpc
cdk deploy App1-prod
cdk deploy App2-prod
```

### Deploy

```bash
cd your-project/infrastructure  # or wherever your wrapper is
AWS_PROFILE=your-profile cdk deploy
```

### Configuration Options

- `mode`: 'dev' | 'testing' | 'staging' | 'prod'
- `CidrRange`: VPC CIDR block (optional if `vpc` is provided; required otherwise)
- `vpc`: Optional shared VPC (from SharedVpcStack)
- `prefix`: Application prefix for resource naming
- `appSubdomain`: Subdomain for the app (e.g., 'www', 'dev')
- `domainName`: Full domain name
- `hostedZoneId`: Route53 hosted zone ID
- `zoneName`: Route53 zone name
- `instanceSize`: EC2 instance size (NANO, SMALL, MEDIUM, etc.)
- `appPort`: Port your Mojolicious app listens on
- `mainPerlDistro`: Name of your Perl distribution
- `appCodePath`: Path to your application code (will be zipped and uploaded to S3)
- `appCodeExcludes`: Files/directories to exclude from the S3 asset

### Shared VPC Benefits

- **Cost savings**: One VPC instead of multiple ($0 vs ~$0.50/month per VPC)
- **Simpler networking**: All apps in same network space
- **Security**: Apps still isolated by security groups (no cross-app traffic by default)
- **Easier management**: Single VPC to monitor and maintain

## Files Included

- `ApplicationStack.ts`: Main CDK stack
- `ApplicationStackProps.ts`: TypeScript interface for stack props
- `ec2-instance.ts`: EC2 instance construct
- `userdata.ts`: CloudFormation Init and UserData configuration
- `prefixBin/`: Shell scripts for bootstrap, deployment, nginx setup, etc.
- `etc/`: Configuration files (systemd service, logrotate, mise config)

## Migration from Old Approach

If your project currently has its own `infrastructure/lib/` directory:

1. Create a simple wrapper script as shown above
2. Delete `infrastructure/lib/`
3. Delete `infrastructure/prefixBin/` and `infrastructure/etc/` (now in common framework)
4. Keep only `infrastructure/bin/` with your wrapper script
5. Update `cdk.json` to point to your new wrapper script

## Benefits

- Single source of truth for infrastructure code
- Consistent deployment across all projects
- Easier to maintain and update
- No git clone issues with private repos
- S3 asset approach works with any repo structure
