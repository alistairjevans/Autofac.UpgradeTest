Param(
    # appveyor api key
    [string]
    $appveyorApiKey = "v2.e1famufjxxxq8sgptk4q",

    [string]
    $testBranchName = "pr-immutable-container"
)

Push-Location $PSScriptRoot

if ($null -eq (Get-Command "git.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need git in path"
    exit;
}

if ($null -eq (Get-Command "nuget.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need nuget in path"
    exit;
}

if(!(Test-Path "reports"))
{
    New-Item "reports" -ItemType Container | Out-Null;
}

# Go through each integration from the text file and clone the code from github
$allIntegrations = Get-Content "integrationslist.txt";

"Upgrading all Configured Integrations"
$results = @();

foreach ($integration in $allIntegrations) {

    if($integration -and ($integration -notmatch "^#"))
    {
        "-----------------------"
        "Processing $integration"
        "-----------------------"

        $integrationPath = "clones/$testBranchName/$integration";

        if(Test-Path $integrationPath)
        {
            "Updating existing clone - $integrationPath"
            Push-Location $integrationPath
            git pull 
            Pop-Location
        }
        else
        {
            "Cloning repository to $integrationPath"
            git clone "https://github.com/autofac/$integration.git" $integrationPath
        }

        $fullOutputFolderPath = Join-Path $PSScriptRoot "reports";
        
        $logFile = "$fullOutputFolderPath/$integration.log";
        
        try {
            "Running upgrade test"
            powershell ".\coreupgradetest.ps1 -checkoutDir $integrationPath -appveyorApiKey $appveyorApiKey -autofacCoreBranchName $testBranchName -testOutputReportFile `"$fullOutputFolderPath\$integration`"" 2>&1 | Tee-Object -Variable result | Tee-Object $logFile
        }
        catch {
            $result = "E: $_";
        }

        $finalOutput = $result | Where-Object { $_ -match "^[SEW]: " }

        $allSuccess = $true;

        foreach ($lineOut in $finalOutput) {
            if($lineOut -match "^E: ")
            {
                $allSuccess = $false;
                break;
            }
        }

        $combinedOutput = [string]::Join([System.Environment]::NewLine, $finalOutput);

        if($allSuccess)
        {

            $results += [pscustomobject] @{ Integration = $integration; Success = $true; Message = $combinedOutput; LogFile = "reports/$integration.log"; };
            "Upgrade Test Succeeded for $integration"
        }
        else {
            $results += [pscustomobject] @{ Integration = $integration; Success = $false; Message = $combinedOutput; LogFile = "reports/$integration.log"; };
            "Upgrade Test Failed for $integration - $finalOutput"
        }

        # On an error we might be in the wrong folder
        Set-Location $PSScriptRoot;
    }
}

"---------------------------------------------"
"Summary of Results"
"Applying $testBranchName"
"---------------------------------------------"

# Output the results
$results | Format-Table -Wrap;

Pop-Location