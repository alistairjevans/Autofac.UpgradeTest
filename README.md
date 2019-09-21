# Autofac.UpgradeTest
Provides upgrade test automation for Autofac Integrations

> You will need git.exe and nuget.exe on your path to use these scripts.

Run upgradeall.ps1 with an appveyor api key to build and test all the autofac integrations defined in integrations.txt.

```
.\upgradeall.ps1 -appveyorApiKey ***apikey***  -testBranchName "pr-immutable-container"
```

That command will clone all the listed git repositories (into ``clones/{branch}``), upgrade them to the latest package output from the specific Autofac branch according to appveyor, then build and run the tests for that repository.

The output of that will be a single table with the summary output (this is an example using 'master' as the branch):

You'll also get a set of either trx files or html files in the ``reports/{branch}`` folder (depending on if the repo supports .NET Core), plus .log files of each upgrade once everything is done (this will contain any build errors).

If any dotnet sdk versions are not currently available, they will be installed locally to ``temp_sdk/``. The first time you run the script it may take some time to download and extract the necessary versions.

Specifying a exact package version
----------------------------------

If you don't want to use latest from appveyor, you can just specify the ``exactPackageVersion`` parameter instead of providing
an appveyor API key and a branch. If you do, we'll just use that.

Upgrading an existing Clone
---------------------------

If you want to upgrade an existing clone (or fork) of an Autofac Integration project, you can run the ``upgradeone.ps1`` script:

```
.\upgradeone.ps1 -checkoutDir {cloneDirectory} -appveyorApiKey {apikey} -testBranchName "pr-immutable-container" -outputReport {reportFilePathNoExtension}
```   

The extension of the report file will vary, so don't provide one.