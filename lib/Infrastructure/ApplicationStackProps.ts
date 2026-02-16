// cspell: disable
import {  type StackProps } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
//import * as s3assets from 'aws-cdk-lib/aws-s3-assets';

import { z } from "zod";

const props = z.object({
mode: z.string(),
    port: z.number().min(3000).max(3999),

})

type props = z.infer<typeof props>;

const StackProps = z.looseObject({
  env: z.object({
    account: z.string().optional(),
    region: z.string().optional(),
  }),
  tags: z.record(z.string(), z.string()),
  crossRegionReferences: z.boolean(),
}) satisfies z.ZodType<StackProps>;

const validModes = z.enum([
  'dev',
  'testing',
  'test' , 
  'staging' , 
  'prod'
]);

export const ApplicationStackProps = StackProps.extend({
  mode: z.string().refine((val) => {
    return validModes.safeParse(val);
  }),
  CidrRange: z.string().optional(), // Optional if vpc is provided
  prefix: z.string(),
  domainName: z.string(),
  appSubdomain: z.string(),
  hostedZoneId: z.string(),
  zoneName: z.string(),
  appPort: z.number().min(3000).max(3999),
  instanceSize: z.enum(ec2.InstanceSize),
  mainPerlDistro: z.string(),
  appCodePath: z.string(),
  appCodeExcludes: z.string().array(),
  vpc: z.instanceof(ec2.Vpc).optional(), // Optional: use shared VPC
});

export type ApplicationStackProps = z.infer<typeof ApplicationStackProps>;


