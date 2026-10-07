# Blue-Green Deployment on AWS: Terraform, Ansible, Jenkins

A zero-downtime release pipeline for a Spring Boot banking app. Every change is built, tested, deployed to the idle environment, verified, and only then switched live behind an Application Load Balancer. If the check after the switch fails, traffic goes back to the previous version automatically.

Built as a CloudBoosta Academy project. The application code comes from the public DevOps Shack tutorial repo (a Kubernetes-based bank app). Everything around it is my own work: the infrastructure, the deployment automation, the pipeline, the monitoring, and a few changes to the app so it could be deployed and verified safely (listed below).

## What it does

```
                        Internet
                           |
                  Application Load Balancer  (listener :80, weighted 100/0)
                    |                    |
             blue target group     green target group
                    |                    |
              EC2 "blue"            EC2 "green"          <- same app, different version
                    \                    /
                     RDS MySQL (shared, private subnets)

  Jenkins (EC2) ---SSH + Ansible---> idle color
  Jenkins (IAM role) ---AWS CLI---> moves the listener weights
  Containers ---awslogs driver---> CloudWatch Logs;  CloudWatch alarms ---> SNS
```

The pipeline never touches the color that is serving users. It deploys to the other one, proves the new version is running there, warms it up behind the load balancer at 0% traffic, and then moves 100% of traffic with a single API call.

## Tools and what each one does

| Tool | Role |
|---|---|
| Terraform | Creates all 39 AWS resources: VPC, subnets, security groups, two app servers, the Jenkins server, the load balancer and target groups, RDS, IAM roles, CloudWatch log group, alarms and SNS topic |
| Ansible | Deploys the container to one color at a time (`--limit blue` or `--limit green`) using an inventory generated from AWS tags |
| Jenkins | Runs the pipeline: build, test, push image, deploy to idle, verify, switch, check, roll back on failure |
| Docker / Docker Hub | The app is packaged as `osahonseth1/bankapp:build-N`, one immutable tag per build |
| AWS ALB | Holds the two target groups; the traffic switch is a change of listener weights |
| CloudWatch | Container logs (log group `/bluegreen/bankapp`, one stream per color and build) and three alarms |

## Repository layout

```
Jenkinsfile                  the pipeline
scripts/bluegreen.sh         helper used by the pipeline (find live color, switch, wait, soak, rollback)
terraform/                   infrastructure (jenkins-bootstrap.sh installs Jenkins on first boot)
ansible/                     deploy.yml, group_vars, inventory generator
src/, pom.xml, Dockerfile    the application
```

## The pipeline, stage by stage

1. **Build and test**: `./mvnw clean package` with an in-memory H2 database, so the test needs no MySQL server.
2. **Build and push image**: tagged `build-<number>`; the tag never gets reused, so any version can be redeployed exactly.
3. **Find live and idle color**: read from the load balancer listener, nothing is hardcoded.
4. **Deploy to idle color**: Ansible installs Docker if needed and starts the new container with the database settings passed as environment variables.
5. **Verify idle color directly**: Jenkins SSHes to the idle server and asks it what it is running (`/version`). The app port is only open to the load balancer, so this has to go over SSH.
6. **Pre-warm**: the idle target group is attached at weight 0 and Jenkins waits until the load balancer itself reports it `healthy`.
7. **Switch traffic**: one `modify-listener` call, then Jenkins polls the public address until it answers as the new color and version.
8. **Post-switch check**: 15 consecutive requests must all be answered by the new version.
9. **On any failure after the switch**: weights go back to the previous color and Jenkins waits until the old version answers again.

Two build parameters make the behaviour demonstrable: `FLIP_TRAFFIC` (deploy and verify without switching) and `SIMULATE_FAILURE` (fail the post-switch check on purpose to prove the rollback).

## Measured results

| What | Result |
|---|---|
| Time for a listener change to take effect (switch or rollback) | 8 to 16 seconds across several runs, measured by polling `/version` every 3 seconds |
| Rollback after a simulated failure | previous version answering again about 15 seconds after the rollback command |
| Post-switch check | 15 of 15 requests served by the new version on every successful run |
| 502 errors on a flip between two servers that both run the app | 0 (checked with a log count on builds 2, 3 and 4) |

