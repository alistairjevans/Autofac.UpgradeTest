Param(
    # Specify the checked-out path to work on
    [string]
    $checkoutDir,
    # If you specify an appveyor API key, we'll go and figure out the exact package name
    [string]
    $appveyorApiKey,
    # The name of the branch (defaults to develop, that the project will be upgraded to),
    # we connect to appveyor to get the latest CI package name.
    [string]
    $autofacCoreBranchName = "develop",
    # If you don't want to use appveyor, you can specify the exact package version here
    # and we'll grab it from MyGet (e.g. 4.9.2-pr-immutab-000635).
    [string]
    $exactPackageVersion,
    # The location to place the generated test report
    [string]
    $testOutputReportFile
)

if(!$checkoutDir)
{
    $checkoutDir = Get-Location;
}

if ($null -eq (Get-Command "nuget.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need nuget in path"
    exit;
}

if ($null -eq (Get-Command "dotnet.exe" -ErrorAction SilentlyContinue)) 
{
    Write-Error "Need dotnet in path"
    exit;
}

if($appveyorApiKey)
{
    # Find the latest package version on the specified branch.
    # Appveyor has the actual package name
    $apiUrl = 'https://ci.appveyor.com/api';
    $token = $appveyorApiKey;
    $headers = @{
    "Authorization" = "Bearer $token"
    "Content-type" = "application/json"
    };
    $accountName = 'Autofac';
    $projectSlug = 'autofac';

    # get project with last build details
    $appveyorProject = Invoke-RestMethod -Method Get -Uri "$apiUrl/projects/$accountName/$projectSlug/branch/$autofacCoreBranchName" -Headers $headers

    if(!$appveyorProject)
    {
        Write-Error("Could not locate branch, or api key is invalid.");
        exit;
    }

    # we assume here that build has a single job
    # get this job id
    $jobId = $appveyorProject.build.jobs[0].jobId

    # get job artifacts (just to get the outputted package name)
    $artifacts = Invoke-RestMethod -Method Get -Uri "$apiUrl/buildjobs/$jobId/artifacts" -Headers $headers

    $nugetPackageFileName = Split-Path $artifacts[0].fileName -Leaf

    # Get the version from the nupkg name
    $match = [Regex]::Match($nugetPackageFileName, "Autofac\.(?<version>.+)\.nupkg");

    if(!$match.Success)
    {
        Write-Error "Cannot get Autofac version."
        exit;
    }

    $exactPackageVersion = $match.Groups["version"].Value;
}
elseif (!$exactPackageVersion) {
    
    Write-Error "Need to provide appveyor key or the exact package version."
    exit;
}

Push-Location $checkoutDir

nuget sources add -Name "Autofac Upgrade MyGet" -Source https://www.myget.org/F/autofac/api/v2 -ConfigFile .\NuGet.Config

$inCoreProject = $false;

# See if we need to install the dotnet SDK
if(Test-Path "global.json")
{
    $inCoreProject = $true;

    $globalJsonFile = Get-Content "global.json" | ConvertFrom-Json;
    
    $sdkVersion = $globalJsonFile.sdk.version;

    # Back to the root to install the SDK
    Push-Location $PSScriptRoot

    .\dotnet-install.ps1 -Version $sdkVersion -InstallDir "temp_sdk" -SkipNonVersionedFiles;

    Pop-Location

    dotnet restore;
}

# Locate all projects that contain an Autofac reference
$childProjects = Get-ChildItem *.csproj -Recurse;

foreach($proj in $childProjects)
{   
    $packList = & dotnet list $proj.FullName package;

    # Leave a space to avoid matching anything else
    if($packList -match "Autofac ")
    {
        dotnet remove $proj.FullName package Autofac

        dotnet add $proj.FullName package Autofac --version $exactPackageVersion
    }
}

if(!$inCoreProject)
{
    # Need to do a regular nuget restore to get msbuild working
    nuget restore

    # Look for vswhere in the path
    if (Get-Command "vswhere.exe" -ErrorAction SilentlyContinue)
    {
        $msbuildExe = vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | select-object -first 1
    }
    else 
    {
        $tempTools = Join-Path $PSScriptRoot "temp_tools";

        $vsWhereExe = Join-Path $tempTools "vswhere.*/tools/vswhere.exe"; 

        if(!(Test-Path $vsWhereExe))
        {
            # Get vswhere
            nuget install vswhere -OutputDirectory $tempTools
        }   

        $vsWhereExe = Resolve-Path $vsWhereExe;

        $msbuildExe = & $vsWhereExe -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | select-object -first 1
    }

    & $msbuildExe -t:Build -p:Configuration=Release
        
    # Locate xunit 
    $xunitRunner = "${env:USERPROFILE}\.nuget\packages\xunit.runner.console\*\tools\xunit.console.exe";

    $testDllPath = Resolve-Path test/*/bin/Release/*.Test.dll

    & $xunitRunner $testDllPath -html "$testOutputReportFile.html"
}
else {

    dotnet build 

    if($LastExitCode -ne 0)
    {
        Write-Error "Failed Build";
    }

    dotnet test --logger "trx;LogFileName=$testOutputReportFile.trx"

    if($LastExitCode -ne 0)
    {
        Write-Error "Failing tests (report at $testOutputReportFile.trx)"
    }
}

Pop-Location

