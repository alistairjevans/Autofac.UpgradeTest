Param(
    # appveyor api key
    [string]
    $appveyorApiKey = "v2.e1famufjxxxq8sgptk4q",

    # Specify the branch to test against
    [Parameter(Mandatory = $true)]
    [string]
    $testBranchName = "pr-immutable-container",

    # Specify the exact version here if you don't want to use the auto-calculated one
    [string]
    $exactPackageVersion
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

if($appveyorApiKey)
{
    $exactPackageVersion = .\getLatestPackageForBranch.ps1 -appveyorApiKey $appveyorApiKey -autofacCoreBranchName $testBranchName;
}
elseif (!$exactPackageVersion) {
    
    Write-Error "Need to provide appveyor key or the exact package version."
    exit;
}

# Go through each integration from the text file and clone the code from github
$allIntegrations = Get-Content "integrationslist.txt";

"====================================="
"Upgrading all Configured Integrations"
"Testing against:"
" $testBranchName $exactPackageVersion"
"====================================="

$results = @();

foreach ($integrationText in $allIntegrations) {

    if($integrationText -and ($integrationText -notmatch "^#"))
    {
        "---------------------------"
        "Processing $integrationText"
        "---------------------------"

        $integration = ($integrationText -split "#" | Select-Object -First 1).Trim();

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
            powershell ".\coreupgradetest.ps1 -checkoutDir $integrationPath -exactPackageVersion $exactPackageVersion -testOutputReportFile `"$fullOutputFolderPath\$integration`"" 2>&1 | Tee-Object -Variable result | Tee-Object $logFile
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

            $results += [pscustomobject] @{ Integration = $integrationText; Success = $true; Message = $combinedOutput; LogFile = "reports/$integration.log"; };
            "Upgrade Test Succeeded for $integration"
        }
        else {
            $results += [pscustomobject] @{ Integration = $integrationText; Success = $false; Message = $combinedOutput; LogFile = "reports/$integration.log"; };
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