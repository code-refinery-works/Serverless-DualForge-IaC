#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { Aspects } from "aws-cdk-lib";
import { AwsSolutionsChecks } from "cdk-nag";
import { ServerlessApiStack } from "../lib/stack";

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
};

const environment = app.node.tryGetContext("environment") ?? "dev";
const logRetentionDays = environment === "prd" ? 90 : 14;

new ServerlessApiStack(app, `ServerlessApi-${environment}`, {
  env,
  environment,
  logRetentionDays,
  corsOrigins: app.node.tryGetContext("corsOrigins") ?? ["https://example.com"],
  description: `Serverless API stack - ${environment}`,
  terminationProtection: environment === "prd",
});

Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));

app.synth();