A listener change is not instant, so the pipeline polls for the new color instead of assuming success when the API call returns.

## Changes I made to the application

- **Test config**: `src/test/resources/application.properties` points tests at H2, because the original test needed a live MySQL on `localhost`.
- **Removed a hardcoded database password** from `application.properties`. Database host, user and password are now injected as environment variables at deploy time.
- **`/version` endpoint and a coloured badge** on the login and dashboard pages, showing the color and build number. This makes every deployment verifiable by the pipeline and visible in a browser.
- **Removed the unused Kubernetes manifests** that came with the tutorial.

## Monitoring and logging

- Container output goes to CloudWatch Logs through Docker's `awslogs` driver. The server role can only write to that one log group.
- `users-seeing-5xx`: the load balancer returned 5xx errors to users.
- `app-returning-5xx`: the application returned 5xx errors.
- `no-healthy-backend`: neither color has a healthy server. It adds both colors together, because the idle color is briefly unhealthy during every deployment and must not raise a false alarm.
- Alarms publish to an SNS topic; set `alert_email` to receive them by email.

## Evidence

Screenshots are in `docs/screenshots/`.

| File | Shows |
|---|---|
| [01-job-history.png](docs/screenshots/01-job-history.png) | Jenkins job: success, failure (intentional), success |
| [02-build-stages.png](docs/screenshots/02-build-stages.png) | A full successful run, every stage green |
| [03-app-blue-badge.png](docs/screenshots/03-app-blue-badge.png) | The app with the blue badge |
| [04-app-green-badge.png](docs/screenshots/04-app-green-badge.png) | The same app after the switch, green badge |
| [05-build2-stages-rollback.png](docs/screenshots/05-build2-stages-rollback.png) | The simulated failure and the stage where it fails |
| [06-build2-console-rollback.png](docs/screenshots/06-build2-console-rollback.png) | Console showing the automatic rollback |
| [07-cloudwatch-alarm-history.png](docs/screenshots/07-cloudwatch-alarm-history.png) | An alarm firing and recovering |
| [09-dockerhub-tags.png](docs/screenshots/09-dockerhub-tags.png) | One image tag per build |

## How to run it

1. AWS CLI configured, Terraform, a key pair in `eu-west-2`, and a Docker Hub account with an access token.
2. In `terraform/`, copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the key pair name, an Amazon Linux 2023 AMI ID, and your public IPv4 as `x.x.x.x/32`.
3. `export TF_VAR_db_password='...'`, then `terraform init && terraform apply`.
4. About 5 minutes later Jenkins is installed by its boot script. Open `http://<jenkins_public_ip>:8080`, unlock it, install the suggested plugins, and add three credentials: `dockerhub`, `app-ssh-key`, `db-password`.
5. Create a Pipeline job from SCM pointing at this repo and run it.
6. `terraform destroy` when finished. Everything is billed while it runs.

## Limitations and what I would change

- **First flip on a fresh stack shows 502s.** The first deploy switches from a server with no app on it, so the load balancer returns 502 for a few seconds (4 responses in my first run). Once both colors run an app this does not happen.
- **The rollback test is simulated.** It proves the rollback path works, but the post-switch check itself has not been shown catching a genuinely broken release.
- **Rollback is not instant.** A bad version can serve users for roughly the time a listener change takes to propagate, plus detection.
- **Shared database.** Blue and green use one RDS instance, so a schema change is not isolated by the blue/green switch. The app uses `ddl-auto=update`, which I would replace with proper migrations for anything real.
- **Plain HTTP.** No TLS certificate or domain; the listener is on port 80.
- **Single-AZ database and one instance per color.** Fine for a demo, not for production.
- **Jenkins setup is partly manual.** Software installs are scripted; the unlock, credentials and job creation are done in the browser, so no secrets sit in Terraform state. Jenkins data is not on a persistent disk, so a rebuild resets build numbers.
- **Image scanning (Trivy) was optional in the brief and is not implemented.**
- **Logging uses CloudWatch Logs** instead of an ELK stack.
