Terraform for deploying SampleWebApiAspNetCore to AWS App Runner.

What it does: 
1. creates an ECR repo
2. builds the Docker image from the repo-root dockerfile
3. pushes it
4. and runs it in App Runner (soon will be deprecated, but express runner doesn't work for some reason) with a public HTTPS URL. 

Docker must be running locally (the build happens on your machine, not in AWS). The AWS CLI must already be authenticated - run `aws sts get-caller-identity` and confirm you see your account (if not run `aws login`). 

## Run
```
    cd terraform
    terraform init
    terraform apply
```

Type `yes` at the prompt. The first apply takes about 3-5 minutes; most of that is App Runner provisioning. When it finishes, the outputs include `service_url` and `swagger_url` - open `swagger_url` in a browser to confirm it works.

Updating the app. Edit any `.cs` file (or the dockerfile, or `.csproj`, etc.), then run `terraform apply` again. Terraform detects the source change, rebuilds the image with a new tag, pushes it, and tells App Runner to redeploy.

## Don't forget to turn it off

Run `terraform destroy`  This also deletes the ECR repo and all images in it.

Variables you can override. Region defaults to `us-east-1`, repo and service names default to `sample-webapi-aspnetcore`. Change them with `-var`, e.g. `terraform apply -var region=eu-west-1`.
Notes. The image is built for `linux/amd64` regardless of your host, so Apple Silicon is fine. Swagger only works because we're in development mode via `ASPNETCORE_ENVIRONMENT=Development`.