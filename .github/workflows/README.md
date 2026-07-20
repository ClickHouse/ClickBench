# Benchmark automation

These workflows launch benchmark machines on AWS. The GitHub-hosted runner is
used only to launch: it assumes a federated IAM role and runs
`run-benchmark.sh`, which starts a self-terminating EC2 machine. The machine
clones the repository, runs `<system>/benchmark.sh` under cloud-init (see
`cloud-init.sh.in`), sends its log to the results sink at play.clickhouse.com,
and shuts down. Collecting the results back into `<system>/results/` is a
separate process, implemented separately. Runs launched for a pull request
carry the PR number in the log (the `ClickBench PR:` line), which the sink
parses into the `clickbench_pr` column of `sink.results`, so they can be told
apart from the runs of main and are excluded by `collect-results.sh`.

| Workflow | Trigger | What it launches |
|----------|---------|------------------|
| `benchmark-daily.yml` | daily, 02:00 UTC | the ClickHouse variants, each on the whole set of machine types, from main |
| `benchmark-manual.yml` | manual | any systems, machines, repository and branch |
| `benchmark-pr.yml` | pull requests | the systems whose directories the PR changes (results and *.md files don't count), from the PR's repository and branch, after manual approval |

## Setup

1. An IAM role for GitHub's OIDC provider, restricted to this repository:

   ```json
   {
       "Version": "2012-10-17",
       "Statement": [{
           "Effect": "Allow",
           "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
           "Action": "sts:AssumeRoleWithWebIdentity",
           "Condition": {
               "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
               "StringLike": { "token.actions.githubusercontent.com:sub": "repo:ClickHouse/ClickBench:*" }
           }
       }]
   }
   ```

   The permissions policy needs `ec2:RunInstances`, `ec2:CreateTags`,
   `ec2:DescribeImages`, and `ec2:DescribeInstanceTypes`.

   The role's ARN and the region (us-east-1) are set in
   `.github/actions/launch-benchmark/action.yml`.

2. An environment named `benchmark-approval` with required reviewers. It
   gates the PR workflow: nothing is launched for a pull request until a
   reviewer approves the pending deployment.

3. Enough on-demand vCPU quota in the region: the daily run launches six
   systems on nine machine types - 3744 vCPUs if everything runs at once,
   most of it in the three metal instances (192 vCPUs each) of the six
   systems. `run-benchmark.sh` waits and retries while the quota or the
   capacity is exhausted, but only within the job's 55-minute limit; what
   could not be launched by then is reported as failed.
