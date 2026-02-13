import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3Assets from 'aws-cdk-lib/aws-s3-assets';
import { Stack } from 'aws-cdk-lib';
import { type UbuntuInstanceProps } from './ec2-instance.ts';
export declare class CustomUbuntuUserData {
    init: ec2.CloudFormationInit;
    initOptions: ec2.ApplyCloudFormationInitOptions;
    prefix_bin_asset: s3Assets.Asset;
    prefix_etc_asset: s3Assets.Asset;
    ssh_keys_asset: s3Assets.Asset;
    shellCommands: ec2.UserData;
    private mode_to_stage;
    constructor(stack: Stack, props: UbuntuInstanceProps, hostname: string);
}
//# sourceMappingURL=userdata.d.ts.map