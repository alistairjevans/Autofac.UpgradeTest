Param(
    # appveyor api key
    [string]
    $appveyorApiKey,

    # Specify the branch to test against
    [Parameter(Mandatory = $true)]
    [string]
    $testBranchName = "develop",

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

$reportsFolder = "reports";

if($testBranchName)
{
    $reportsFolder += "/$testBranchName";
}

if(!(Test-Path $reportsFolder))
{
    New-Item $reportsFolder -ItemType Container | Out-Null;
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
$allIntegrations = Get-Content "integrations.txt";

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

        $logFile = "$reportsFolder/$integration.log";
        
        $result = $null;
        $failed = $false;

        $reportsFolder = Resolve-Path $reportsFolder;

        try 
        {
            "Running upgrade test"
            powershell ".\upgradeone.ps1 -checkoutDir $integrationPath -exactPackageVersion $exactPackageVersion -outputReport `"$reportsFolder\$integration`"" 2>&1 | Tee-Object -Variable result | Tee-Object $logFile
        }
        catch 
        {
            $result = "E: $_";
            $failed = $true;
        }

        $finalOutput = $result | Where-Object { $_ -match "^[SEW]: " }

        # Ensure that we cannot be marked as successful if an exception occurred.
        $allSuccess = !$failed;

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
"Tested against:"
" $testBranchName $exactPackageVersion"
"---------------------------------------------"

# Output the results
$results | Format-Table -Wrap -AutoSize;

Pop-Location