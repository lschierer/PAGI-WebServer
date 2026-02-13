import { Stack } from 'aws-cdk-lib';
import { type Construct } from 'constructs';
import { type ApplicationStackProps } from './ApplicationStackProps.ts';
export declare class ApplicationStack extends Stack {
    readonly applicationURL: string;
    readonly appPrefix: string;
    constructor(scope: Construct, id: string, props: ApplicationStackProps);
    private addSelfDestruct;
}
//# sourceMappingURL=ApplicationStack.d.ts.map