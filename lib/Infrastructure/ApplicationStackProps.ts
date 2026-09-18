// cspell: disable
import { type StackProps } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';

import { z } from "zod";

const validModes = z.enum([
  'dev',
  'testing',
  'test',
  'staging',
  'prod'
]);

const ApplicationStackPropsSchema = z.object({
  env: z.object({
    account: z.string().optional(),
    region: z.string().optional(),
  }).optional(),
  tags: z.record(z.string(), z.string()).optional(),
  crossRegionReferences: z.boolean().optional(),
  mode: z.string().refine((val) => {
    return validModes.safeParse(val).success;
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
  // Which branch of PAGI-WebServer the instance clones. Defaults to main.
  //
  // Exists so an unmerged framework branch can be exercised on a dev stack. The
  // deploy scripts build from a commit, so before this a framework change could not
  // be tested until it was already on main - which is the opposite of what branching
  // the framework is for.
  // Optional rather than defaulted: z.default() would make this REQUIRED in the
  // inferred output type, which is what every stack's props object is typed against.
  // The fallback to main lives at the substitution site in userdata.ts instead.
  pagiBranch: z.string().optional(),
  appCodePath: z.string(),
  appCodeExcludes: z.string().array().optional(),
  vpc: z.instanceof(ec2.Vpc).optional(), // Optional: use shared VPC
});

export { ApplicationStackPropsSchema as ApplicationStackProps };

export type ApplicationStackProps = z.infer<typeof ApplicationStackPropsSchema> & StackProps;
