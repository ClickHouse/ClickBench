This benchmark is not automated.

Go to https://clapdb.com/  
Click on "Get Started" and then install the clapctl.

```
curl -fsSL https://clapdb.com/install.sh | sh
```

Configure your AWS credentials following the instructions from
[AWS Official Documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-authentication-short-term.html)

> You must make sure your credentials has `AdministratorAccess`

Increase your AWS Quota For ClapDB

```
clapctl quota --set 1000
```

Deploy your ClapBD instance

```
clapctl deploy -n your_cluster_name
```

After the deployment is finished, you will need to log in to the ClapDB web
interface and register a new instance. Go to
https://clapdb.com/dashboard/deployments/ and bind your instance a pro license.

Import the clickbench dataset

```
clapctl dataset --import hits.tsv -n your_cluster_name
```

Then run the benchmark

```
export deployment=your_cluster_name
./run.sh
```
