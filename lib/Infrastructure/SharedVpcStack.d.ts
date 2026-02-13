import { Stack, type StackProps } from 'aws-cdk-lib';
import { type Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
export interface SharedVpcStackProps extends StackProps {
    vpcCidr: string;
    maxAzs?: number;
}
export declare class SharedVpcStack extends Stack {
    readonly vpc: ec2.Vpc;
    constructor(scope: Construct, id: string, props: SharedVpcStackProps);
}
//# sourceMappingURL=SharedVpcStack.d.ts.map