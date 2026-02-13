import { NestedStack, Stack } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';
import { type ApplicationStackProps } from './ApplicationStackProps.ts';
export interface UbuntuInstanceProps extends ApplicationStackProps {
    vpc: ec2.IVpc | ec2.Vpc;
    appCodeAsset: s3assets.Asset;
}
export declare class UbuntuInstance extends ec2.Instance {
    readonly hostname: string;
    constructor(scope: NestedStack | Stack, id: string, props: UbuntuInstanceProps);
}
//# sourceMappingURL=ec2-instance.d.ts.map