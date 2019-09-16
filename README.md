# Autofac.UpgradeTest
Provides upgrade test automation for Autofac Integrations

Run upgradeallintegrations.ps1 with an api key to build and test all the autofac integrations:

```
    .\coreupgradetest.ps1 -appveyorApiKey ***apikey*** -testBranchName "branchtotest"
```

You'll get a set of either trx files or html files in the reports folder once everything is done.

If any dotnet sdk versions are not available, they will be installed locally to temp_sdk.