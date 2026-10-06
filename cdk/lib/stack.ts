import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as kms from "aws-cdk-lib/aws-kms";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as iam from "aws-cdk-lib/aws-iam";
import { NodejsFunction } from "aws-cdk-lib/aws-lambda-nodejs";
import * as path from "path";

interface Props extends cdk.StackProps {
  environment: string;
  logRetentionDays: number;
  corsOrigins: string[];
}

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);

    const { environment, logRetentionDays, corsOrigins } = props;
    const namePrefix = `serverless-api-${environment}`;

    // ── KMS CMK ────────────────────────────────────────────────
    const cmk = new kms.Key(this, "Cmk", {
      alias: `alias/${namePrefix}`,
      description: `${namePrefix} CMK`,
      enableKeyRotation: true,
      pendingWindow: cdk.Duration.days(30),
      removalPolicy: environment === "prd" ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // ── DynamoDB ───────────────────────────────────────────────
    const table = new dynamodb.Table(this, "ItemsTable", {
      tableName: `${namePrefix}-items`,
      partitionKey: { name: "pk", type: dynamodb.AttributeType.STRING },
      sortKey:      { name: "sk", type: dynamodb.AttributeType.STRING },
      billingMode:  dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      encryption:   dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey: cmk,
      removalPolicy: environment === "prd" ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // ── CloudWatch Log Groups ──────────────────────────────────
    const lambdaLogGroup = new logs.LogGroup(this, "LambdaLogGroup", {
      logGroupName:  `/aws/lambda/${namePrefix}-handler`,
      retention:     logRetentionDays as logs.RetentionDays,
      encryptionKey: cmk,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const apigwLogGroup = new logs.LogGroup(this, "ApigwLogGroup", {
      logGroupName:  `/aws/apigateway/${namePrefix}`,
      retention:     logRetentionDays as logs.RetentionDays,
      encryptionKey: cmk,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ── Lambda Function ────────────────────────────────────────
    const handler = new NodejsFunction(this, "Handler", {
      functionName:  `${namePrefix}-handler`,
      entry:         path.join(__dirname, "../../src/handlers/index.ts"),
      handler:       "handler",
      runtime:       lambda.Runtime.NODEJS_20_X,
      architecture:  lambda.Architecture.ARM_64,
      timeout:       cdk.Duration.seconds(29),
      memorySize:    512,
      tracing:       lambda.Tracing.ACTIVE,
      logGroup:      lambdaLogGroup,
      bundling:      { minify: true, sourceMap: true, target: "es2022" },
      environment: {
        TABLE_NAME:             table.tableName,
        ENVIRONMENT:            environment,
        POWERTOOLS_SERVICE_NAME: namePrefix,
      },
    });

    // Minimal least-privilege policy — no wildcard resources
    handler.addToRolePolicy(new iam.PolicyStatement({
      sid:       "DynamoDBAccess",
      actions:   ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan"],
      resources: [table.tableArn, `${table.tableArn}/index/*`],
    }));
    cmk.grantEncryptDecrypt(handler);

    // ── API Gateway HTTP API ───────────────────────────────────
    const api = new apigwv2.HttpApi(this, "HttpApi", {
      apiName:     `${namePrefix}-api`,
      corsPreflight: {
        allowOrigins: corsOrigins,
        allowMethods: [apigwv2.CorsHttpMethod.GET, apigwv2.CorsHttpMethod.POST, apigwv2.CorsHttpMethod.PUT, apigwv2.CorsHttpMethod.DELETE, apigwv2.CorsHttpMethod.OPTIONS],
        allowHeaders: ["Content-Type", "Authorization"],
        maxAge:       cdk.Duration.minutes(5),
      },
    });

    const lambdaIntegration = new integrations.HttpLambdaIntegration("LambdaIntegration", handler, {
      payloadFormatVersion: apigwv2.PayloadFormatVersion.VERSION_2_0,
    });

    const routes: [string, apigwv2.HttpMethod][] = [
      ["/items",      apigwv2.HttpMethod.GET],
      ["/items",      apigwv2.HttpMethod.POST],
      ["/items/{id}", apigwv2.HttpMethod.GET],
      ["/items/{id}", apigwv2.HttpMethod.PUT],
      ["/items/{id}", apigwv2.HttpMethod.DELETE],
    ];
    routes.forEach(([path, method]) => api.addRoutes({ path, methods: [method], integration: lambdaIntegration }));

    const cfnStage = api.defaultStage!.node.defaultChild as apigwv2.CfnStage;
    cfnStage.accessLogSettings = {
      destinationArn: apigwLogGroup.logGroupArn,
      format: JSON.stringify({ requestId: "$context.requestId", sourceIp: "$context.identity.sourceIp", httpMethod: "$context.httpMethod", path: "$context.path", status: "$context.status", responseLatency: "$context.responseLatency" }),
    };
    cfnStage.defaultRouteSettings = { throttlingBurstLimit: 500, throttlingRateLimit: 1000, detailedMetricsEnabled: true };

    // ── Outputs ────────────────────────────────────────────────
    new cdk.CfnOutput(this, "ApiEndpoint",       { value: api.apiEndpoint,         description: "HTTP API endpoint URL" });
    new cdk.CfnOutput(this, "LambdaFunctionName",{ value: handler.functionName,    description: "Lambda function name" });
    new cdk.CfnOutput(this, "DynamoDbTableName", { value: table.tableName,         description: "DynamoDB table name" });
    new cdk.CfnOutput(this, "KmsKeyArn",         { value: cmk.keyArn,              description: "KMS CMK ARN" });
  }
}