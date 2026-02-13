import { type StackProps } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
export interface ApplicationStackProps extends StackProps {
    mode: 'dev' | 'testing' | 'test' | 'staging' | 'prod';
    CidrRange?: string;
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
    vpc?: ec2.IVpc;
}
//# sourceMappingURL=ApplicationStackProps.d.ts.map