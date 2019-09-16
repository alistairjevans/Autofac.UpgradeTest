Param(
    # appveyor api key
    [string]
    $appveyorApiKey,

    [string]
    $testBranchName = "develop"
)

Push-Location $PSScriptRoot

if(!(Test-Path "reports"))
{
    New-Item "reports" -ItemType Container
}

# Go through each integration from the text file and clone the code from github
$allIntegrations = Get-Content "integrationslist.txt";

foreach ($integration in $allIntegrations) {

    $integrationPath = "clones/$testBranchName/$integration";

    if(Test-Path $integrationPath)
    {
        Push-Location $integrationPath
        git pull 
        Pop-Location
    }
    else
    {
        git clone "https://github.com/autofac/$integration.git" $integrationPath
    }

    $fullOutputFolderPath = Resolve-Path "reports";

    .\coreupgradetest.ps1 -checkoutDir $integrationPath -appveyorApiKey $appveyorApiKey -autofacCoreBranchName $testBranchName -testOutputReportFile "$fullOutputFolderPath\$integration";
}

Pop-Location